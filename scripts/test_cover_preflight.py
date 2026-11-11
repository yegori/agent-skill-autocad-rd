"""Synthetic local files only. No Word/COM activation, DOC parser or user fixtures."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cover_preflight", ROOT / "toolkit/cover_preflight.py")
cover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cover)


class CoverPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "template.docx"
        self.source.write_bytes(b"synthetic-not-a-word-document")
        self.request = {
            "template": str(self.source), "out": str(self.root / "draft.docx"),
            "pdf": str(self.root / "draft.pdf"),
            "template_sha256": hashlib.sha256(self.source.read_bytes()).hexdigest(),
            "replace": {"TOKEN": "VALUE"}, "expected_counts": {"TOKEN": 1},
        }

    def reject(self, code):
        before = sorted(p.name for p in self.root.iterdir())
        with self.assertRaisesRegex(cover.PreflightError, code):
            cover.preflight(self.request)
        self.assertEqual(before, sorted(p.name for p in self.root.iterdir()))

    def test_same_parent_empty_outputs_passes_without_writes(self):
        before = self.source.read_bytes()
        result = cover.preflight(self.request)
        self.assertEqual(result["status"], "preflight_only")
        self.assertFalse(result["execution_authorized"])
        self.assertFalse(result["native_generation_available"])
        self.assertIsNone(result["replacements"][0]["observed"])
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(list(self.root.iterdir()), [self.source])

    def test_doc_exists(self):
        target = Path(self.request["out"])
        target.write_bytes(b"keep")
        self.reject("output_exists")
        self.assertEqual(target.read_bytes(), b"keep")

    def test_pdf_exists_doc_absent(self):
        target = Path(self.request["pdf"])
        target.write_bytes(b"keep-pdf")
        self.reject("output_exists")
        self.assertEqual(target.read_bytes(), b"keep-pdf")
        self.assertFalse(Path(self.request["out"]).exists())

    def test_source_alias(self):
        self.request["out"] = str(self.root / "child" / ".." / self.source.name)
        self.reject("source_output_alias")

    def test_no_force(self):
        self.request["force"] = True
        self.reject("force_overwrite_removed")

    def test_missing_parent(self):
        self.request["out"] = str(self.root / "missing" / "draft.docx")
        self.reject("path_missing")

    def test_hash_required(self):
        self.request.pop("template_sha256")
        self.reject("explicit_template_sha256_required")

    def test_source_mutation_before_check(self):
        self.source.write_bytes(b"changed")
        self.reject("source_hash_mismatch")

    def test_source_mutation_during_hash(self):
        digest = hashlib.sha256()
        def update(chunk):
            digest.update(chunk)
            self.source.write_bytes(b"changed-length")
        fake = type("Digest", (), {"update": staticmethod(update),
                                   "hexdigest": digest.hexdigest})()
        with patch.object(cover.hashlib, "sha256", return_value=fake):
            self.reject("source_changed")

    def test_source_hardlink(self):
        os.link(self.source, self.root / "alias.docx")
        self.reject("hardlink_forbidden")

    def link(self, link, target, directory=False):
        try:
            link.symlink_to(target, target_is_directory=directory)
        except OSError as error:
            self.skipTest(f"symlink unavailable: {error}")

    def test_source_symlink(self):
        link = self.root / "link.docx"
        self.link(link, self.source)
        self.request["template"] = str(link)
        self.reject("link_or_reparse_forbidden")

    def test_parent_symlink(self):
        link = self.root / "linked"
        self.link(link, self.root, True)
        self.request["out"] = str(link / "draft.docx")
        self.reject("link_or_reparse_forbidden")

    def test_dangling_output(self):
        self.link(Path(self.request["pdf"]), self.root / "absent")
        self.reject("output_exists")

    def test_mocked_reparse_attribute_refused_before_hash(self):
        ordinary = self.source.lstat()
        fake = SimpleNamespace(st_mode=ordinary.st_mode, st_file_attributes=0x400)
        original = Path.lstat
        def lstat(path, *args, **kwargs):
            return fake if path == self.source else original(path, *args, **kwargs)
        with patch.object(Path, "lstat", lstat):
            self.reject("link_or_reparse_forbidden")

    def test_duplicate_json_key_refused(self):
        with self.assertRaisesRegex(cover.PreflightError, "duplicate_json_key"):
            json.loads('{"TOKEN":1,"TOKEN":2}', object_pairs_hook=cover._unique_object)

    def test_missing_expected_count(self):
        self.request["expected_counts"] = {}
        self.reject("exact_expected_count_keys_required")

    def test_extra_expected_count(self):
        self.request["expected_counts"]["OTHER"] = 2
        self.reject("exact_expected_count_keys_required")

    def test_zero_boolean_or_negative_expected_count(self):
        for count in (0, -1, True, 1.0):
            with self.subTest(count=count):
                self.request["expected_counts"]["TOKEN"] = count
                self.reject("positive_expected_count_required")

    def test_empty_requires_explicit_passthrough(self):
        self.request.update(replace={}, expected_counts={})
        self.reject("choose_replacements_or_explicit_passthrough_draft")
        self.request["passthrough_draft"] = True
        self.assertEqual(cover.preflight(self.request)["mode"], "passthrough_draft")

    def test_passthrough_cannot_hide_replacements(self):
        self.request["passthrough_draft"] = True
        self.reject("choose_replacements_or_explicit_passthrough_draft")

    def test_literal_unicode_preserved_not_normalized(self):
        self.request.update(replace={"B": "В"}, expected_counts={"B": 1})
        item = cover.preflight(self.request)["replacements"][0]
        self.assertEqual((item["old"], item["new"]), ("B", "В"))
        self.assertIsNone(item["observed"])

    def test_wrong_extensions(self):
        self.request["out"] = str(self.root / "draft.doc")
        self.reject("matching_doc_or_docx_extension_required")

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 unavailable")
    def test_wrapper_fail_before_even_with_fake_foreign_word(self):
        # Tripwires: no real COM factory, process enumeration or shutdown may be reached.
        script = '''
function New-Object { throw 'COM_FACTORY_MUST_NOT_RUN' }
function Get-Process { throw 'FOREIGN_WORD_MUST_NOT_BE_TOUCHED' }
function Stop-Process { throw 'PROCESS_STOP_MUST_NOT_RUN' }
try {
  & $env:COVER_SCRIPT -Template $env:COVER_SOURCE -Out $env:COVER_OUT `
    -Pdf $env:COVER_PDF -TemplateSha256 $env:COVER_HASH -PassthroughDraft
  exit 3
} catch {
  if ($_.ToString() -notmatch '^legacy_cover_native_disabled') {
    Write-Error $_; exit 4
  }
  Write-Output 'EXPECTED_NATIVE_FAIL_BEFORE'; exit 0
}
'''
        env = dict(os.environ, COVER_SCRIPT=str(ROOT / "toolkit/make_cover.ps1"),
                   COVER_SOURCE=str(self.source), COVER_OUT=self.request["out"],
                   COVER_PDF=self.request["pdf"], COVER_HASH=self.request["template_sha256"])
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=env,
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("EXPECTED_NATIVE_FAIL_BEFORE", result.stdout)
        self.assertEqual(list(self.root.iterdir()), [self.source])
        # The only passing wrapper mode is offline preflight, with no story-count claims.
        script = '''
function New-Object { throw 'COM_FACTORY_MUST_NOT_RUN' }
& $env:COVER_SCRIPT -Template $env:COVER_SOURCE -Out $env:COVER_OUT `
  -Pdf $env:COVER_PDF -TemplateSha256 $env:COVER_HASH -PassthroughDraft -PreflightOnly
'''
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=env,
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "preflight_only")
        self.assertEqual(list(self.root.iterdir()), [self.source])

    def test_cli_invalid_contract_nonzero(self):
        result = subprocess.run([shutil.which("python"), "-I", str(ROOT / "toolkit/cover_preflight.py")],
                                input=json.dumps({}), text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["status"], "failed")


if __name__ == "__main__":
    unittest.main()
