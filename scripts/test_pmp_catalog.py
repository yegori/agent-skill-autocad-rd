import importlib.util
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

p = load('pmp_catalog_tests', ROOT/'toolkit/pmp_catalog.py')
writer = load('pmp_writer_tests', ROOT/'toolkit/add_pmp_size.py')


class PmpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def pmp(self, relative='selected/DWG To PDF.pmp', size=None, desc=None):
        target = self.root/relative; target.parent.mkdir(parents=True, exist_ok=True)
        data = {'data': {'udm': {'media': {'size': size or {}, 'description': desc or {}}}}}
        target.write_text('PIAFILEVERSION_3.0,json\n'+json.dumps(data, ensure_ascii=False), encoding='utf-8')
        return target

    def test_registry_current_profiles_not_arbitrary_profiles(self):
        base = r'Software\Autodesk\AutoCAD\R24.3'
        values = {
            base: {},
            base + r'\CAD': {'CurProfile': 'Current'},
            base + r'\CAD\Profiles\Current\General': {'PrinterDescDir': 'D:/selected/PMP'},
            base + r'\C3D': {},
            base + r'\C3D\Profiles': {'CurProfile': 'Civil Current'},
            base + r'\C3D\Profiles\Civil Current\General': {'PrinterDescDir': 'D:/civil/PMP'},
        }
        class Key:
            def __init__(self, name): self.name = name
            def __enter__(self): return self
            def __exit__(self, *args): pass
        def open_key(hive, name):
            if name not in values: raise FileNotFoundError(name)
            return Key(name)
        def enum_key(key, index):
            if index >= 2: raise OSError('end')
            return ['CAD','C3D'][index]
        def query(key, name):
            if name not in values[key.name]: raise FileNotFoundError(name)
            return values[key.name][name], 1
        registry = types.SimpleNamespace(HKEY_CURRENT_USER=1, OpenKey=open_key, EnumKey=enum_key, QueryValueEx=query)
        with patch.object(p.os, 'name', 'nt'), patch.dict('sys.modules', {'winreg':registry}):
            self.assertEqual(p.current_profile_dirs(), ['D:/selected/PMP','D:/civil/PMP'])

    def test_civil_only_fallback(self):
        f = self.pmp('Autodesk/C3D 2024/rus/Plotters/PMP Files/DWG To PDF.pmp')
        r = p.resolve_pmp(appdata=self.root, profile_dirs=[])
        self.assertEqual(r['path'], str(f)); self.assertEqual(r['status'], 'found')

    def test_autocad_only_fallback(self):
        f = self.pmp('Autodesk/AutoCAD 2024/R24.3/enu/Plotters/PMP Files/DWG To PDF.pmp')
        self.assertEqual(p.resolve_pmp(appdata=self.root, profile_dirs=[])['path'], str(f))

    def test_multiple_products_refuse_guess(self):
        self.pmp('Autodesk/C3D 2024/rus/Plotters/PMP Files/DWG To PDF.pmp')
        self.pmp('Autodesk/AutoCAD 2024/R24.3/enu/Plotters/PMP Files/DWG To PDF.pmp')
        r = p.resolve_pmp(appdata=self.root, profile_dirs=[])
        self.assertEqual(r['status'], 'ambiguous'); self.assertIsNone(r['path'])

    def test_explicit_wins_and_missing_never_falls_back(self):
        f = self.pmp(); self.test_civil_only_fallback()
        self.assertEqual(p.resolve_pmp(f, appdata=self.root, profile_dirs=[])['path'], str(f))
        self.assertEqual(p.resolve_pmp(self.root/'absent', appdata=self.root, profile_dirs=[])['status'], 'missing')

    def test_current_profile_directory_over_known_location(self):
        f = self.pmp(); self.test_civil_only_fallback()
        self.assertEqual(p.resolve_pmp(appdata=self.root, profile_dirs=[f.parent])['path'], str(f))
        self.assertEqual(p.resolve_pmp(appdata=self.root, profile_dirs=[self.root/'not_created'])['status'], 'missing')

    def test_same_path_profiles_deduplicated_and_multiple_refused(self):
        f = self.pmp(); g = self.pmp('second/DWG To PDF.pmp')
        self.assertEqual(p.resolve_pmp(profile_dirs=[f.parent, f.parent])['status'], 'found')
        self.assertEqual(p.resolve_pmp(profile_dirs=[f.parent, g.parent])['status'], 'ambiguous')
        self.assertEqual(p.resolve_pmp(profile_dirs=[f.parent, self.root/'missing-profile'])['status'], 'ambiguous')

    def test_localized_name_dimensions_and_tolerance(self):
        f = self.pmp(size={'0': {'name':'User-1','localized_name':'Прежний размер листа (891.00 x 420.00 мм)'}})
        entries = p.read_catalog(f)[2]
        self.assertEqual(p.match_paper(entries, 'User-1'), 'exact_name')
        self.assertEqual(p.match_paper(entries, 'UserDefinedMetric (891.01 x 420.00мм)'), 'dimensions_only')
        self.assertEqual(p.match_paper(entries, 'UserDefinedMetric (891.10 x 420.00мм)'), 'missing')
        self.assertEqual(p.match_paper(entries, 'UserDefinedMetric (420.00 x 891.00мм)'), 'missing')

    def test_description_bounds(self):
        f = self.pmp(size={'0':{'name':'User-1','media_description_name':'D'}},
                     desc={'0':{'name':'D','media_bounds_urx':630,'media_bounds_ury':297}})
        self.assertEqual(p.match_paper(p.read_catalog(f)[2], 'UserDefinedMetric (630.00 x 297.00мм)'), 'dimensions_only')

    def test_same_dimensions_never_write_or_backup(self):
        f = self.pmp(size={'0':{'name':'User-1','localized_name':'Прежний (891.00 x 420.00 мм)'}})
        before = f.read_bytes()
        self.assertEqual(writer.add_sizes(f,['UserDefinedMetric (891.00 x 420.00мм)']), [])
        self.assertEqual(f.read_bytes(), before); self.assertEqual(len(list(f.parent.iterdir())),1)

    def test_duplicate_names_in_request_and_sparse_keys_preserved(self):
        f = self.pmp(size={'1':{'name':'untouched'}}, desc={'1':{'name':'RDCI-0'}})
        before = f.read_bytes(); name = 'UserDefinedMetric (891.00 x 420.00мм)'
        self.assertEqual(writer.add_sizes(f,[name,name]),[name])
        data = p.read_catalog(f)[1]['data']['udm']['media']
        self.assertEqual(data['size']['1']['name'],'untouched'); self.assertEqual(data['description']['1']['name'],'RDCI-0')
        backups = list(f.parent.glob('*.bak_*')); self.assertEqual(len(backups),1); self.assertEqual(backups[0].read_bytes(),before)

    def test_invalid_late_size_does_not_partially_write(self):
        f = self.pmp(); before = f.read_bytes()
        with self.assertRaises(ValueError): writer.add_sizes(f,['UserDefinedMetric (891 x 420мм)','garbage'])
        self.assertEqual(f.read_bytes(),before); self.assertEqual(len(list(f.parent.iterdir())),1)

    def test_missing_discovery_does_not_create_configuration(self):
        self.assertEqual(p.resolve_pmp(appdata=self.root,profile_dirs=[])['status'],'missing')
        self.assertEqual(list(self.root.iterdir()),[])


if __name__ == '__main__': unittest.main()
