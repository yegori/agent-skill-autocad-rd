import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

SPEC = importlib.util.spec_from_file_location("stage_inputs", Path(__file__).resolve().parents[1]/"toolkit/stage_inputs.py")
p = importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(p)


class StageInputsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve();self.source = self.root/'input';self.source.mkdir()
        self.env = self.root/'env';self.env.mkdir();(self.source/'001 full name.dwg').write_bytes(b'fixture only')
        (self.source/'xref.dwg').write_bytes(b'fake dependency');(self.env/'test.pc3').write_bytes(b'fake profile')
        h = lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
        self.spec = {'schema_version':1,'coverage':'explicit_not_discovered','plan_id':'a'*64,'step_id':str(uuid.uuid4()),
          'files':[{'path':'001 full name.dwg','sha256':h(self.source/'001 full name.dwg'),'role':'drawing'},
                   {'path':'xref.dwg','sha256':h(self.source/'xref.dwg'),'role':'project_dependency'}],
          'environment':[{'root':'plotters','path':'test.pc3','sha256':h(self.env/'test.pc3')}],
          'plot_options':{'device':'DWG To PDF.pc3','cover':False}}
        self.dest = self.root/'stage'

    def prepare(self):return p.prepare(self.spec,self.source,{'plotters':str(self.env)},self.dest)

    def test_separate_identical_copies_full_names_and_no_execution(self):
        result = self.prepare();self.assertFalse(result['execution_authorized'])
        for tree in ('snapshot','working'):
            self.assertEqual((self.dest/tree/'001 full name.dwg').read_bytes(),b'fixture only')
        self.assertEqual(p.verify(self.dest,expected_stage_id=result['stage_id'])['working_changes'],[])
        self.assertEqual((self.env/'test.pc3').read_bytes(),b'fake profile')

    def test_work_change_only_explicit_and_never_snapshot(self):
        self.prepare();(self.dest/'working/001 full name.dwg').write_bytes(b'changed work')
        with self.assertRaises(p.StageError):p.verify(self.dest)
        self.assertEqual(p.verify(self.dest,allow_work_changes=True)['working_changes'],['001 full name.dwg'])
        (self.dest/'snapshot/001 full name.dwg').write_bytes(b'changed snapshot')
        with self.assertRaises(p.StageError):p.verify(self.dest,allow_work_changes=True)

    def test_source_and_environment_drift_refuse(self):
        self.prepare()
        for path in (self.source/'001 full name.dwg',self.env/'test.pc3'):
            old=path.read_bytes();path.write_bytes(b'changed')
            with self.assertRaises(p.StageError):p.verify(self.dest)
            path.write_bytes(old)

    def test_missing_dependency_and_wrong_hash_refuse_before_destination(self):
        (self.source/'xref.dwg').unlink()
        with self.assertRaises((OSError,p.StageError)):self.prepare()
        self.assertFalse(self.dest.exists())
        (self.source/'xref.dwg').write_bytes(b'wrong')
        with self.assertRaises(p.StageError):self.prepare()
        self.assertFalse(self.dest.exists())

    def test_existing_destination_and_original_files_never_replaced(self):
        self.prepare();before=(self.dest/'manifest.json').read_bytes()
        with self.assertRaises(FileExistsError):self.prepare()
        self.assertEqual((self.dest/'manifest.json').read_bytes(),before)
        self.assertEqual((self.source/'001 full name.dwg').read_bytes(),b'fixture only')

    def test_manifest_identity_and_preparing_are_not_accepted(self):
        self.prepare();path=self.dest/'manifest.json';data=json.loads(path.read_text(encoding='utf-8'))
        data['spec']['plot_options']['cover']=True;path.write_text(json.dumps(data),encoding='utf-8')
        with self.assertRaises(p.StageError):p.verify(self.dest)
        data['status']='preparing';path.write_text(json.dumps(data),encoding='utf-8')
        with self.assertRaises(p.StageError):p.verify(self.dest)

    def test_paths_duplicates_and_overlaps_refuse(self):
        for value in ('../escape.dwg','/escape.dwg','x\\a.dwg','C:/a.dwg'):
            spec=copy.deepcopy(self.spec);spec['files'][0]['path']=value
            with self.assertRaises(p.StageError):p.prepare(spec,self.source,{'plotters':str(self.env)},self.dest)
        with self.assertRaises(p.StageError):p.prepare(self.spec,self.source,{'plotters':str(self.env)},self.source/'stage')
        self.spec['files'].append(copy.deepcopy(self.spec['files'][0]))
        with self.assertRaises(p.StageError):self.prepare()

    def test_extra_files_and_missing_working_refuse(self):
        self.prepare();extra=self.dest/'snapshot/extra.dwg';extra.write_bytes(b'extra')
        with self.assertRaises(p.StageError):p.verify(self.dest)
        extra.unlink();(self.dest/'working/xref.dwg').unlink()
        with self.assertRaises(p.StageError):p.verify(self.dest,allow_work_changes=True)

    def test_copy_failure_retains_unprepared_partial(self):
        with patch.object(p.shutil,'copyfileobj',side_effect=OSError('synthetic copy failure')):
            with self.assertRaises(OSError):self.prepare()
        data=json.loads((self.dest/'manifest.json').read_text(encoding='utf-8'))
        self.assertEqual(data['status'],'preparing')
        with self.assertRaises(p.StageError):p.verify(self.dest)

    def test_link_refused_before_descent(self):
        self.prepare();link=self.dest/'snapshot/link'
        # Portable deterministic traversal test; no developer-mode/symlink privileges needed.
        real=Path.lstat;visited=[]
        link.mkdir();(link/'would_walk.txt').write_bytes(b'must not descend')
        def lstat(path,*args,**kwargs):
            visited.append(path)
            if path==link:
                import types,stat
                return types.SimpleNamespace(st_mode=stat.S_IFLNK,st_file_attributes=0x400)
            return real(path,*args,**kwargs)
        with patch.object(Path,'lstat',lstat):
            with self.assertRaises(p.StageError):p.verify(self.dest)
        self.assertFalse(any(path.is_relative_to(link) and path!=link for path in visited))

    def test_expected_id_and_missing_environment_refuse(self):
        self.prepare()
        with self.assertRaises(p.StageError):p.verify(self.dest,expected_stage_id='b'*64)
        (self.env/'test.pc3').unlink()
        with self.assertRaises((OSError,p.StageError)):p.verify(self.dest)


if __name__=='__main__':unittest.main()
