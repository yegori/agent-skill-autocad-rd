"""Real UTF-8 byte pipes/Unicode paths; only inert files and pre-native failure gates.
Legacy stdin encoding is changed exclusively inside isolated test children.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHILD = r'''
import runpy, subprocess, sys
sys.stdin.reconfigure(encoding="cp1251", errors="surrogateescape")
def forbidden_native(*args, **kwargs):
    raise AssertionError("NATIVE_PROCESS_TRIPWIRE")
subprocess.Popen = forbidden_native
runpy.run_path(sys.argv[1], run_name="__main__")
'''


class Utf8CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.parent = self.root / "папка_пример"
        self.parent.mkdir()
        self.source = self.parent / "шаблон_пример.docx"
        self.source.write_bytes(b"inert-not-a-word-document")
        self.exe = self.parent / "WINWORD.EXE"
        self.exe.write_bytes(b"inert-not-an-executable")
        self.request = {
            "template": str(self.source), "template_sha256": hashlib.sha256(self.source.read_bytes()).hexdigest(),
            "out": str(self.parent / "новый_черновик.docx"), "pdf": str(self.parent / "новый_черновик.pdf"),
            "replace": {"B": "В", "В": "B"}, "expected_counts": {"B": 1, "В": 2},
            "word_exe": str(self.exe), "word_sha256": hashlib.sha256(self.exe.read_bytes()).hexdigest(),
            "work_parent": str(self.parent), "expected_pages": 0, "timeout_sec": 5, "pane_timeout_sec": 2,
        }

    def snapshot(self):
        return {str(path.relative_to(self.root)): path.read_bytes() if path.is_file() else None
                for path in self.root.rglob("*")}

    def cli(self, name, payload=None):
        before = self.snapshot()
        if payload is None:
            payload = json.dumps(self.request, ensure_ascii=False).encode("utf-8")
        result = subprocess.run([sys.executable, "-I", "-c", CHILD, str(ROOT / "toolkit" / name)],
                                input=payload, capture_output=True, timeout=20)
        self.assertEqual(self.snapshot(), before, "CLI must not stage/write/activate anything")
        self.assertNotIn(b"NATIVE_PROCESS_TRIPWIRE", result.stderr)
        return result, json.loads(result.stdout.decode("ascii"))

    def test_preflight_utf8_bytes_over_legacy_stdin_preserves_actual_cyrillic_paths(self):
        result, data = self.cli("cover_preflight.py")
        self.assertEqual(result.returncode, 0, data)
        self.assertEqual(data["status"], "preflight_only")
        self.assertEqual(data["template"], str(self.source))
        self.assertEqual(data["out"], self.request["out"])
        self.assertEqual(data["pdf"], self.request["pdf"])
        self.assertEqual(data["template_sha256"], self.request["template_sha256"])
        self.assertEqual([(item["old"], item["new"], item["expected"]) for item in data["replacements"]],
                         [("B", "В", 1), ("В", "B", 2)])

    def test_draft_utf8_reaches_invalid_page_gate_before_run_or_native(self):
        self.request.update(replace={}, expected_counts={}, passthrough_draft=True)
        result, data = self.cli("cover_draft.py")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(data["error"], "explicit_positive_expected_pages_required")
        self.assertFalse(data["native_accepted"])

    def test_invalid_utf8_fails_closed_for_both_consumers(self):
        for name in ("cover_preflight.py", "cover_draft.py"):
            with self.subTest(name=name):
                result, data = self.cli(name, b'{"template":"\xff"}')
                self.assertEqual(result.returncode, 1)
                self.assertEqual(data["status"], "failed")
                self.assertIn("utf-8", data["error"])

    def test_duplicate_json_keys_still_refused_for_both_consumers(self):
        payload = json.dumps(self.request, ensure_ascii=False)[:-1] + ',"expected_counts":{"B":1,"B":2}}'
        for name in ("cover_preflight.py", "cover_draft.py"):
            with self.subTest(name=name):
                result, data = self.cli(name, payload.encode("utf-8"))
                self.assertEqual(result.returncode, 1)
                self.assertEqual(data["error"], "duplicate_json_key")

    def test_ascii_byte_contract_still_valid(self):
        source = self.root / "template.docx"; source.write_bytes(b"ascii-fixture")
        exe = self.root / "WINWORD.EXE"; exe.write_bytes(b"inert-exe")
        self.request.update(template=str(source), template_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                            out=str(self.root / "new.docx"), pdf=str(self.root / "new.pdf"),
                            word_exe=str(exe), word_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
                            work_parent=str(self.root), replace={}, expected_counts={}, passthrough_draft=True)
        payload = json.dumps(self.request, ensure_ascii=True).encode("ascii")
        result, data = self.cli("cover_preflight.py", payload)
        self.assertEqual((result.returncode, data["status"]), (0, "preflight_only"))
        result, data = self.cli("cover_draft.py", payload)
        self.assertEqual((result.returncode, data["error"]), (1, "explicit_positive_expected_pages_required"))

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 unavailable")
    def test_powershell_producers_emit_utf8_and_restore_caller_encoding(self):
        env = dict(os.environ, COVER_ROOT=str(ROOT), COVER_SOURCE=str(self.source), COVER_OUT=self.request["out"],
                   COVER_PDF=self.request["pdf"], COVER_SHA=self.request["template_sha256"], COVER_EXE=str(self.exe),
                   COVER_EXE_SHA=self.request["word_sha256"], COVER_WORK=str(self.parent))
        script = r'''
$ErrorActionPreference='Stop'
$OutputEncoding=[Text.ASCIIEncoding]::new()
$original=$OutputEncoding
$lines=& (Join-Path $env:COVER_ROOT 'toolkit/make_cover.ps1') -Template $env:COVER_SOURCE `
  -TemplateSha256 $env:COVER_SHA -Out $env:COVER_OUT -Pdf $env:COVER_PDF `
  -Replace ([ordered]@{'B'='В';'В'='B'}) -ExpectedCounts @{'B'=1;'В'=2} -PreflightOnly
if (-not [object]::ReferenceEquals($OutputEncoding,$original)) {throw 'caller_encoding_changed'}
$parsed=($lines -join "`n")|ConvertFrom-Json
if ($parsed.template -cne $env:COVER_SOURCE -or $parsed.out -cne $env:COVER_OUT -or $parsed.pdf -cne $env:COVER_PDF) {throw 'unicode_path_changed'}
if ($parsed.replacements[0].old -cne 'B' -or $parsed.replacements[0].new -cne 'В' -or
    $parsed.replacements[1].old -cne 'В' -or $parsed.replacements[1].new -cne 'B') {throw 'literal_map_changed'}
try {
  & (Join-Path $env:COVER_ROOT 'toolkit/make_cover_draft.ps1') -Template $env:COVER_SOURCE `
    -TemplateSha256 $env:COVER_SHA -Out $env:COVER_OUT -Pdf $env:COVER_PDF `
    -WordExe $env:COVER_EXE -WordSha256 $env:COVER_EXE_SHA -WorkParent $env:COVER_WORK `
    -ExpectedPages 0 -PassthroughDraft
  throw 'invalid_page_gate_not_reached'
} catch { if ($_.ToString() -notmatch 'explicit_positive_expected_pages_required') {throw} }
if (-not [object]::ReferenceEquals($OutputEncoding,$original)) {throw 'caller_encoding_changed_on_error'}
Write-Output 'UTF8_PS_ROUNDTRIP_AND_DRAFT_PRE_NATIVE_GATE_OK'
'''
        before = self.snapshot()
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=env,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode("utf-8", errors="replace"))
        self.assertIn(b"UTF8_PS_ROUNDTRIP_AND_DRAFT_PRE_NATIVE_GATE_OK", result.stdout)
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__": unittest.main()
