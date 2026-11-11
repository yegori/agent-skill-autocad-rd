"""Explicit THREE-map prepared copy pre/postflight; no discovery, CAD or source overwrite."""
from __future__ import annotations
import argparse
import importlib.util
import json
import ntpath
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import uuid

_loader = importlib.util.spec_from_file_location('rd_stage', Path(__file__).with_name('stage_inputs.py'))
stage = importlib.util.module_from_spec(_loader)
_loader.loader.exec_module(stage)
r = stage.r


class PrepareError(Exception):
    pass


def no_links(path):
    if '..' in Path(path).parts:
        raise PrepareError('prepare_noncanonical_absolute_path')
    path = Path(os.path.abspath(path))
    for item in (path, *path.parents):
        if item.exists() or item.is_symlink():
            info = item.lstat()
            if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
                raise PrepareError('prepare_reparse_point')
    return path


def regular(root, relative):
    # Reuse established containment and digest checks; also reject *internal* hardlinks.
    no_links(root)
    path = r.checked_file(Path(root), relative)
    if not stat.S_ISREG(path.stat().st_mode) or path.stat().st_nlink != 1:
        raise PrepareError('prepare_non_regular_or_hardlink')
    return path


def absolute_root(value):
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise PrepareError('prepare_absolute_root_required')
    path = no_links(value).resolve(strict=True)
    if not path.is_dir():
        raise PrepareError('prepare_root_not_directory')
    return path


def relative(value):
    stage.relative(value)
    # Windows device names, wildcard/control/ADS and trailing-dot aliases are not ordinary files.
    for part in value.split('/'):
        if (re.search(r'[<>:"|?*]', part) or re.fullmatch(r'(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?', part)):
            raise PrepareError('prepare_windows_path_alias')
    return value


def new_target(issue, output, value):
    if (not isinstance(value, str) or not value or '/' in value or ntpath.splitdrive(value)[0]
            or value.startswith('\\') or ':' in value or any(ord(c) < 32 for c in value)):
        raise PrepareError('prepare_invalid_new_path')
    parts = value.split('\\')
    if parts[0] == '.':
        parts = parts[1:]
    if not parts:
        raise PrepareError('prepare_invalid_new_path')
    for part in parts:
        if part != '..':
            relative(part)
    candidate = output.parent
    for part in parts:
        candidate = no_links(candidate.parent if part == '..' else candidate / part)
        if not candidate.is_relative_to(issue):
            raise PrepareError('prepare_target_outside_issue')
    # Parent segments are permitted only when the final target stays within this issue.
    if not candidate.is_relative_to(issue) or candidate == issue:
        raise PrepareError('prepare_target_outside_issue')
    return regular(issue, candidate.relative_to(issue).as_posix())


def overlap(a, b):
    return a == b or a.is_relative_to(b) or b.is_relative_to(a)


def validate(spec):
    if not isinstance(spec, dict) or type(spec.get('schema_version')) is not int or spec['schema_version'] != 1:
        raise PrepareError('prepare_invalid_spec')
    source_root = absolute_root(spec['source_root']);issue = absolute_root(spec['issue_root'])
    source = regular(source_root, relative(spec['source_path']))
    if source.suffix.lower() != '.dwg' or r.digest(source) != stage.sha(spec['source_sha256']):
        raise PrepareError('prepare_source_sha_or_extension')
    output = no_links(issue / relative(spec['output_path']))
    if (output.name != source.name or output.parent == issue or output.parent.exists()
            or overlap(output.parent, source_root) or overlap(output.parent, Path(__file__).resolve().parents[1])):
        raise PrepareError('prepare_output_collision_or_overlap')
    maps = spec.get('mappings')
    if not isinstance(maps, list) or len(maps) != 3:
        raise PrepareError('prepare_exactly_three_required')
    handles, names, targets = set(), set(), set()
    resolved = []
    for row in maps:
        handle, name, old = row['handle'], row['name'], row['old_path']
        if (not isinstance(handle, str) or not re.fullmatch(r'[1-9A-Fa-f][0-9A-Fa-f]*', handle)
                or not isinstance(name, str) or not name or not isinstance(old, str) or not old
                or any('\0' in x for x in (name, old))
                or ntpath.normcase(ntpath.normpath(old)) == ntpath.normcase(ntpath.normpath(row['new_path']))):
            raise PrepareError('prepare_bad_mapping_or_noop')
        target = new_target(issue, output, row['new_path'])
        if (overlap(target, output.parent) or target == source or target.suffix.lower() != '.dwg'
                or r.digest(target) != stage.sha(row['target_sha256'])):
            raise PrepareError('prepare_target_binding')
        if handle.upper() in handles or name.casefold() in names or str(target).casefold() in targets:
            raise PrepareError('prepare_duplicate_or_colliding_map')
        handles.add(handle.upper());names.add(name.casefold());targets.add(str(target).casefold())
        resolved.append({**row, 'target': str(target)})
    return source, issue, output, resolved


