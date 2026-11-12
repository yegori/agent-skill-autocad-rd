"""Synthetic PDFs/filesystem only. Never reads project PDFs or activates native applications."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import pymupdf as fitz

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('assemble_pdf', ROOT / 'toolkit/assemble_pdf.py')
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)


class AssemblyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.inputs = self.root / 'вход'; self.inputs.mkdir()
        self.first = self.inputs / 'z_обложка.pdf'; self.second = self.inputs / 'a_лист.pdf'
        self.make_pdf(self.first, ['FIRST-A', 'FIRST-B']); self.make_pdf(self.second, ['LAST-C'])
        self.output = self.root / 'новый.pdf'; self.report = self.root / 'новый.json'
        self.plan = {'inputs': [self.entry(self.first, 2), self.entry(self.second, 1)], 'expected_total_pages': 3}
        self.before = {p: p.read_bytes() for p in (self.first, self.second)}

    def make_pdf(self, path, labels, password=False):
        with fitz.open() as doc:
            for i, label in enumerate(labels):
                page = doc.new_page(width=300+i*20, height=400)
                page.insert_text((30, 40), label)
                if i: page.set_rotation(90)
            doc.set_metadata({'title': 'SOURCE_TITLE_NOT_INFERRED'})
            options = dict(encryption=fitz.PDF_ENCRYPT_AES_256, user_pw='test-user', owner_pw='test-owner') if password else {}
            doc.save(path, **options)

    def entry(self, path, pages):
        return {'path': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'pages': pages}

    def run_assembly(self, **kwargs):
        return mod.assemble(self.plan, str(self.inputs), str(self.output), str(self.report), **kwargs)

    def unchanged(self):
        for path, data in self.before.items(): self.assertEqual(path.read_bytes(), data)

    def test_unicode_order_two_plus_one_and_default_metadata(self):
        result = self.run_assembly()
        self.assertEqual(result['status'], 'assembled_pending_coordinator_qa', result)
        with fitz.open(self.output) as doc:
            self.assertEqual([p.get_text().strip() for p in doc], ['FIRST-A', 'FIRST-B', 'LAST-C'])
            self.assertEqual([p.rotation for p in doc], [0, 90, 0])
            self.assertEqual(doc.metadata['title'], '')
        self.assertEqual(result['published'], [str(self.output), str(self.report)])
        self.assertFalse(result['engineering_release_approved']); self.assertFalse(result['publication_pair_atomic'])
        self.assertEqual(json.loads(self.report.read_text())['output']['pages'], 3)
        self.assertTrue((Path(result['run_dir']) / 'assembled.pdf').exists())
        self.unchanged()

    def test_cli_utf8_plan_and_duplicate_invalid_utf8_fail_before(self):
        plan_path = self.root / 'план.json'; plan_path.write_bytes(json.dumps(self.plan, ensure_ascii=False).encode('utf-8'))
        args = [sys.executable, '-I', str(ROOT/'toolkit/assemble_pdf.py'), '--plan', str(plan_path),
                '--input-root', str(self.inputs), '--output', str(self.output), '--report', str(self.report)]
        result = subprocess.run(args, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual(json.loads(result.stdout)['plan_sha256'], hashlib.sha256(plan_path.read_bytes()).hexdigest())
        for data in (b'{"inputs":[],"inputs":[]}', b'{"bad":"\xff"}'):
            plan_path.write_bytes(data)
            failed = subprocess.run(args, capture_output=True, timeout=30)
            self.assertEqual(failed.returncode, 1)
        self.unchanged()

    def test_wrong_hash_and_actual_page_count(self):
        for key, value, code in [('sha256', '0'*64, 'input_hash_mismatch'), ('pages', 1, 'input_page_count_mismatch')]:
            with self.subTest(key=key):
                plan = json.loads(json.dumps(self.plan)); plan['inputs'][0][key] = value
                if key == 'pages': plan['expected_total_pages'] = 2
                result = mod.assemble(plan, str(self.inputs), str(self.output), str(self.report))
                self.assertEqual(result['status'], 'failed'); self.assertIn(code, result['error'])
                self.assertFalse(self.output.exists()); self.assertFalse(self.report.exists())
        self.unchanged()

    def test_plan_total_boolean_duplicate_escape_reserved_and_absolute(self):
        variants = []
        p = json.loads(json.dumps(self.plan)); p['expected_total_pages'] = 4; variants.append(p)
        p = json.loads(json.dumps(self.plan)); p['expected_total_pages'] = True; variants.append(p)
        p = json.loads(json.dumps(self.plan)); p['inputs'][0]['pages'] = True; variants.append(p)
        p = json.loads(json.dumps(self.plan)); p['inputs'][1] = dict(p['inputs'][0], path='./'+self.first.name); p['expected_total_pages']=4; variants.append(p)
        for name in ('../outside.pdf', str(self.first), 'C:relative.pdf', 'NUL.pdf', 'CON .pdf', 'bad./x.pdf'):
            p = json.loads(json.dumps(self.plan)); p['inputs'][0]['path'] = name; variants.append(p)
        for plan in variants:
            with self.subTest(plan=plan):
                with self.assertRaises(ValueError): mod.assemble(plan, str(self.inputs), str(self.output), str(self.report))
        self.assertFalse(list(self.root.glob('assemble-pdf-*'))); self.unchanged()

    def test_destinations_existing_alias_and_inside_inputs_refused(self):
        for target in (self.output, self.report):
            target.write_bytes(b'KEEP')
            with self.assertRaises(ValueError): self.run_assembly()
            self.assertEqual(target.read_bytes(), b'KEEP'); target.unlink()
        with self.assertRaises(ValueError): mod.assemble(self.plan, str(self.inputs), str(self.first), str(self.report))
        with self.assertRaises(ValueError): mod.assemble(self.plan, str(self.inputs), str(self.inputs/'new.pdf'), str(self.report))
        with self.assertRaises(ValueError): mod.assemble(self.plan, str(self.inputs), str(self.output), str(self.report), str(self.inputs))
        self.unchanged()

    def test_identical_bytes_different_filename_duplicate_refused(self):
        copy = self.inputs / 'duplicate.pdf'; copy.write_bytes(self.first.read_bytes())
        self.plan['inputs'][1] = self.entry(copy, 2); self.plan['expected_total_pages'] = 4
        with self.assertRaisesRegex(ValueError, 'duplicate_input_hash'): self.run_assembly()
        self.unchanged()

    def test_missing_parser_module_fails_before_private_work(self):
        import builtins
        importing = builtins.__import__
        def missing(name, *args, **kwargs):
            if name == 'pymupdf': raise ImportError('inert-module-unavailable')
            return importing(name, *args, **kwargs)
        with patch('builtins.__import__', missing):
            with self.assertRaisesRegex(ImportError, 'inert-module-unavailable'): self.run_assembly()
        self.assertFalse(list(self.root.glob('assemble-pdf-*')))

    def test_changed_during_held_read_refused(self):
        opening = Path.open
        class ChangingReader:
            def __init__(inner, stream): inner.stream = stream
            def __enter__(inner): return inner
            def __exit__(inner, *args): inner.stream.close()
            def fileno(inner): return inner.stream.fileno()
            def read(inner, size):
                data = inner.stream.read(size); self.first.write_bytes(b'inert-external-mutation'); return data
        def changed(path, *args, **kwargs):
            stream = opening(path, *args, **kwargs)
            return ChangingReader(stream) if path == self.first and args == ('rb',) else stream
        with patch.object(Path, 'open', changed):
            with self.assertRaisesRegex(ValueError, 'input_changed_during_read'): mod.read_bound(self.first)
        self.assertFalse(self.output.exists())

    def test_password_and_invalid_pdf(self):
        for name, encrypted in [('password.pdf', True), ('invalid.pdf', False)]:
            path = self.inputs / name
            if encrypted: self.make_pdf(path, ['SECRET-INERT'], password=True)
            else: path.write_bytes(b'not-a-pdf')
            plan = {'inputs':[self.entry(path,1)], 'expected_total_pages':1}
            result = mod.assemble(plan, str(self.inputs), str(self.output), str(self.report))
            self.assertEqual(result['status'], 'failed'); self.assertFalse(self.output.exists())

    def test_hardlink_and_mocked_reparse(self):
        alias = self.inputs / 'hardlink.pdf'; os.link(self.first, alias)
        with self.assertRaisesRegex(ValueError, 'hardlink'): self.run_assembly()
        alias.unlink()
        original = Path.lstat
        def mocked(path, *args, **kwargs):
            info = original(path, *args, **kwargs)
            return SimpleNamespace(st_mode=info.st_mode, st_file_attributes=0x400) if path == self.first else info
        with patch.object(Path, 'lstat', mocked):
            with self.assertRaisesRegex(ValueError, 'reparse'): self.run_assembly()
        self.unchanged()

    def test_symlink_source_or_root(self):
        link = self.root / 'linked'
        try: link.symlink_to(self.inputs, target_is_directory=True)
        except OSError as error: self.skipTest('symlink privilege unavailable: '+str(error))
        with self.assertRaisesRegex(ValueError, 'reparse'): mod.assemble(self.plan, str(link), str(self.output), str(self.report))

    def test_postflight_changed_bytes_and_same_bytes_new_identity(self):
        verify = mod._verify_sources
        for identity_only in (False, True):
            with self.subTest(identity_only=identity_only):
                def mutate(bindings):
                    if identity_only:
                        replacement = self.root / 'replacement.tmp'; replacement.write_bytes(self.first.read_bytes()); os.replace(replacement, self.first)
                    else: self.first.write_bytes(b'changed-by-test')
                    verify(bindings)
                with patch.object(mod, '_verify_sources', mutate): result = self.run_assembly()
                self.assertEqual(result['status'], 'failed'); self.assertFalse(self.output.exists())
                self.first.write_bytes(self.before[self.first])

    def test_parser_uses_captured_hashed_bytes_not_source_reopen(self):
        original = fitz.open; approved = self.first.read_bytes(); seen = []
        def opening(*args, **kwargs):
            self.assertFalse(args, 'production parser was given a path')
            data = kwargs.get('stream')
            if data == approved:
                seen.append(data); self.first.write_bytes(b'changed-after-capture')
            return original(*args, **kwargs)
        with patch.object(fitz, 'open', opening): result = self.run_assembly()
        self.assertEqual(seen, [approved]); self.assertEqual(result['status'], 'failed')
        self.assertFalse(self.output.exists())

    def test_private_temp_collision_no_overwrite(self):
        work = self.root / 'inert-temp'; work.mkdir(); (work/'assembled.pdf').write_bytes(b'KEEP')
        with patch.object(mod.tempfile, 'mkdtemp', return_value=str(work)): result = self.run_assembly()
        self.assertEqual(result['status'], 'failed'); self.assertEqual((work/'assembled.pdf').read_bytes(), b'KEEP')
        self.assertFalse(self.output.exists()); self.unchanged()

    def test_pdf_publication_collision_no_overwrite(self):
        def publishing(data, target):
            target.write_bytes(b'COMPETING')
            mod._publish_new(data, target)
        result = self.run_assembly(publisher=publishing)
        self.assertEqual(result['status'], 'failed'); self.assertEqual(result['published'], [])
        self.assertEqual(self.output.read_bytes(), b'COMPETING'); self.assertFalse(self.report.exists()); self.unchanged()

    def test_second_publication_collision_explicit_partial_pair(self):
        def publishing(data, target):
            mod._publish_new(data, target)
            if target == self.output: self.report.write_bytes(b'COMPETING-REPORT')
        result = self.run_assembly(publisher=publishing)
        self.assertEqual(result['status'], 'failed'); self.assertEqual(result['published'], [str(self.output)])
        self.assertEqual(self.report.read_bytes(), b'COMPETING-REPORT'); self.assertTrue(result['partial_publication_possible'])
        self.unchanged()

    def test_source_changed_during_publication_is_failed_partial(self):
        def publishing(data, target):
            mod._publish_new(data, target)
            if target == self.output: self.second.write_bytes(b'inert-external-change')
        result = self.run_assembly(publisher=publishing)
        self.assertEqual(result['status'], 'failed'); self.assertEqual(result['published'], [str(self.output)])
        self.assertFalse(self.report.exists()); self.assertTrue(result['partial_publication_possible'])

    def test_partial_write_retained_and_evidence_failure_honest(self):
        def partial(data, target):
            with target.open('xb') as stream: stream.write(data[:10])
            raise OSError('inert-write-error')
        result = self.run_assembly(publisher=partial)
        self.assertEqual(result['status'], 'failed'); self.assertEqual(self.output.stat().st_size, 10)
        self.assertTrue(result['partial_publication_possible']); self.unchanged()
        self.output.unlink()  # Test fixture only, never a production cleanup policy.
        original = mod._publish_new
        def no_result(data, target):
            if target.name == 'result.json': raise OSError('inert-evidence-error')
            return original(data, target)
        with patch.object(mod, '_publish_new', no_result): result = self.run_assembly()
        self.assertEqual(result['status'], 'failed'); self.assertTrue(result['evidence_write_uncertain'])


if __name__ == '__main__': unittest.main()
