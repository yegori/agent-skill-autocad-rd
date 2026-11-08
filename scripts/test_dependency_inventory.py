import contextlib
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
    def test_missing_coverage_cannot_be_promoted(self):
        self.native['omissions']=[]
        with self.assertRaises(p.DependencyError):self.build()

if __name__=='__main__':unittest.main()
