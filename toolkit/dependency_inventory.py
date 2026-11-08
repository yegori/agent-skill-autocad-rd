"""Validate side-database evidence; bind only declared direct dependencies inside explicit roots. Never authorize/reuse."""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path, PureWindowsPath
import stat
import sys

_spec = importlib.util.spec_from_file_location('rd_dep_resource', Path(__file__).with_name('resource_inventory.py'))
r = importlib.util.module_from_spec(_spec);_spec.loader.exec_module(r)


class DependencyError(Exception):
    pass


def contained(root, candidate):
    root = Path(root).resolve(strict=True)
    path = Path(os.path.abspath(candidate))
    if not path.is_relative_to(root) or path == root:
        raise DependencyError('outside_authorized_root')
    current = root
    for part in (None, *path.relative_to(root).parts):
        if part is not None:current = current / part
        info = current.lstat()
        if stat.S_ISLNK(info.st_mode) or getattr(info,'st_file_attributes',0) & 0x400:
            raise DependencyError('dependency_reparse_point')
    if not path.is_file():raise DependencyError('dependency_not_regular_file')
    return path


def reference_path(parent, value):
    if not isinstance(value,str) or not value or any(ord(c)<32 for c in value) or '%' in value:
        raise DependencyError('unsupported_dependency_reference')
    win=PureWindowsPath(value)
    if win.drive and os.name!='nt':raise DependencyError('foreign_absolute_reference')
    if win.root and not win.drive:raise DependencyError('root_relative_reference_requires_review')
    return Path(value.replace('\\','/')) if win.drive else Path(parent)/value.replace('\\','/')


def build_inventory(probe, native, source_root, source_path, environment_roots):
    root=Path(source_root).resolve(strict=True);source=contained(root,root/source_path)
    if (not isinstance(probe,dict) or type(probe.get('schema_version')) is not int or probe['schema_version']!=1 or probe.get('kind')!='dependency_probe'
        or probe.get('status')!='observed_partial' or probe.get('completion_mode')!='owned_job_after_side_database_read'
        or probe.get('exit_code') is not None or probe.get('root_alive_before_stop') is not True
        or probe.get('cleanup_verified') is not True or type(probe.get('cad_starts')) is not int or probe['cad_starts']!=1
        or not r.number(probe.get('elapsed_seconds')) or probe.get('execution_authorized') is not False):
        raise DependencyError('dependency_completion_unproven')
    if (not isinstance(native,dict) or type(native.get('schema_version')) is not int or native['schema_version']!=1 or native.get('kind')!='side_database_dependencies'
        or native.get('status')!='observed_partial' or native.get('execution_authorized') is not False
        or native.get('coverage')!='direct_tables_and_asset_dictionaries'
        or any(not isinstance(native.get(k),list) for k in ('xrefs','fonts','assets','layouts','omissions'))
        or not native['omissions']):raise DependencyError('invalid_partial_dependency_report')
    sha=r.digest(source)
    if sha!=probe.get('source_sha256') or sha!=native.get('source_sha256'):raise DependencyError('dependency_source_changed')
    files=[{'path':source.relative_to(root).as_posix(),'sha256':sha,'role':'drawing'}];environment=[];questions=[];refs=[]
    def project_ref(kind,item):
        if not isinstance(item,dict):raise DependencyError('invalid_dependency_row')
        try:
            candidate=reference_path(source.parent,item.get('path'));resolved=contained(root,candidate)
            record={'path':resolved.relative_to(root).as_posix(),'sha256':r.digest(resolved),'role':'project_dependency'}
            if record not in files:files.append(record)
            refs.append({'kind':kind,'name':item.get('name'),'resolved_path':record['path']})
            if PureWindowsPath(item['path']).is_absolute():questions.append({'kind':kind,'reason':'absolute_reference_not_staged'})
            if kind=='xref':questions.append({'kind':kind,'reason':'nested_xref_probe_required'})
        except (DependencyError,OSError) as exc:
            questions.append({'kind':kind,'reason':str(exc) if isinstance(exc,DependencyError) else 'dependency_missing_or_unreadable'})
    for item in native['xrefs']:project_ref('xref',item)
    for item in native['assets']:project_ref('asset',item)
    if not isinstance(environment_roots,dict) or 'project' in environment_roots:
        raise DependencyError('invalid_environment_roots')
    roots={name:Path(path).resolve(strict=True) for name,path in environment_roots.items()}
    for style in native['fonts']:
        if not isinstance(style,dict):raise DependencyError('invalid_font_row')
        for field in ('file','big_font'):
            value=style.get(field)
            if field=='big_font' and not value:continue
            if not value:
                questions.append({'kind':'font','style':style.get('name'),'reason':'font_filename_or_registry_mapping_required'});continue
            candidates=[]
            for name,folder in [('project',root),*roots.items()]:
                try:
                    candidate=reference_path(source.parent if name=='project' else folder,value)
                    path=contained(folder,candidate)
                    candidates.append((name,folder,path))
                except (DependencyError,OSError):continue
            if not candidates:
                questions.append({'kind':'font','style':style.get('name'),'reason':'font_missing_in_authorized_roots'});continue
            hashes={r.digest(path) for _,_,path in candidates}
            if len(hashes)!=1:
                questions.append({'kind':'font','style':style.get('name'),'reason':'ambiguous_font_content_search_order_unknown'});continue
            for name,folder,path in candidates:
                if name=='project':
                    row={'path':path.relative_to(root).as_posix(),'sha256':next(iter(hashes)),'role':'project_dependency'}
                    if row not in files:files.append(row)
                else:
                    row={'root':name,'path':path.relative_to(folder).as_posix(),'sha256':next(iter(hashes))}
                    if row not in environment:environment.append(row)
    return {'schema_version':1,'status':'needs_input' if questions else 'observed_partial',
        'coverage':'direct_tables_and_asset_dictionaries','execution_authorized':False,'dependency_complete':False,
        'files':files,'environment':environment,'questions':questions,'references':refs,'omissions':native['omissions'],
        'layouts':native['layouts'],'host_fontalt':native.get('host_fontalt'),'host_fontmap':native.get('host_fontmap')}


