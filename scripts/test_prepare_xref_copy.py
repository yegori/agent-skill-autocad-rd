"""Offline explicit-map validation tests; fake native JSON is NOT Autodesk API proof."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import unittest

loader = importlib.util.spec_from_file_location('prepare', Path(__file__).resolve().parents[1] / 'toolkit/prepare_xref_copy.py')
p = importlib.util.module_from_spec(loader);loader.loader.exec_module(p)


class PrepareCopyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='xref-copy-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.src = self.root / 'sources';self.src.mkdir()
        self.issue = self.root / 'issue';self.issue.mkdir()
        (self.issue / 'refs' / 'nested').mkdir(parents=True)
        self.source = self.src / '001 [sample].dwg';self.source.write_bytes(b'original')
        self.host = self.root / 'host' / 'safe.dwg';self.host.parent.mkdir();self.host.write_bytes(b'safe host')
        self.evidence = self.root / 'evidence'
        self.spec = {'schema_version': 1, 'source_root': str(self.src), 'source_path': self.source.name,
                     'source_sha256': p.r.digest(self.source), 'issue_root': str(self.issue),
                     'output_path': 'prepared/' + self.source.name, 'mappings': []}
        for i in range(3):
            file = self.issue / 'refs' / 'nested' / f'{i}.dwg';file.write_bytes(f'target{i}'.encode())
            self.spec['mappings'].append({'handle': str(i+1), 'name': f'ref{i}',
                'old_path': f'Z:\\old\\missing{i}.dwg', 'new_path': f'..\\refs\\nested\\{i}.dwg',
                'target_sha256': p.r.digest(file)})

    def pre(self):
        return p.preflight(self.spec, self.host, p.r.digest(self.host), self.evidence)

    def fake(self):
        self.pre()
        request = p.read_json(self.evidence / 'request.json')
        Path(request['output']).write_bytes(b'reserialized candidate')
        p.write_new(self.evidence / 'owned.json', {'AllDone': True, 'TimedOut': False,
            'RootExitedBeforeStop': False, 'RootExitCodeBeforeStop': None, 'Terminated': True, 'ElapsedSeconds': .1})
        p.write_new(self.evidence / 'native.json', {'schema_version': 1, 'kind': 'explicit_xref_copy',
            'status': 'prepared_candidate', 'completion_hold': 'inside_managed_prepare_command',
            'request_sha256': p.r.digest(self.evidence / 'request.json'), 'source_sha256': request['source_sha256'],
            'output': request['output'], 'output_sha256': p.r.digest(Path(request['output'])),
            'changed_count': 3, 'verified_direct_xref_count': 3, 'mappings': request['mappings'],
            'dependency_complete': False, 'semantic_identity_proven': False, 'execution_authorized': False})
        (self.evidence / 'native.complete').write_text('ALLDONE\n', encoding='utf-8')
        return request

    def modify(self, file, change):
        path = self.evidence / file;data = p.read_json(path);change(data)
        path.write_text(json.dumps(data), encoding='utf-8')

    def assert_not_published(self):
        self.assertFalse((self.evidence / 'prepared.json').exists())
        self.assertFalse((self.issue / self.spec['output_path']).exists())

    def test_explicit_three_preflight_missing_old_targets_allowed(self):
        self.assertEqual(self.pre()['status'], 'preflight_ready')
        _, request, output = p.check_bindings(self.evidence)
        self.assertEqual(Path(request['source']).name, self.source.name)
        self.assertEqual(Path(request['output']).name, self.source.name)
        self.assertEqual(len(request['mappings']), 3)
        self.assertEqual(self.source.read_bytes(), b'original')
        self.assertFalse(output.exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows no-replace publication API only')
    def test_happy_fake_postflight_preserves_source_and_separates_provenance(self):
        self.fake()
        self.assertEqual(p.finish(self.evidence)['changed_count'], 3)
        report = p.read_json(self.evidence / 'prepared.json')
        self.assertIsNone(report['exit_code']);self.assertFalse(report['dependency_complete'])
        self.assertFalse(report['semantic_identity_proven']);self.assertFalse(report['publication_approved'])
        self.assertEqual(self.source.read_bytes(), b'original')
        with self.assertRaises(Exception):
            p.finish(self.evidence)

    def test_invalid_specs_fail_before_creating_evidence(self):
        original = copy.deepcopy(self.spec)
        cases = [lambda s: s.update(source_sha256='0'*64),
            lambda s: s.update(source_path='../outside.dwg'),
            lambda s: s.update(output_path='prepared/renamed.dwg'),
            lambda s: s.update(output_path='../escape.dwg'),
            lambda s: s.update(output_path=self.source.name),
            lambda s: s.update(mappings=s['mappings'][:2]),
            lambda s: s['mappings'][1].update(handle='1'),
            lambda s: s['mappings'][1].update(name='REF0'),
            lambda s: s['mappings'][1].update(new_path=s['mappings'][0]['new_path'], target_sha256=s['mappings'][0]['target_sha256']),
            lambda s: s['mappings'][0].update(new_path=s['mappings'][0]['old_path']),
            lambda s: s['mappings'][0].update(target_sha256='0'*64)]
        for change in cases:
            with self.subTest(change=change):
                self.spec = copy.deepcopy(original);change(self.spec)
                with self.assertRaises(Exception): self.pre()
                self.assertFalse(self.evidence.exists())

    def test_rooted_unc_drive_ads_escape_and_windows_alias_new_paths(self):
        for value in ('C:\\target.dwg', 'C:target.dwg', '\\\\server\\share\\a.dwg', '\\refs\\0.dwg',
                      '..\\..\\outside.dwg', '..\\refs\\nested\\0.dwg:ads', '..\\refs\\nested\\NUL.dwg',
                      '..\\refs\\nested\\0.dwg.', '..\\refs\\nested\\*.dwg', '..//refs/0.dwg', '.\\'):
            with self.subTest(value=value):
                self.spec['mappings'][0]['new_path'] = value
                with self.assertRaises(Exception): self.pre()
                self.assertFalse(self.evidence.exists())

    def test_missing_target_and_existing_output_directory(self):
        target = self.issue / 'refs/nested/0.dwg';target.unlink()
        with self.assertRaises(Exception): self.pre()
        self.assertFalse(self.evidence.exists())
        target.write_bytes(b'target0');(self.issue / 'prepared').mkdir()
        with self.assertRaises(Exception): self.pre()
        self.assertFalse(self.evidence.exists())

    def test_source_target_and_host_hardlinks_rejected(self):
        for file in (self.source, self.issue / 'refs/nested/0.dwg', self.host):
            with self.subTest(file=file):
                alias = self.root / 'alias';os.link(file, alias)
                try:
                    with self.assertRaises(Exception): self.pre()
                    self.assertFalse(self.evidence.exists())
                finally: alias.unlink()

    def test_reparse_before_open(self):
        # Symlink creation on Windows may require Developer Mode; do not weaken the assertion on supported hosts.
        target = self.issue / 'refs/nested/0.dwg';target.unlink()
        try:
            target.symlink_to(self.source)
        except OSError:
            self.skipTest('symlink privilege unavailable')
        with self.assertRaises(Exception): self.pre()
        self.assertFalse(self.evidence.exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows junction test')
    def test_junction_target_rejected_before_hash(self):
        alias = self.issue / 'alias'
        result = subprocess.run(['cmd', '/c', 'mklink', '/J', str(alias), str(self.issue / 'refs')], capture_output=True)
        if result.returncode:
            self.skipTest('junction unavailable: ' + result.stderr.decode(errors='replace'))
        self.spec['mappings'][0]['new_path'] = '..\\alias\\nested\\0.dwg'
        with self.assertRaisesRegex(p.PrepareError, 'prepare_reparse_point'):
            self.pre()
        self.assertFalse(self.evidence.exists())
        alias.rmdir()

    def test_no_automatic_retry_or_cleanup(self):
        self.pre()
        with self.assertRaises(Exception): self.pre()
        self.assertTrue((self.evidence / 'request.json').exists())

    def test_wrong_native_result_fails_closed(self):
        request = self.fake()
        baseline = (self.evidence / 'native.json').read_text(encoding='utf-8')
        cases = [lambda d: d.update(changed_count=2), lambda d: d.update(changed_count=True),
                 lambda d: d.update(source_sha256='0'*64), lambda d: d.update(output_sha256='0'*64),
                 lambda d: d.update(request_sha256='0'*64), lambda d: d.update(output=str(self.source)),
                 lambda d: d.update(completion_hold='inside_managed_command'),
                 lambda d: d.update(verified_direct_xref_count=2),
                 lambda d: d['mappings'][0].update(old_path='different'),
                 lambda d: d['mappings'][0].update(new_path='different'),
                 lambda d: d['mappings'][0].update(target_sha256='0'*64)]
        for change in cases:
            with self.subTest(change=change):
                (self.evidence / 'native.json').write_text(baseline, encoding='utf-8')
                self.modify('native.json', change)
                with self.assertRaises(Exception): p.finish(self.evidence)
                self.assert_not_published()
                self.assertTrue(Path(request['output']).exists())

    def test_marker_early_exit_timeout_cleanup_uncertainty(self):
        self.fake()
        baseline = (self.evidence / 'owned.json').read_text(encoding='utf-8')
        for field, value in [('AllDone', False), ('TimedOut', True), ('RootExitedBeforeStop', True),
                             ('RootExitedBeforeStop', None), ('RootExitCodeBeforeStop', 0), ('Terminated', False)]:
            with self.subTest(field=field, value=value):
                (self.evidence / 'owned.json').write_text(baseline, encoding='utf-8')
                self.modify('owned.json', lambda d: d.update({field: value}))
                with self.assertRaises(Exception): p.finish(self.evidence)
                self.assert_not_published()
        (self.evidence / 'owned.json').write_text(baseline, encoding='utf-8')
        (self.evidence / 'native.complete').unlink()
        with self.assertRaises(Exception): p.finish(self.evidence)
        self.assert_not_published()

    def test_output_collision_and_drift_after_native(self):
        self.fake()
        out = self.issue / self.spec['output_path'];out.write_bytes(b'protected existing')
        with self.assertRaises(Exception): p.finish(self.evidence)
        self.assertEqual(out.read_bytes(), b'protected existing');out.unlink()
        for file in (self.source, self.issue / 'refs/nested/0.dwg', self.evidence / 'input' / self.source.name, self.host):
            before = file.read_bytes();file.write_bytes(b'mutation')
            with self.assertRaises(Exception): p.finish(self.evidence)
            self.assert_not_published();file.write_bytes(before)

    def test_static_native_boundary_supplement_only(self):
        code = (Path(__file__).resolve().parents[1] / 'toolkit/dependencies/PrepareXrefCopy.cs').read_text(encoding='utf-8')
        self.assertIn('b.PathName = m.new_path;', code)
        self.assertEqual(code.count('.ReadDwgFile('), 2)
        self.assertEqual(code.count('.SaveAs('), 1)
        self.assertNotIn('DocumentManager.Open(', code)
        self.assertNotIn('.ResolveXrefs(', code)
        self.assertLess(code.index('Verify(saved, expected)'), code.index('NewText(q.marker'))
        self.assertIn('while (true) System.Threading.Thread.Sleep', code)


if __name__ == '__main__':
    unittest.main()
