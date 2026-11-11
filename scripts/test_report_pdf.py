"""Targeted offline publication tests; synthetic inputs, no CAD/network."""
import hashlib
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import pymupdf

SPEC = importlib.util.spec_from_file_location("report_pdf", Path(__file__).resolve().parents[1] / "toolkit/report_pdf.py")
p = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = p
SPEC.loader.exec_module(p)


class ReportPDFTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "summary.md"
        self.output = self.root / "report.pdf"
        self.image = self.root / "evidence.png"
        pix = pymupdf.Pixmap(pymupdf.csRGB, (0, 0, 640, 480), False)
        pix.clear_with(200)
        pix.save(self.image)

    def render(self, text):
        self.source.write_text(text, encoding="utf-8")
        return p.create_report(self.source, self.output)

    def test_cyrillic_table_long_code_embedded_deduplicated_and_unchanged(self):
        long_path = "C:/" + "длинный_путь/" * 35 + "конец.png"
        self.source.write_text("# Проверка ТЕСТ-1\n\n## R-01\nДеталь 130,25 кг.\n"
            "[Схема](evidence.png) и ![Повтор](evidence.png)\n"
            "| Позиция | Значение |\n|---|---|\n| ДЕТ-2 | 12 × 2,50 = 30,00 кг |\n"
            "```text\n" + long_path + "\n```\n<img src='https://invalid/image.png'>\n", encoding="utf-8")
        before = {f: hashlib.sha256(f.read_bytes()).hexdigest() for f in [self.source, self.image]}
        result = p.create_report(self.source, self.output)
        self.assertEqual(result['embedded_evidence'], 1)
        with pymupdf.open(self.output) as doc:
            text = "".join(page.get_text() for page in doc)
            self.assertIn("Проверка ТЕСТ-1", text)
            self.assertIn("30,00", text)
            self.assertIn("<img", text)  # Literal, never interpreted as HTML.
            compact = "".join(text.split())
            self.assertIn(long_path, compact)
            self.assertIn("R-01: Схема", text)
            images = {i[0]: i for page in doc for i in page.get_images()}
            self.assertEqual(len(images), 1)
            self.assertEqual(next(iter(images.values()))[2:4], (640, 480))
        self.assertEqual(before, {f: hashlib.sha256(f.read_bytes()).hexdigest() for f in before})
        old = self.output.read_bytes()
        with self.assertRaisesRegex(p.ReportError, "already exists"):
            p.create_report(self.source, self.output)
        self.assertEqual(self.output.read_bytes(), old)

    def test_missing_escape_remote_uri_and_non_image_links_fail_before_output(self):
        for target in ["missing.png", "../outside.png", "https://host/e.png", "file:///e.png",
                       "C:/e.png", "//host/e.png", "%2e%2e/e.png", "e.png?x", "x.pdf"]:
            with self.subTest(target=target):
                with self.assertRaises((p.ReportError, OSError)):
                    self.render(f"# Отчёт\n[Доказательство]({target})\n")
                self.assertFalse(self.output.exists())

    def test_unc_root_refused_before_filesystem_access(self):
        with patch.object(Path, "lstat") as probe:
            for path in ("//server.invalid/share/report.md", r"\\server.invalid\share\report.md"):
                with self.assertRaisesRegex(p.ReportError, "UNC/device"):
                    p.safe_path(path)
            probe.assert_not_called()

    def test_hardlink_image_refused(self):
        linked = self.root / "hard.png"
        os.link(self.image, linked)
        with self.assertRaisesRegex(p.ReportError, "single-link"):
            self.render("[linked](hard.png)")
        self.assertFalse(self.output.exists())

    def test_symlink_image_and_directory_refused(self):
        linked = self.root / "link.png"
        try:
            linked.symlink_to(self.image)
        except OSError as error:
            self.skipTest(f"OS does not grant symlink creation: {error}")
        with self.assertRaisesRegex(p.ReportError, "linked/reparse"):
            self.render("[linked](link.png)")
        directory = self.root / "alias"
        directory.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(p.ReportError, "linked/reparse"):
            self.render("[linked](alias/evidence.png)")
        self.assertFalse(self.output.exists())

    def test_reparse_attribute_refused_without_symlink_privilege(self):
        original = Path.lstat
        for blocked in (self.root, self.image):
            def marked(path, *args, **kwargs):
                result = original(path, *args, **kwargs)
                if path == blocked:
                    return SimpleNamespace(st_mode=result.st_mode, st_file_attributes=0x400)
                return result
            with self.subTest(blocked=str(blocked)), patch.object(Path, "lstat", marked):
                with self.assertRaisesRegex(p.ReportError, "linked/reparse"):
                    self.render("[linked](evidence.png)")
            self.assertFalse(self.output.exists())

    def test_hardlinked_markdown_and_existing_output_link_refused(self):
        self.source.write_text("# Заголовок", encoding="utf-8")
        os.link(self.source, self.root / "copy.md")
        with self.assertRaisesRegex(p.ReportError, "single-link"):
            p.create_report(self.source, self.output)
        os.link(self.image, self.output)
        before = self.image.read_bytes()
        with self.assertRaisesRegex(p.ReportError, "already exists"):
            p.create_report(self.source, self.output)
        self.assertEqual(self.image.read_bytes(), before)

    def test_unsupported_missing_text_syntax_is_explicit(self):
        for text in ["```text\nunclosed", "![x][ref]\n[ref]: evidence.png", "[x](a(b).png)",
                     "| A | B |\n|---|---|\n| only one |", "a `unclosed"]:
            with self.subTest(text=text):
                with self.assertRaises((p.ReportError, OSError)):
                    self.render(text)
                self.assertFalse(self.output.exists())

    def test_multi_page_table_retains_first_and_last_rows(self):
        text = "# Таблица\n| Код | Описание |\n|---|---|\n"
        text += "\n".join(f"| ПОЗ-{i:03} | Количество {i} шт; примечание сохранено |" for i in range(120))
        self.render(text)
        with pymupdf.open(self.output) as doc:
            self.assertGreater(len(doc), 2)
            combined = "".join(page.get_text() for page in doc)
            for i in range(120):
                self.assertIn(f"ПОЗ-{i:03}", combined)


if __name__ == "__main__":
    unittest.main()