def main():
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8')
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('evidence',type=Path);p.add_argument('--source-root',type=Path,required=True)
    p.add_argument('--source-path',required=True);p.add_argument('--environment-roots',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    try:
        if a.output.resolve().is_relative_to(a.source_root.resolve()) or a.output.exists():raise DependencyError('dependency_output_not_new_or_inside_source')
        evidence=a.evidence.resolve(strict=True);raw=contained(evidence,evidence/'native.json');marker=contained(evidence,evidence/'native.complete')
        probe=json.loads(contained(evidence,evidence/'probe.json').read_text(encoding='utf-8-sig'))
        if r.digest(raw)!=probe.get('native_sha256') or marker.read_text(encoding='utf-8-sig').strip()!='ALLDONE':raise DependencyError('dependency_evidence_changed')
        result=build_inventory(probe,json.loads(raw.read_text(encoding='utf-8-sig')),a.source_root,a.source_path,json.loads(a.environment_roots.read_text(encoding='utf-8-sig')))
        with a.output.open('x',encoding='utf-8') as stream:json.dump(result,stream,ensure_ascii=False,indent=2,allow_nan=False);stream.write('\n')
    except (DependencyError,OSError,ValueError,TypeError,KeyError,AttributeError):
        print(json.dumps({'status':'failed','error':'dependency_evidence_or_scope_invalid'}));return 2
    print(json.dumps({'status':result['status'],'direct_files':len(result['files']),'environment_bindings':len(result['environment']),'questions':len(result['questions']),'execution_authorized':False}))
    return 3 if result['status']=='needs_input' else 0


if __name__=='__main__':raise SystemExit(main())
