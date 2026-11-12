"""Explicit ordered, hash-bound PDF assembly. No discovery/native apps; QA remains caller-owned."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import ntpath
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

_spec = importlib.util.spec_from_file_location("cover_preflight", Path(__file__).with_name("cover_preflight.py"))
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)
MAX_INPUTS, MAX_PAGES = 64, 1000
MAX_FILE, MAX_BYTES = 128 * 1024**2, 512 * 1024**2


def _state(info):
    return guard._fingerprint(info), info.st_ctime_ns


def read_bound(path, expected=None, limit=MAX_FILE):
    """Hash and parse the SAME captured bytes, not a later path reopen."""
    guard._ordinary_chain(path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= limit:
        raise ValueError("nonempty_regular_input_within_limit_required")
    with path.open("rb") as source:
        opened = os.fstat(source.fileno())
        if guard._fingerprint(before) != guard._fingerprint(opened):
            raise ValueError("input_identity_changed")
        data = source.read(limit + 1)
        after = os.fstat(source.fileno())
    guard._ordinary_chain(path)
    if (len(data) > limit or guard._fingerprint(before) != guard._fingerprint(after)
            or opened.st_ctime_ns != after.st_ctime_ns or _state(before) != _state(path.lstat())):
        raise ValueError("input_changed_during_read")
    digest = hashlib.sha256(data).hexdigest()
    if expected is not None and digest != expected.lower():
        raise ValueError("input_hash_mismatch")
    return data, digest, _state(before)


def _inside(path, root):
    try:
        return os.path.commonpath([os.path.normcase(str(path)), os.path.normcase(str(root))]) == os.path.normcase(str(root))
    except ValueError:  # Different Windows drives.
        return False


def _new_destination(path):
    guard._ordinary_chain(path.parent)
    if not path.parent.is_dir() or os.path.lexists(path):
        raise ValueError("destination_exists_or_parent_invalid")


def validate(plan, input_root, output, report, work_parent):
    root, out, side = map(guard._path, (input_root, output, report))
    work = guard._path(work_parent) if work_parent else out.parent
    for directory in (root, work):
        guard._ordinary_chain(directory)
        if not directory.is_dir():
            raise ValueError("existing_directory_required")
    if out.suffix.lower() != '.pdf' or side.suffix.lower() != '.json':
        raise ValueError("pdf_output_json_report_required")
    if os.path.normcase(str(out)) == os.path.normcase(str(side)):
        raise ValueError("output_report_alias")
    for target in (out, side, work):
        if _inside(target, root):
            raise ValueError("outputs_and_work_must_be_outside_input_root")
    for target in (out, side):
        _new_destination(target)
    if not isinstance(plan, dict) or set(plan) != {'inputs', 'expected_total_pages'}:
        raise ValueError("explicit_inputs_and_expected_total_required")
    entries, total = plan['inputs'], plan['expected_total_pages']
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_INPUTS:
        raise ValueError("input_count_limit")
    if type(total) is not int or not 1 <= total <= MAX_PAGES:
        raise ValueError("positive_total_pages_required")
    selected, seen, hashes = [], set(), set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {'path', 'sha256', 'pages'}:
            raise ValueError("input_path_sha256_pages_required")
        name = entry['path']
        if not isinstance(name, str) or not name or ntpath.splitdrive(name)[0] or name.startswith(('\\', '/')):
            raise ValueError("relative_input_required")
        parts = name.replace('\\', '/').split('/')
        if '..' in parts:
            raise ValueError("relative_traversal_forbidden")
        path = guard._path(str(root / Path(*parts)))
        if not _inside(path, root) or path.suffix.lower() != '.pdf':
            raise ValueError("in_root_pdf_required")
        key = os.path.normcase(str(path))
        if key in seen:
            raise ValueError("duplicate_input")
        seen.add(key)
        guard._ordinary_chain(path)
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError("regular_pdf_required")
        if not isinstance(entry['sha256'], str) or not re.fullmatch('[0-9a-fA-F]{64}', entry['sha256']):
            raise ValueError("explicit_sha256_required")
        if entry['sha256'].lower() in hashes:
            raise ValueError("duplicate_input_hash")
        hashes.add(entry['sha256'].lower())
        if type(entry['pages']) is not int or not 1 <= entry['pages'] <= MAX_PAGES:
            raise ValueError("positive_input_pages_required")
        selected.append((path, dict(entry)))
    if sum(entry['pages'] for _, entry in selected) != total:
        raise ValueError("planned_total_mismatch")
    return root, out, side, work, selected


def _page_info(page):
    return {'rect': list(page.rect), 'mediabox': list(page.mediabox), 'cropbox': list(page.cropbox),
            'rotation': page.rotation, 'content_stream_sha256': hashlib.sha256(page.read_contents()).hexdigest()}


def _verify_sources(bindings):
    for path, expected, identity in bindings:
        if guard.source_hash(path) != expected or _state(path.lstat()) != identity:
            raise ValueError("postflight_input_changed")


def _publish_new(data, target):
    _new_destination(target)
    with target.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def _json_bytes(value):
    return json.dumps(value, ensure_ascii=True, indent=2).encode('utf-8')


def assemble(plan, input_root, output, report, work_parent=None, *, publisher=_publish_new, _plan_binding=None):
    """publisher is an inert unit-test seam only; never selectable via CLI."""
    root, out, side, work, selected = validate(plan, input_root, output, report, work_parent)
    import pymupdf as fitz  # Installed PyMuPDF required; avoid deprecated alias stdout. No install/fallback.
    run = Path(tempfile.mkdtemp(prefix='assemble-pdf-', dir=work))
    result = {'status': 'failed', 'engineering_release_approved': False, 'coordinator_qa_required': True,
              'run_dir': str(run), 'input_root': str(root), 'ordered_sources': [], 'published': [],
              'publication_pair_atomic': False, 'cleanup': 'private_work_retained_no_deletion',
              'limits': {'inputs': MAX_INPUTS, 'pages': MAX_PAGES, 'input_bytes': MAX_FILE, 'total_bytes': MAX_BYTES},
              'coverage': 'whole_input_pages_in_explicit_order_no_native_print_or_S4_closure',
              'limitations': ['trusted PDF parser, not an OS/filesystem sandbox; stable local directories required',
                  'no text/render/pixel identity or engineering/signature/fidelity acceptance',
                  'document metadata/outlines/attachments/forms/digital signatures not preserved or approved as a contract',
                  'sidecar candidate alone is not pair completion proof: require CLI exit0 and private result.json']}
    try:
        expected_pages, bindings, byte_count = [], ([_plan_binding] if _plan_binding else []), 0
        if _plan_binding:
            result['plan_sha256'] = _plan_binding[1]
        with fitz.open() as merged:
            for path, entry in selected:
                data, digest, identity = read_bound(path, entry['sha256'])
                byte_count += len(data)
                if byte_count > MAX_BYTES:
                    raise ValueError("total_input_bytes_limit")
                # Never give the parser a source pathname: approved captured bytes only.
                with fitz.open(stream=data, filetype='pdf') as source:
                    if not source.is_pdf or source.needs_pass or source.is_encrypted or source.metadata.get('encryption'):
                        raise ValueError("unencrypted_pdf_required")
                    if source.page_count != entry['pages']:
                        raise ValueError("input_page_count_mismatch")
                    pages = [_page_info(page) for page in source]
                    if any(page.rect.is_empty or page.rect.is_infinite for page in source):
                        raise ValueError("invalid_page_geometry")
                    merged.insert_pdf(source)  # All pages, provided order; no sorting/discovery.
                bindings.append((path, digest, identity))
                result['ordered_sources'].append(dict(entry, sha256=digest, bytes=len(data), pages_metadata=pages))
                expected_pages.extend(pages)
            pdf_bytes = merged.tobytes()  # Default document metadata, no invented title/author/requisites.
        private_pdf = run / 'assembled.pdf'
        _publish_new(pdf_bytes, private_pdf)
        closed_data, output_sha, _ = read_bound(private_pdf, hashlib.sha256(pdf_bytes).hexdigest(), limit=MAX_BYTES)
        with fitz.open(stream=closed_data, filetype='pdf') as closed:
            if closed.needs_pass or closed.page_count != plan['expected_total_pages']:
                raise ValueError("closed_output_page_count_mismatch")
            actual = [_page_info(page) for page in closed]
        for wanted, got in zip(expected_pages, actual):
            if wanted['rotation'] != got['rotation'] or wanted['content_stream_sha256'] != got['content_stream_sha256']:
                raise ValueError("closed_output_order_or_content_mismatch")
            if any(abs(a-b) > 0.0001 for key in ('rect','mediabox','cropbox') for a,b in zip(wanted[key],got[key])):
                raise ValueError("closed_output_page_format_mismatch")
        _verify_sources(bindings)
        for target in (out, side):
            _new_destination(target)
        result.update(output={'path': str(out), 'sha256': output_sha, 'bytes': len(closed_data),
                              'pages': len(actual), 'pages_metadata': actual}, report_path=str(side))
        result['publication_attempt'] = str(out)
        publisher(closed_data, out)
        result['published'].append(str(out))
        if guard.source_hash(out) != output_sha:
            raise ValueError("published_pdf_hash_mismatch")
        _verify_sources(bindings)
        result['status'] = 'assembled_pending_coordinator_qa'
        # No claim of atomic publication; the final private result/CLI outcome is authoritative.
        side_payload = {k:v for k,v in result.items() if k not in ('published','publication_attempt')}
        side_bytes = _json_bytes(side_payload)
        result['publication_attempt'] = str(side)
        publisher(side_bytes, side)
        result['published'].append(str(side))
        result['report_sha256'] = hashlib.sha256(side_bytes).hexdigest()
        if guard.source_hash(side) != result['report_sha256']:
            raise ValueError("published_report_hash_mismatch")
        _verify_sources(bindings)
        result.pop('publication_attempt', None)
    except Exception as error:
        result.update(status='failed', error=str(error), partial_publication_possible=bool(result.get('publication_attempt')))
    try:
        _publish_new(_json_bytes(result), run / 'result.json')
    except (OSError, ValueError) as error:
        result.update(status='failed', evidence_write_uncertain=True, error='private_result_write_failed: '+str(error))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('plan','input-root','output','report'):
        parser.add_argument('--'+key, required=True)
    parser.add_argument('--work-parent')
    args = parser.parse_args()
    try:
        plan_path = guard._path(args.plan)
        data, plan_sha, plan_identity = read_bound(plan_path, limit=1024**2)
        plan = json.loads(data.decode('utf-8', errors='strict'), object_pairs_hook=guard._unique_object)
        result = assemble(plan, args.input_root, args.output, args.report, args.work_parent,
                          _plan_binding=(plan_path, plan_sha, plan_identity))
    except (ValueError, OSError, RuntimeError, ImportError) as error:
        result = {'status': 'failed', 'error': str(error), 'coordinator_qa_required': True}
    print(json.dumps(result, ensure_ascii=True, indent=2))
    return 0 if result['status'] == 'assembled_pending_coordinator_qa' else 1


if __name__ == '__main__':
    raise SystemExit(main())
