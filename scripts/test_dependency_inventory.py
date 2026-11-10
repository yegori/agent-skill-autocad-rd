import contextlib
import copy
import io
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('dependencies',Path(__file__).resolve().parents[1]/'toolkit/dependency_inventory.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name).resolve()
        self.inputs=self.root/'input';self.inputs.mkdir();(self.inputs/'001 test.dwg').write_bytes(b'not real DWG')
        self.fonts=self.root/'fonts';self.fonts.mkdir();(self.fonts/'test.shx').write_bytes(b'not real font')
        h=hashlib.sha256(b'not real DWG').hexdigest()
        self.probe={'schema_version':1,'kind':'dependency_probe','status':'observed_partial','source_sha256':h,'completion_mode':'owned_job_after_side_database_read','exit_code':None,'root_alive_before_stop':True,'cleanup_verified':True,'cad_starts':1,'elapsed_seconds':1.0,'execution_authorized':False}
        self.native={'schema_version':1,'kind':'side_database_dependencies','status':'observed_partial','source_sha256':h,'coverage':'direct_tables_and_asset_dictionaries','execution_authorized':False,'xrefs':[],'assets':[],'layouts':[],'fonts':[{'name':'standard','file':'test.shx','big_font':''}],'omissions':['nested_xref_contents','actual_font_resolution_and_substitution']}
    def build(self):return p.build_inventory(self.probe,self.native,self.inputs,'001 test.dwg',{'fonts':self.fonts})
    def test_partial_never_complete_or_authorized(self):
        result=self.build();self.assertEqual(result['status'],'observed_partial');self.assertFalse(result['execution_authorized']);self.assertFalse(result['dependency_complete']);self.assertEqual(len(result['environment']),1)
    def test_parent_escape_never_opened(self):
        outside=self.root/'outside.dwg';outside.write_bytes(b'outside')
        self.native['xrefs']=[{'name':'bad','path':'../outside.dwg'}]
        real=p.r.digest;seen=[]
        def digest(path):seen.append(path);return real(path)
        with patch.object(p.r,'digest',digest):result=self.build()
        self.assertEqual(result['questions'][0]['reason'],'outside_authorized_root');self.assertNotIn(outside,seen)
    def test_direct_xref_binds_but_requires_nested_probe(self):
        (self.inputs/'refs').mkdir();(self.inputs/'refs/x.dwg').write_bytes(b'child')
        self.native['xrefs']=[{'name':'x','path':r'refs\x.dwg'}]
        result=self.build();self.assertEqual(len(result['files']),2);self.assertEqual(result['questions'][0]['reason'],'nested_xref_probe_required')
    def test_asset_and_missing_asset(self):
        (self.inputs/'image.png').write_bytes(b'fake image');self.native['assets']=[{'name':'img','path':'image.png'}]
        self.assertEqual(len(self.build()['files']),2);(self.inputs/'image.png').unlink();self.assertEqual(self.build()['status'],'needs_input')
    def test_missing_and_ambiguous_fonts(self):
        (self.fonts/'test.shx').unlink();self.assertEqual(self.build()['status'],'needs_input')
        (self.fonts/'test.shx').write_bytes(b'different');(self.inputs/'test.shx').write_bytes(b'other')
        self.assertEqual(self.build()['questions'][0]['reason'],'ambiguous_font_content_search_order_unknown')
    def test_empty_font_does_not_guess_typeface_or_substitute(self):
        self.native['fonts'][0]['file']='';self.native['fonts'][0]['typeface']='Arial';self.assertEqual(self.build()['questions'][0]['reason'],'font_filename_or_registry_mapping_required')
    def test_source_drift_and_unproven_execution(self):
        for field,value in (('cleanup_verified',False),('root_alive_before_stop',False),('exit_code',0),('cad_starts',2)):
            old=self.probe[field];self.probe[field]=value
            with self.assertRaises(p.DependencyError):self.build()
            self.probe[field]=old
        (self.inputs/'001 test.dwg').write_bytes(b'changed')
        with self.assertRaises(p.DependencyError):self.build()
    def test_cli_evidence_hash_marker_and_exclusive_output(self):
        evidence=self.root/'evidence';evidence.mkdir();raw=evidence/'native.json';raw.write_text(json.dumps(self.native),encoding='utf-8')
        probe=dict(self.probe,native_sha256=hashlib.sha256(raw.read_bytes()).hexdigest())
        (evidence/'probe.json').write_text(json.dumps(probe),encoding='utf-8');marker=evidence/'native.complete';marker.write_text('ALLDONE\n',encoding='utf-8')
        roots=self.root/'roots.json';roots.write_text(json.dumps({'fonts':str(self.fonts)}),encoding='utf-8')
        output=self.root/'inventory.json'
        args=['dependencies',str(evidence),'--source-root',str(self.inputs),'--source-path','001 test.dwg','--environment-roots',str(roots),'--output',str(output)]
        with patch.object(p.sys,'argv',args),contextlib.redirect_stdout(io.StringIO()):self.assertEqual(p.main(),0)
        before=output.read_bytes()
        with patch.object(p.sys,'argv',args),contextlib.redirect_stdout(io.StringIO()):self.assertEqual(p.main(),2)
        self.assertEqual(output.read_bytes(),before);output.unlink();raw.write_text('{}',encoding='utf-8')
        with patch.object(p.sys,'argv',args),contextlib.redirect_stdout(io.StringIO()):self.assertEqual(p.main(),2)
        self.assertFalse(output.exists())
    def test_reserved_project_environment_root_refuses(self):
        with self.assertRaises(p.DependencyError):p.build_inventory(self.probe,self.native,self.inputs,'001 test.dwg',{'project':self.fonts})
    def issue(self):
        return p.build_inventory(self.probe,self.native,self.inputs,'001 test.dwg',{},issue_only=True)
    def test_issue_only_rejects_external_roots_before_any_hash(self):
        with patch.object(p.r,'digest') as digest:
            with self.assertRaisesRegex(p.DependencyError,'issue_only_forbids_environment_roots'):
                p.build_inventory(self.probe,self.native,self.inputs,'001 test.dwg',{'fonts':self.fonts},issue_only=True)
            digest.assert_not_called()
    def test_issue_only_binds_exact_relative_files_and_never_substitutes_fonts(self):
        (self.inputs/'test.shx').write_bytes(b'issue font')
        (self.inputs/'child.dwg').write_bytes(b'child')
        self.native['xrefs']=[{'name':'stamp','path':'./child.dwg'}]
        result=self.issue()
        self.assertEqual(result['resolution_scope'],'issue_relative_only')
        self.assertEqual(result['environment'],[])
        self.assertEqual({x['path'] for x in result['files']},{'001 test.dwg','test.shx','child.dwg'})
        self.assertFalse(result['dependency_complete']);self.assertFalse(result['execution_authorized'])
        self.assertEqual(result['questions'][0]['path'],'./child.dwg')
    def test_issue_only_absolute_unc_drive_relative_ads_and_escape_are_not_read(self):
        (self.inputs/'child.dwg').write_bytes(b'child')
        outside=self.root/'outside.dwg';outside.write_bytes(b'outside')
        for value in (str(self.inputs/'child.dwg'),r'C:\outside.dwg',r'C:relative.dwg',r'\\server\share\x.dwg',
                      '/root/x.dwg','child.dwg:stream','../outside.dwg','%TEMP%/x.dwg'):
            with self.subTest(value=value):
                self.native['xrefs']=[{'name':'blocked','path':value}]
                seen=[];real=p.r.digest
                def digest(path):seen.append(path);return real(path)
                with patch.object(p.r,'digest',side_effect=digest):result=self.issue()
                self.assertEqual(seen,[self.inputs/'001 test.dwg'])
                self.assertEqual(len(result['files']),1)
                self.assertEqual(result['questions'][0]['name'],'blocked')
                self.assertEqual(result['questions'][0]['path'],value)
    def test_issue_only_missing_font_does_not_search_external_or_basename(self):
        (self.inputs/'other').mkdir();(self.inputs/'other/test.shx').write_bytes(b'other')
        result=self.issue()
        self.assertEqual(result['questions'][0]['path'],'test.shx')
        self.assertEqual(result['questions'][0]['reason'],'font_missing_in_authorized_roots')
        self.assertEqual(len(result['files']),1)
        self.native['fonts'][0]['file']=str(self.fonts/'test.shx')
        self.assertEqual(self.issue()['questions'][0]['reason'],'absolute_or_special_dependency_reference')
    def test_issue_only_source_must_be_relative_and_root_reparse_is_rejected(self):
        from types import SimpleNamespace
        with self.assertRaises(p.DependencyError):
            p.build_inventory(self.probe,self.native,self.inputs,str(self.inputs/'001 test.dwg'),{},issue_only=True)
        real=Path.lstat
        def info(path,*args,**kwargs):
            data=real(path,*args,**kwargs)
            return SimpleNamespace(st_mode=data.st_mode,st_file_attributes=0x400) if path==self.inputs else data
        with patch.object(Path,'lstat',info),patch.object(p.r,'digest') as digest:
            with self.assertRaisesRegex(p.DependencyError,'dependency_reparse_point'):self.issue()
            digest.assert_not_called()
    def test_issue_only_cli_does_not_require_environment_file(self):
        evidence=self.root/'evidence';evidence.mkdir();raw=evidence/'native.json'
        raw.write_text(json.dumps(self.native),encoding='utf-8')
        (evidence/'probe.json').write_text(json.dumps(dict(self.probe,native_sha256=p.r.digest(raw))),encoding='utf-8')
        (evidence/'native.complete').write_text('ALLDONE\n',encoding='utf-8')
        output=self.root/'inventory.json'
        args=['dependencies',str(evidence),'--source-root',str(self.inputs),'--source-path','001 test.dwg','--issue-only','--output',str(output)]
        with patch.object(p.sys,'argv',args),contextlib.redirect_stdout(io.StringIO()):self.assertEqual(p.main(),3)
        result=json.loads(output.read_text(encoding='utf-8'))
        self.assertEqual(result['resolution_scope'],'issue_relative_only');self.assertEqual(result['environment'],[])
    def add_usage(self):
        fixture = Path(__file__).with_name('fixtures') / 'dependency_usage.json'
        self.native.update(json.loads(fixture.read_text(encoding='utf-8')))

    def test_usage_style_xref_provenance_and_table_only_are_distinct(self):
        self.add_usage()
        result = self.issue()
        usage = result['usage']
        records = {r['record']['record_handle']: r for r in usage['record_evidence']}
        self.assertEqual(records['10']['observation_count'], 4)
        self.assertEqual(records['10']['state'], 'references_observed')
        self.assertEqual(records['11']['state'], 'table_only_no_observation')
        self.assertEqual(records['20']['observation_count'], 1)
        self.assertEqual(usage['observations'], self.native['usage']['observations'])
        self.assertEqual({r['space'] for r in usage['containers']}, {'model', 'paper', 'block_definition'})
        self.assertFalse(result['dependency_complete']); self.assertFalse(usage['complete'])
        self.assertFalse(result['execution_authorized']); self.assertEqual(result['environment'], [])

    def test_usage_absence_never_removes_existing_questions(self):
        self.add_usage()
        observed = self.issue()
        self.native['usage']['observations'] = []
        no_observations = self.issue()
        del self.native['usage']
        legacy = self.issue()
        self.assertEqual(observed['questions'], no_observations['questions'])
        self.assertEqual(observed['questions'], legacy['questions'])
        self.assertNotIn('usage', legacy)
        self.assertEqual(legacy['coverage'], 'direct_tables_and_asset_dictionaries')
        self.assertTrue(all(r['state'] == 'table_only_no_observation' for r in no_observations['usage']['record_evidence']))

    def test_unknown_proxy_dimensions_viewports_preserved_not_resolved(self):
        self.add_usage()
        usage = self.issue()['usage']
        unknown = [r for r in usage['observations'] if r['kind'] == 'unsupported_entity']
        self.assertEqual([r['class_name'] for r in unknown], ['AcDbProxyEntity', 'AcDbAlignedDimension', 'AcDbViewport'])
        self.assertTrue(all(r['target_handle'] is None for r in unknown))
        self.assertIn('model_to_paper_viewports', usage['omissions'])
        self.assertIn('proxy_spds_custom_resources', usage['omissions'])

    def test_block_cycle_is_finite_definition_edges_not_recursive_usage(self):
        self.add_usage()
        usage = self.issue()['usage']
        edges = {(r['container_handle'], r['target_handle']) for r in usage['observations'] if r['kind'] == 'block_reference'}
        self.assertTrue({('C', 'D'), ('D', 'C')}.issubset(edges))
        self.assertEqual(usage['traversal'], 'definitions_once_no_recursion')
        self.assertIn('insertion_paths_and_cycles_not_expanded', usage['omissions'])
        self.assertFalse(usage['complete'])
        # A cap can leave target definitions unscanned. Keep the edge, never infer non-use.
        self.native['usage']['truncated'] = True
        self.native['usage']['containers'] = self.native['usage']['containers'][:2]
        self.native['usage']['observations'] = self.native['usage']['observations'][:4]
        result = self.issue()
        self.assertTrue(result['usage']['truncated'])
        self.assertEqual(result['usage']['observations'][2]['target_handle'], 'C')
        self.assertEqual(len(result['questions']), 3)

    def test_usage_invalid_provenance_completeness_and_limits_rejected(self):
        self.add_usage()
        original = copy.deepcopy(self.native)
        mutations = [
            lambda u: u.update(complete=True),
            lambda u: u.update(truncated='false'),
            lambda u: u.update(max_entities=20001),
            lambda u: u.update(observations=[u['observations'][0]] * 20001),
            lambda u: u.update(containers=[u['containers'][0]] * 2049),
            lambda u: u['observations'][0].update(container_handle=[]),
            lambda u: u.update(omissions=[]),
            lambda u: u['observations'][0].update(target_handle='FF'),
            lambda u: u['observations'][0].update(owner_handle='B'),
            lambda u: u['observations'][0].update(container_handle='20', owner_handle='20'),
            lambda u: u['observations'][3].update(parent_insert_handle='102', owner_handle='102'),
            lambda u: u['observations'].append(dict(u['observations'][0])),
            lambda u: u['containers'].append(dict(u['containers'][0])),
            lambda u: u['observations'][8].update(target_handle='10'),
        ]
        for mutate in mutations:
            self.native = copy.deepcopy(original)
            mutate(self.native['usage'])
            with self.assertRaises(p.DependencyError): self.issue()
        self.native = copy.deepcopy(original)
        del self.native['fonts'][0]['record_handle']
        with self.assertRaises(p.DependencyError): self.issue()

    def test_usage_does_not_relax_completion_or_source_hash(self):
        self.add_usage()
        self.test_source_drift_and_unproven_execution()

    def test_usage_raw_hash_and_old_output_guards(self):
        self.add_usage()
        # Keep only the existing resolvable font so the shared CLI success fixture still returns 0.
        self.native['fonts'] = self.native['fonts'][:1]
        self.native['xrefs'] = []
        self.test_cli_evidence_hash_marker_and_exclusive_output()

    def test_missing_coverage_cannot_be_promoted(self):
        self.native['omissions']=[]
        with self.assertRaises(p.DependencyError):self.build()

if __name__=='__main__':unittest.main()
