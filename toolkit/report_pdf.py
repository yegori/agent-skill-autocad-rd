"""Publish an existing UTF-8 Markdown report and local PNG/JPEG evidence as a NEW PDF.

Deliberately small subset: headings, paragraphs/lists, fenced code, pipe tables,
and inline [caption](relative.png) / ![caption](relative.jpg). Other inline
formatting is printed literally. No HTML interpretation, resource discovery,
network, Markdown execution, or changes to a job manifest. Requires PyMuPDF.
"""
import argparse
from dataclasses import dataclass, field
import os
from pathlib import Path
import re
import stat
import sys

import pymupdf


class ReportError(ValueError):
    pass


def safe_path(path):
    """Check lexical ancestors before opening, without following reparse points."""
    if os.fspath(path).startswith(("//", "\\\\")):
        raise ReportError(f"UNC/device paths refused: {path}")
    path = Path(os.path.abspath(path))
    for item in reversed((path, *path.parents)):
        st = item.lstat()
        if stat.S_ISLNK(st.st_mode) or getattr(st, "st_file_attributes", 0) & 0x400:
            raise ReportError(f"linked/reparse path refused: {item}")
    return path


def read_regular(path, limit):
    path = safe_path(path)
    before = path.stat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ReportError(f"not a single-link regular file: {path}")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino) or opened.st_nlink != 1:
            raise ReportError(f"input changed while opening: {path}")
        data = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
    safe_path(path)
    now = path.stat()
    signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_nlink)
    if signature(before) != signature(after) or signature(after) != signature(now):
        raise ReportError(f"input changed during read: {path}")
    if len(data) > limit:
        raise ReportError(f"input exceeds {limit} bytes: {path}")
    return data


@dataclass
class Evidence:
    path: str
    data: bytes
    width: int
    height: int
    references: list = field(default_factory=list)


LINK = re.compile(r"!?\[([^\]\n]*)\]\(([^)\n]*)\)")


class Report:
    def __init__(self, source):
        self.source = safe_path(source)
        self.root = self.source.parent
        self.images = []
        self.by_path = {}
        self.heading = "Отчёт"

    def inline(self, text):
        # Inline code is literal, including anything resembling a Markdown link.
        parts = text.split("`")
        if len(parts) % 2 == 0:
            raise ReportError("unclosed inline code; use balanced single backticks")
        for i in range(0, len(parts), 2):
            value = parts[i]
            if re.search(r"\]\s*\[|^\s*\[[^]]+\]:", value):
                raise ReportError("reference-style links unsupported; use inline local image links")
            parts[i] = LINK.sub(self.image_link, value)
            if "](" in parts[i] or "![" in parts[i]:
                raise ReportError("unsupported/malformed image link (nested parentheses not supported)")
        return "`".join(parts)

    def image_link(self, match):
        caption, target = match.groups()
        # Reject URI/drive/UNC/percent encoding, traversal and ambiguous syntax.
        if (not target or target != target.strip() or re.search(r"[:%?#<>\"\x00-\x1f]", target)
                or target.startswith(("/", "\\"))):
            raise ReportError(f"only plain relative PNG/JPEG links allowed: {target}")
        components = target.replace("\\", "/").split("/")
        if any(p in ("", ".", "..") or p.endswith((" ", ".")) for p in components):
            raise ReportError(f"ambiguous/escaping image path refused: {target}")
        path = self.root.joinpath(*components)
        if path.suffix.lower() not in (".png", ".jpg", ".jpeg"):
            raise ReportError(f"link is not PNG/JPEG evidence: {target}")
        key = os.path.normcase(str(path))
        if key not in self.by_path:
            if len(self.images) >= 64:
                raise ReportError("at most 64 unique evidence images supported")
            data = read_regular(path, 64 * 1024 * 1024)
            if not (data.startswith(b"\x89PNG\r\n\x1a\n") or data.startswith(b"\xff\xd8\xff")):
                raise ReportError(f"not PNG/JPEG bytes: {target}")
            pix = pymupdf.Pixmap(data)
            if pix.width * pix.height > 100_000_000:
                raise ReportError(f"image exceeds 100 million pixels: {target}")
            if sum(len(e.data) for e in self.images) + len(data) > 256 * 1024 * 1024:
                raise ReportError("total evidence exceeds 256 MiB")
            self.by_path[key] = len(self.images)
            self.images.append(Evidence(target, data, pix.width, pix.height))
        index = self.by_path[key]
        reference = f"{self.heading}: {caption or target}"
        if reference not in self.images[index].references:
            self.images[index].references.append(reference)
        return f"{caption or target} [E{index + 1}]"

    def blocks(self):
        text = read_regular(self.source, 2 * 1024 * 1024).decode("utf-8-sig")
        if any(ord(c) < 32 and c not in "\n\r\t" for c in text):
            raise ReportError("control characters in Markdown")
        lines = text.splitlines()
        result, i = [], 0
        while i < len(lines):
            line = lines[i]
            if line.startswith("```"):
                fence = line
                code = []
                i += 1
                while i < len(lines) and lines[i] != "```":
                    code.append(lines[i]); i += 1
                if i == len(lines):
                    raise ReportError("unclosed code fence")
                result.append(("code", [fence, *code, "```"])); i += 1
            elif i + 1 < len(lines) and is_separator(lines[i + 1]):
                headers = cells(line)
                if len(headers) != len(cells(lines[i + 1])):
                    raise ReportError("table header/separator column mismatch")
                rows = [headers]; i += 2
                while i < len(lines) and lines[i].strip().startswith("|"):
                    row = cells(lines[i])
                    if len(row) != len(headers):
                        raise ReportError("table row column mismatch; escaped pipes supported")
                    rows.append(row); i += 1
                result.append(("table", [[self.inline(c) for c in row] for row in rows]))
            else:
                heading = re.match(r"^(#{1,6})\s+(.+)$", line)
                if heading:
                    self.heading = heading[2]
                    result.append(("heading", (len(heading[1]), self.inline(heading[2]))))
                else:
                    result.append(("text", self.inline(line)))
                i += 1
        return result