def write_new(path, data):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')


def copy_new(source, target, sha):
    with source.open('rb') as src, target.open('xb') as dst:
        shutil.copyfileobj(src, dst)
    if r.digest(target) != sha:
        raise PrepareError('prepare_copy_changed')


def preflight(spec, host, host_sha, evidence):
    source, issue, output, maps = validate(spec)
    host = no_links(host).resolve(strict=True)
    host = regular(host.parent, host.name)
    if host.suffix.lower() != '.dwg' or host == source or r.digest(host) != stage.sha(host_sha):
        raise PrepareError('prepare_host_binding')
    evidence = no_links(evidence)
    package = Path(__file__).resolve().parents[1]
    if (not str(evidence).isascii() or any(c in str(evidence) for c in '"\n\r') or evidence.exists()
            or any(overlap(evidence, p) for p in (source.parent, issue, host.parent, package))
            or overlap(output.parent, package) or overlap(output.parent, host)):
        raise PrepareError('prepare_evidence_collision_or_overlap')
    # No cleanup or retry: after the first mkdir all failures retain partial evidence.
    evidence.mkdir(parents=True, exist_ok=False)
    write_new(evidence / 'binding.json', {'schema_version': 1, 'spec': spec, 'host': str(host), 'host_sha256': host_sha})
    (evidence / 'input').mkdir()
    snapshot = evidence / 'input' / source.name
    copy_new(source, snapshot, spec['source_sha256'])
    copy_new(host, evidence / 'host.dwg', host_sha)
    # The output parent itself must be NEW. Targets were staged elsewhere in this issue beforehand.
    output.parent.mkdir(parents=True, exist_ok=False)
    temp_dir = output.parent / ('_pending_' + uuid.uuid4().hex)
    temp_dir.mkdir()
    request = {'schema_version': 1, 'source': str(snapshot), 'source_sha256': spec['source_sha256'],
               'issue_root': str(issue), 'output': str(temp_dir / source.name),
               'report': str(evidence / 'native.json'), 'marker': str(evidence / 'native.complete'), 'mappings': maps}
    write_new(evidence / 'request.json', request)
    check_bindings(evidence)
    return {'status': 'preflight_ready', 'execution_authorized': False}


def read_json(path):
    return json.loads(regular(path.parent, path.name).read_text(encoding='utf-8-sig'))


def check_bindings(evidence):
    evidence = no_links(evidence).resolve(strict=True)
    binding = read_json(evidence / 'binding.json');spec = binding['spec']
    source = regular(absolute_root(spec['source_root']), relative(spec['source_path']))
    issue = absolute_root(spec['issue_root']);output = no_links(issue / relative(spec['output_path']))
    request = read_json(evidence / 'request.json')
    if (request['source_sha256'] != spec['source_sha256'] or request['source'] != str(evidence / 'input' / source.name)
            or request['issue_root'] != str(issue) or request['report'] != str(evidence / 'native.json')
            or request['marker'] != str(evidence / 'native.complete')
            or Path(request['output']).parent.parent != output.parent or Path(request['output']).name != source.name
            or not Path(request['output']).parent.name.startswith('_pending_')):
        raise PrepareError('prepare_request_binding')
    for path, sha in ((source, spec['source_sha256']), (Path(request['source']), spec['source_sha256']),
                      (Path(binding['host']), binding['host_sha256']), (evidence / 'host.dwg', binding['host_sha256'])):
        if r.digest(regular(path.parent, path.name)) != sha:
            raise PrepareError('prepare_source_or_host_changed')
    expected = []
    for row in spec['mappings']:
        target = new_target(issue, output, row['new_path'])
        if r.digest(target) != row['target_sha256']:
            raise PrepareError('prepare_target_changed')
        expected.append({**row, 'target': str(target)})
    if request['mappings'] != expected:
        raise PrepareError('prepare_request_maps_changed')
    return binding, request, output


