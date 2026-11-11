"""Inert backend only: never executes cover_native_host/Word/COM."""
import importlib.util
import json
import os
import shutil
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cover_draft", ROOT / "toolkit/cover_draft.py")
cover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cover)


class DraftTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.template = self.root / "template.docx"; self.template.write_bytes(b"supplied-values-kept")
        self.exe = self.root / "WINWORD.EXE"; self.exe.write_bytes(b"inert-not-executable")
        self.request = dict(template=str(self.template), template_sha256=cover.pre.source_hash(self.template),
                            out=str(self.root / "new.docx"), pdf=str(self.root / "new.pdf"),
                            word_exe=str(self.exe), word_sha256=cover.pre.source_hash(self.exe),
                            expected_pages=2, work_parent=str(self.root), timeout_sec=5, pane_timeout_sec=2,
                            replace={}, expected_counts={}, passthrough_draft=True)
        self.calls = []

    def backend(self, config, config_path):
        self.calls.append(config)
        self.assertEqual(Path(config["snapshot"]).read_bytes(), b"supplied-values-kept")
        self.assertEqual(Path(config["doc"]).name, "new.docx")
        Path(config["doc"]).write_bytes(Path(config["snapshot"]).read_bytes())
        Path(config["pdf"]).write_bytes(b"inert-pdf")
        return dict(status="controlled_draft_closed_and_stopped", cleanup_verified=True,
                    root_live_before_stop=True, timed_out=False, ownership=dict(identity_verified=True),
                    closed_artifact_sha256={kind: cover.pre.source_hash(Path(config[kind])) for kind in ("doc", "pdf")},
                    document=dict(document_closed=True, replacement_counts=[], coverage="passthrough_no_story_acceptance"))

    def generate(self, backend=None, **kwargs):
        return cover.generate(self.request, backend=backend or self.backend,
                              pdf_validator=lambda path, pages: self.assertEqual(pages, 2), **kwargs)

    def test_same_parent_success_preserves_supplied_values(self):
        result = self.generate()
        self.assertEqual(result["status"], "draft_generated_pending_coordinator_qa")
        self.assertFalse(result["native_accepted"])
        self.assertEqual(Path(self.request["out"]).read_bytes(), self.template.read_bytes())
        self.assertEqual(self.template.read_bytes(), b"supplied-values-kept")
        self.assertEqual(result["native"]["document"]["replacement_counts"], [])

    def test_existing_doc_or_pdf_fail_before_backend_or_writes(self):
        for key in ("out", "pdf"):
            target = Path(self.request[key]); target.write_bytes(b"keep")
            before = set(self.root.iterdir())
            with self.assertRaisesRegex(ValueError, "output_exists"):
                self.generate()
            self.assertEqual(before, set(self.root.iterdir())); self.assertEqual(self.calls, [])
            self.assertEqual(target.read_bytes(), b"keep"); target.unlink()

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell unavailable")
    def test_draft_wrapper_collision_fails_before_native_host(self):
        Path(self.request["pdf"]).write_bytes(b"keep-existing")
        before = set(self.root.iterdir())
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(ROOT / "toolkit/make_cover_draft.ps1"),
                                 "-Template", self.request["template"], "-TemplateSha256", self.request["template_sha256"],
                                 "-Out", self.request["out"], "-Pdf", self.request["pdf"],
                                 "-WordExe", self.request["word_exe"], "-WordSha256", self.request["word_sha256"],
                                 "-WorkParent", str(self.root), "-ExpectedPages", "2", "-PassthroughDraft"],
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output_exists", result.stdout + result.stderr)
        self.assertEqual(before, set(self.root.iterdir()))
        self.assertEqual(Path(self.request["pdf"]).read_bytes(), b"keep-existing")

    def test_bad_binary_hash_fail_before_writes(self):
        self.request["word_sha256"] = "0" * 64
        before = set(self.root.iterdir())
        with self.assertRaisesRegex(ValueError, "word_binary_hash_mismatch"): self.generate()
        self.assertEqual(before, set(self.root.iterdir()))

    def test_reserved_and_ambiguous_paths_fail_before_writes(self):
        before = set(self.root.iterdir())
        for name in ("NUL.docx", "con.docx", "CON .docx", "COM0.docx", "COM10.docx", "COM1.docx", "LPT².docx", "bad\x01.docx", "dir. /new.docx", "dir./new.docx", "C:rel.docx"):
            with self.subTest(name=name):
                self.request["out"] = str(self.root / name) if not name.startswith("C:") else name
                with self.assertRaises(ValueError): self.generate()
                self.assertEqual(before, set(self.root.iterdir()))

    def test_backend_failures_preserve_partials_no_publication(self):
        for error in ("foreign_winword", "pane_timeout", "hwnd_mismatch", "earlyexit0", "Open", "Find", "Export", "Close", "COM_hang_timeout", "cleanup_uncertain"):
            with self.subTest(error=error):
                def failing(config, path):
                    Path(config["doc"]).write_bytes(b"partial")
                    raise RuntimeError(error)
                result = self.generate(backend=failing)
                self.assertEqual(result["status"], "failed"); self.assertEqual(result["error"], error)
                self.assertFalse(Path(self.request["out"]).exists()); self.assertFalse(Path(self.request["pdf"]).exists())
                self.assertEqual((Path(result["run_dir"]) / "generated/new.docx").read_bytes(), b"partial")

    def test_uncertain_evidence_never_publishes(self):
        for key, value in (("cleanup_verified", False), ("root_live_before_stop", False), ("timed_out", True)):
            def backend(config, path):
                result = self.backend(config, path); result[key] = value; return result
            result = self.generate(backend=backend)
            self.assertEqual(result["status"], "failed"); self.assertEqual(result["published"], [])

    def test_snapshot_or_source_mutation_no_publication(self):
        for target in ("snapshot", "template"):
            def backend(config, path):
                result = self.backend(config, path); Path(config[target]).write_bytes(b"changed"); return result
            result = self.generate(backend=backend)
            self.assertEqual(result["status"], "failed"); self.assertEqual(result["published"], [])
            self.template.write_bytes(b"supplied-values-kept")

    def test_second_publication_collision_explicit_partial_pair(self):
        def publish(source, target):
            cover.copy_new(source, target)
            if str(target) == self.request["out"]:
                Path(self.request["pdf"]).write_bytes(b"concurrent-keep")
        result = self.generate(publisher=publish)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["published"], [self.request["out"]])
        self.assertEqual(Path(self.request["pdf"]).read_bytes(), b"concurrent-keep")
        self.assertEqual(Path(self.request["out"]).read_bytes(), b"supplied-values-kept")

    def test_publication_write_error_retains_partial(self):
        def publish(source, target):
            with Path(target).open("xb") as stream: stream.write(b"partial")
            raise OSError("write_failure")
        result = self.generate(publisher=publish)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["publication_attempt"], self.request["out"])
        self.assertEqual(Path(self.request["out"]).read_bytes(), b"partial")

    def test_pdf_postflight_failure_no_publication(self):
        def invalid(path, pages): raise RuntimeError("pdf_invalid")
        result = cover.generate(self.request, backend=self.backend, pdf_validator=invalid)
        self.assertEqual(result["status"], "failed"); self.assertEqual(result["published"], [])

    def test_literal_map_restrictions(self):
        for replacements in ({"^p": "x"}, {"A": "AB"}, {"A": "x", "AB": "y"}, {"A\r": "x"}):
            self.request.update(replace=replacements, expected_counts={old: 1 for old in replacements}, passthrough_draft=False)
            with self.assertRaises(ValueError): self.generate()

    def test_replacement_counts_evidence_required(self):
        self.request.update(replace={"TOKEN": "VALUE"}, expected_counts={"TOKEN": 1}, passthrough_draft=False)
        result = self.generate()
        self.assertEqual(result["error"], "replacement_evidence_missing")
        self.assertFalse(Path(self.request["out"]).exists())

    def test_real_installed_pdf_validator_with_synthetic_pages(self):
        try:
            import fitz
        except ImportError:
            self.skipTest("PyMuPDF unavailable; production does not install or waive it")
        for pages in (1, 2):
            def backend(config, path):
                result = self.backend(config, path)
                Path(config["pdf"]).unlink()  # replace only this synthetic fixture, not production publication.
                with fitz.open() as document:
                    for _ in range(pages): document.new_page()
                    document.save(config["pdf"])
                result["closed_artifact_sha256"]["pdf"] = cover.pre.source_hash(Path(config["pdf"]))
                return result
            result = cover.generate(self.request, backend=backend)
            self.assertEqual(result["status"], "failed" if pages == 1 else "draft_generated_pending_coordinator_qa")

    @unittest.skipUnless(os.name == "nt", "Windows host invocation boundary")
    def test_native_host_timeout_never_kills_or_claims_cleanup(self):
        process = unittest.mock.Mock()
        process.wait.side_effect = subprocess.TimeoutExpired("inert-host", 95)
        with patch.object(cover.subprocess, "Popen", return_value=process):
            with self.assertRaisesRegex(RuntimeError, "timeout_cleanup_uncertain_no_publication"):
                cover.run_native({"timeout_sec": 5}, self.root / "config.json")
        process.kill.assert_not_called()
        process.terminate.assert_not_called()

    def test_missing_pdf_module_fails_before_run_creation(self):
        import builtins
        original = builtins.__import__
        def importing(name, *args, **kwargs):
            if name == "fitz": raise ImportError("synthetic_missing_pymupdf")
            return original(name, *args, **kwargs)
        before = set(self.root.iterdir())
        with patch("builtins.__import__", importing):
            with self.assertRaisesRegex(ImportError, "synthetic_missing_pymupdf"):
                cover.generate(self.request, backend=self.backend)
        self.assertEqual(before, set(self.root.iterdir()))
        self.assertEqual(self.calls, [])

    def test_original_pid_addition_is_only_capture_not_lookup(self):
        text = (ROOT / "toolkit/spds_text/OwnedCadProcess.cs").read_text(encoding="utf-8")
        self.assertEqual(text.count("owner.OriginalProcessId = info.processId;"), 1)
        self.assertNotIn("GetProcessById", text)
        self.assertLess(text.index("owner.OriginalProcessId = info.processId;"), text.index("Check(AssignProcessToJobObject"))


if __name__ == "__main__": unittest.main()
