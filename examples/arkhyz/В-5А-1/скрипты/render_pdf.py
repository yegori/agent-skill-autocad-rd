"""Рендер PDF-листов в PNG (целиком и фрагменты таблиц) для просмотра.

Текст в PDF комплекта — SHX-шрифты, pdftotext его не читает, поэтому смотрим картинки.
Запуск: python render_pdf.py "<папка выдачи>\\pdf" <папка для png>
Фрагменты: crop(номер листа по порядку файлов, x0, y0, x1, y1 в долях листа, имя).
"""
import glob
import os
import sys
import pymupdf

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
files = sorted(glob.glob(os.path.join(src, "*.pdf")))

for i, f in enumerate(files, 1):
    page = pymupdf.open(f)[0]
    z = 2000 / page.rect.width
    page.get_pixmap(matrix=pymupdf.Matrix(z, z)).save(f"{out}/s{i}.png")
    print(i, os.path.basename(f))


def crop(i, fx0, fy0, fx1, fy1, name, z=3):
    page = pymupdf.open(files[i - 1])[0]
    r = page.rect
    clip = pymupdf.Rect(r.x0 + fx0 * r.width, r.y0 + fy0 * r.height,
                        r.x0 + fx1 * r.width, r.y0 + fy1 * r.height)
    page.get_pixmap(matrix=pymupdf.Matrix(z, z), clip=clip).save(f"{out}/{name}.png")


crop(5, 0.77, 0.0, 1.0, 0.48, "c5spec")     # спецификация Км-1
crop(5, 0.36, 0.88, 0.65, 0.98, "c5steel")  # ведомость расхода стали
crop(5, 0.77, 0.67, 1.0, 0.885, "c5notes")  # примечания
crop(6, 0.77, 0.0, 1.0, 0.31, "c6spec")     # спецификация КВ-1
crop(6, 0.05, 0.07, 0.25, 0.36, "c6r1", 3.5)
crop(6, 0.27, 0.07, 0.47, 0.36, "c6r2", 3.5)
crop(6, 0.48, 0.1, 0.68, 0.36, "c6r3", 3.5)
crop(7, 0.77, 0.0, 1.0, 0.21, "c7spec")     # спецификация защиты откосов
crop(7, 0.1, 0.28, 0.32, 0.62, "c7plan", 3.5)
crop(7, 0.84, 0.33, 0.94, 0.66, "c7coord")