def finish(evidence):
    evidence = no_links(evidence).resolve(strict=True)
    binding, request, output = check_bindings(evidence)
    owned = read_json(evidence / 'owned.json')
    if (owned.get('AllDone') is not True or owned.get('TimedOut') is not False
            or owned.get('RootExitedBeforeStop') is not False or owned.get('Terminated') is not True
            or owned.get('RootExitCodeBeforeStop') is not None):
        raise PrepareError('prepare_owned_completion_unproven')
    marker = regular(evidence, 'native.complete')
    if marker.read_text(encoding='utf-8-sig') != 'ALLDONE\n':
        raise PrepareError('prepare_marker_invalid')
    native = read_json(evidence / 'native.json')
    if (native.get('kind') != 'explicit_xref_copy' or native.get('status') != 'prepared_candidate'
            or native.get('completion_hold') != 'inside_managed_prepare_command'
            or native.get('request_sha256') != r.digest(evidence / 'request.json')
            or native.get('source_sha256') != request['source_sha256'] or type(native.get('changed_count')) is not int
            or native['changed_count'] != 3 or native.get('mappings') != request['mappings']
            or native.get('output') != request['output'] or native.get('schema_version') != 1
            or type(native.get('verified_direct_xref_count')) is not int or native['verified_direct_xref_count'] < 3
            or native.get('dependency_complete') is not False or native.get('semantic_identity_proven') is not False
            or native.get('execution_authorized') is not False):
        raise PrepareError('prepare_native_result_invalid')
    temp = regular(output.parent, Path(request['output']).relative_to(output.parent).as_posix())
    if r.digest(temp) != stage.sha(native.get('output_sha256')) or output.exists():
        raise PrepareError('prepare_output_collision_or_hash')
    # Windows rename is no-replace. Never use replace(), Move-Item -Force, or POSIX replacing rename.
    if os.name != 'nt':
        raise PrepareError('prepare_publish_requires_windows_no_replace_rename')
    os.rename(temp, output)
    check_bindings(evidence)
    if r.digest(regular(output.parent, output.name)) != native['output_sha256']:
        raise PrepareError('prepare_published_output_changed')
    result = {'schema_version': 1, 'kind': 'explicit_xref_prepared_copy', 'status': 'prepared_candidate',
              'source': {'root': binding['spec']['source_root'], 'path': binding['spec']['source_path'], 'sha256': request['source_sha256']},
              'output': str(output), 'output_sha256': native['output_sha256'], 'mappings': request['mappings'],
              'request_sha256': r.digest(evidence / 'request.json'), 'native_sha256': r.digest(evidence / 'native.json'),
              'completion_mode': 'owned_job_after_prepared_copy', 'exit_code': None, 'root_alive_before_stop': True,
              'cleanup_verified': True, 'elapsed_seconds': owned['ElapsedSeconds'], 'cad_starts': 1,
              'dependency_complete': False, 'execution_authorized': False,
              'semantic_identity_proven': False, 'publication_approved': False}
    write_new(evidence / 'prepared.pending.json', result)
    os.rename(evidence / 'prepared.pending.json', evidence / 'prepared.json')  # Closed, no-replace metadata publication.
    return {'status': 'prepared_candidate', 'changed_count': 3, 'execution_authorized': False}


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    pre = sub.add_parser('preflight');pre.add_argument('spec', type=Path)
    pre.add_argument('--host', type=Path, required=True);pre.add_argument('--host-sha', required=True)
    pre.add_argument('--evidence', type=Path, required=True)
    post = sub.add_parser('finish');post.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = (preflight(read_json(args.spec), args.host, args.host_sha, args.evidence)
                  if args.command == 'preflight' else finish(args.evidence))
    except (PrepareError, stage.StageError, r.InventoryError, OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
        print(json.dumps({'status': 'failed', 'error': str(exc)}));return 2
    print(json.dumps(result));return 0


if __name__ == '__main__':
    raise SystemExit(main())
