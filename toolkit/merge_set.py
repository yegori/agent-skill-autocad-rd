# Сводный PDF комплекта: первые N страниц обложки (обложка + титул) + все «NNN *.pdf» из папки листов по номерам.
# python -I merge_set.py <итог.pdf> <папка листов> [<обложка.pdf> [N=2]]
# Обложка может быть тем же файлом, что и итог (берутся его первые N страниц) — запись через временный файл.
import glob, os, sys
import pymupdf

out, sheets = sys.argv[1], sys.argv[2]
cover = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else ''
n = int(sys.argv[4]) if len(sys.argv) > 4 else 2
doc = pymupdf.open()
if cover:
    c = pymupdf.open(cover)
    doc.insert_pdf(c, from_page=0, to_page=min(n, len(c)) - 1)
    c.close()
files = sorted(glob.glob(os.path.join(sheets, '[0-9][0-9][0-9] *.pdf')))
for f in files:
    with pymupdf.open(f) as s:
        doc.insert_pdf(s)
tmp = out + '.tmp'
doc.save(tmp, garbage=3, deflate=True)
pages = len(doc)
doc.close()
os.replace(tmp, out)
print(f'сводный PDF: {pages} стр. (обложка {n if cover else 0} + листов {len(files)}) -> {out}')