def cells(line):
    if not line.strip().startswith("|") or not line.strip().endswith("|"):
        raise ReportError("tables must have leading and trailing pipes")
    return [s.strip().replace(r"\|", "|") for s in re.split(r"(?<!\\)\|", line.strip()[1:-1])]


def is_separator(line):
    return bool(re.fullmatch(r"\s*\|\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|\s*", line))


class PDF:
    def __init__(self):
        self.doc = pymupdf.open()
        # MuPDF's embedded Base14 font programs include Cyrillic; TextWriter
        # embeds them (unlike insert_text's limited Base14 encoding).
        self.font = pymupdf.Font("helv")
        self.mono = pymupdf.Font("cour")
        self.toc = []
        self.new_page()

    def new_page(self, width=595, height=842):
        if len(self.doc) >= 500:
            raise ReportError("report exceeds 500 pages")
        self.page = self.doc.new_page(width=width, height=height)
        self.y = 42
        self.bottom = height - 42
        self.right = width - 42

    def wrap(self, text, width, size=10, font=None):
        font = font or self.font
        text = text.expandtabs(4)
        if any(not font.has_glyph(ord(c)) for c in text if not c.isspace()):
            raise ReportError("unsupported glyph in text; no silent font substitution")
        rows = []
        while text:
            if font.text_length(text, fontsize=size) <= width:
                rows.append(text); break
            lo, hi = 1, len(text)
            while lo < hi:
                mid = (lo + hi + 1) // 2
                if font.text_length(text[:mid], fontsize=size) <= width:
                    lo = mid
                else:
                    hi = mid - 1
            cut = text.rfind(" ", 0, lo + 1)
            if cut <= 0:
                cut = lo
            else:
                cut += 1
            rows.append(text[:cut]); text = text[cut:]
        return rows or [""]

    def put(self, text, x, y, size=10, font=None):
        writer = pymupdf.TextWriter(self.page.rect)
        writer.append((x, y), text, font=font or self.font, fontsize=size)
        writer.write_text(self.page)

    def text(self, text, size=10, font=None):
        for line in self.wrap(text, self.right - 42, size, font):
            if self.y + size * 1.45 > self.bottom:
                self.new_page()
            self.put(line, 42, self.y, size, font)
            self.y += size * 1.45

    def table(self, rows):
        cols = len(rows[0])
        if not 2 <= cols <= 8:
            raise ReportError("tables support 2 to 8 columns")
        width = (self.right - 42) / cols
        for row_index, row in enumerate(rows):
            wrapped = [self.wrap(c, width - 10, 9) for c in row]
            count = max(map(len, wrapped))
            for i in range(count):
                if self.y + 17 > self.bottom:
                    self.new_page()
                top = self.y - 10
                for col, lines in enumerate(wrapped):
                    rect = pymupdf.Rect(42 + col * width, top, 42 + (col + 1) * width, top + 17)
                    self.page.draw_rect(rect, color=(.65, .65, .65), width=.3,
                                        fill=(.93, .95, .97) if row_index == 0 else None)
                    if i < len(lines):
                        self.put(lines[i], rect.x0 + 5, self.y + 2, 9)
                self.y += 17
        self.y += 10

    def appendix(self, image, number):
        # Embed original bytes, never a thumbnail/re-encoded rendering. Use a
        # suitably large evidence page at 150 pixels/inch, rather than shrinking
        # every large drawing to A4. Captions stay at ordinary readable size.
        caption = [f"E{number} — {image.path}", *image.references]
        image_width, image_height = image.width * 72 / 150, image.height * 72 / 150
        width = max(595, image_width + 84)
        lines = [line for c in caption for line in self.wrap(c, width - 84)]
        header = 42 + len(lines) * 14.5 + 12
        height = max(842, header + image_height + 42)
        if max(width, height) > 14400:
            raise ReportError("evidence page would exceed 14400 pt")
        self.new_page(width, height)
        self.toc.append([1, f"E{number} — {image.path}", len(self.doc)])
        for line in lines:
            self.put(line, 42, self.y); self.y += 14.5
        rect = pymupdf.Rect(42, header, 42 + image_width, header + image_height)
        self.page.insert_image(rect, stream=image.data)


def create_report(source, output):
    output = Path(os.path.abspath(output))
    safe_path(output.parent)
    if os.path.lexists(output):
        raise ReportError(f"output already exists (never overwritten): {output}")
    if output.suffix.lower() != ".pdf":
        raise ReportError("output must end in .pdf")
    report = Report(source)
    blocks = report.blocks()  # Fail on every invalid link before creating output.
    pdf = PDF()
    try:
        for kind, content in blocks:
            if kind == "heading":
                level, text = content
                pdf.y += 8
                if pdf.y + 50 > pdf.bottom:
                    pdf.new_page()
                pdf.toc.append([1, text, len(pdf.doc)])
                pdf.text(text, size=max(11, 18 - level * 2)); pdf.y += 5
            elif kind == "code":
                for line in content:
                    pdf.text(line, size=9, font=pdf.mono)
            elif kind == "table":
                pdf.table(content)
            else:
                pdf.text(content)
        for index, image in enumerate(report.images, 1):
            pdf.appendix(image, index)
        if pdf.toc:
            pdf.doc.set_toc(pdf.toc)
        pdf.doc.set_metadata({"title": report.source.stem, "subject": "Derived report publication; not a drawing set or new check"})
        pdf.doc.subset_fonts()
        data = pdf.doc.tobytes(garbage=4, deflate=True)
        safe_path(output.parent)
        # Exclusive creation also protects against an output appearing during render.
        with output.open("xb") as stream:
            stream.write(data)
        return {"pages": len(pdf.doc), "embedded_evidence": len(report.images), "output": str(output)}
    finally:
        pdf.doc.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("summary", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = create_report(args.summary, args.output)
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f"report_pdf: {error}\n")
    print(f"Created {result['output']}: {result['pages']} pages, {result['embedded_evidence']} evidence images")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    main()
