"""Сравнение PDF: старая выдача против новой (основа регрессии R1 и проверки «PDF актуальны»).

  python -I compare_pdfs.py <старый.pdf|папка> <новый.pdf|папка> [--dpi 30] [--diff-out <папка>] [--threshold 60]

* Два файла — постранично. Две папки — листы сопоставляются по номеру в начале имени («003 …»), иначе по имени.
* Для каждой пары: совпадает ли формат страниц; есть ли отличия и ГДЕ: «только штамп» (подписи-картинки сглаживаются
  по-разному при каждой печати — шум) или «ОТЛИЧАЕТСЯ» (отличия на поле чертежа; область в мм от левого верхнего угла).
  Долю пикселей для решения НЕ использовать: правка одного числа (+1885,86 → +2113,10 на листе А1) = 0,0006%.
* --diff-out: для отличающихся страниц — картинка «было | стало» по области отличий (dpi 60).
"""
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')  # python -I игнорирует PYTHONIOENCODING; в pwsh: [Console]::OutputEncoding = [Text.Encoding]::UTF8
import argparse, glob, json, os, re, sys
import pymupdf


def key(name):
    m = re.match(r'(\d{3})', name)
    return int(m.group(1)) if m else name


def pages(path):
    return [(os.path.basename(path), i, p) for i, p in enumerate(pymupdf.open(path))]


def pairs(a, b):
    if os.path.isdir(a) and os.path.isdir(b):
        A = {key(os.path.basename(f)): f for f in glob.glob(os.path.join(a, '*.pdf'))}
        B = {key(os.path.basename(f)): f for f in glob.glob(os.path.join(b, '*.pdf'))}
        for k in sorted(set(A) | set(B), key=lambda x: (isinstance(x, str), x)):
            if k not in A or k not in B:
                yield k, A.get(k), B.get(k), None, None
                continue
            for (na, i, pa), (nb, _, pb) in zip(pages(A[k]), pages(B[k])):
                yield k, A[k], B[k], pa, pb
    else:
        for (na, i, pa), (nb, _, pb) in zip(pages(a), pages(b)):
            yield i + 1, a, b, pa, pb


def gray(p, dpi):
    pm = p.get_pixmap(dpi=dpi, colorspace=pymupdf.csGRAY)
    return pm


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('old'); ap.add_argument('new')
    ap.add_argument('--dpi', type=int, default=100); ap.add_argument('--threshold', type=int, default=60)
    ap.add_argument('--min-px', type=int, default=30, help='мин. размер скопления отличий (пикс. при --dpi), меньше — шум')
    ap.add_argument('--diff-out'); ap.add_argument('--json')
    ap.add_argument('--stamp-mm', type=float, nargs=2, default=[190, 60], help='зона штампа в правом нижнем углу, мм')
    a = ap.parse_args()
    res = []
    for k, fa, fb, pa, pb in pairs(a.old, a.new):
        if pa is None:
            res.append({'лист': k, 'статус': 'только в старом' if fa else 'только в новом'}); continue
        ra, rb = pa.rect, pb.rect
        if abs(ra.width - rb.width) > 1 or abs(ra.height - rb.height) > 1:
            res.append({'лист': k, 'статус': 'РАЗНЫЙ ФОРМАТ', 'старый': [round(ra.width), round(ra.height)], 'новый': [round(rb.width), round(rb.height)]}); continue
        import numpy as np
        from scipy import ndimage
        ga, gb = gray(pa, a.dpi), gray(pb, a.dpi)
        A = np.frombuffer(ga.samples, np.uint8).reshape(ga.height, ga.width).astype(np.int16)
        B = np.frombuffer(gb.samples, np.uint8).reshape(gb.height, gb.width).astype(np.int16)
        mask = np.abs(A - B) > a.threshold
        diff = int(mask.sum()); pct = 100.0 * diff / mask.size
        k_px = a.dpi / 25.4
        # Скопления отличий: правка текста — плотное пятно; шум печати (сглаживание штриховок, подписи-картинки) —
        # разрозненные пиксели. Склеиваем соседей (dilation) и берём связные области ≥ --min-px пикселей.
        lab, n = ndimage.label(ndimage.binary_dilation(mask, iterations=2))
        real = []
        if n:
            sizes = ndimage.sum(mask, lab, range(1, n + 1))
            for comp, sz in enumerate(sizes, 1):
                if sz < a.min_px:
                    continue
                ys, xs = np.nonzero(lab == comp)
                x0, y0, x1, y1 = xs.min() / k_px, ys.min() / k_px, xs.max() / k_px, ys.max() / k_px
                in_stamp = x0 >= ga.width / k_px - a.stamp_mm[0] and y0 >= ga.height / k_px - a.stamp_mm[1]
                real.append({'мм': [round(x0), round(y0), round(x1), round(y1)], 'пикс': int(sz), 'штамп': bool(in_stamp)})
        field = [r for r in real if not r['штамп']]
        # НЕ судить по доле пикселей: правка одного числа на листе А1 — тысячные доли процента
        st = ('совпадает' if not diff else 'ОТЛИЧАЕТСЯ' if field else
              'только штамп (подписи?)' if real else 'шум печати (одиночные пиксели)')
        row = {'лист': k, 'статус': st, 'отличий_%': round(pct, 4)}
        if field:
            row['области_мм'] = [r['мм'] for r in field][:8]
        if a.diff_out and field:
            from PIL import Image, ImageChops
            os.makedirs(a.diff_out, exist_ok=True)
            ia, ib = [Image.frombytes('L', (pm.width, pm.height), pm.samples) for pm in (pa.get_pixmap(dpi=60, colorspace=pymupdf.csGRAY), pb.get_pixmap(dpi=60, colorspace=pymupdf.csGRAY))]
            k60 = 60 / 25.4   # рамка вокруг всех найденных областей правок (не вокруг шума)
            box = (int(min(r['мм'][0] for r in field) * k60), int(min(r['мм'][1] for r in field) * k60),
                   int(max(r['мм'][2] for r in field) * k60) + 1, int(max(r['мм'][3] for r in field) * k60) + 1)
            if box:
                pad = 40; x0, y0, x1, y1 = box
                c = (max(0, x0 - pad), max(0, y0 - pad), min(ia.width, x1 + pad), min(ia.height, y1 + pad))
                w = c[2] - c[0]; out = Image.new('L', (w * 2 + 10, c[3] - c[1]), 128)
                out.paste(ia.crop(c), (0, 0)); out.paste(ib.crop(c), (w + 10, 0))
                fn = os.path.join(a.diff_out, f'diff_{k}.png'); out.save(fn); row['картинка'] = fn
        res.append(row)
    for r in res:
        print(' | '.join(f'{k}: {v}' for k, v in r.items()))
    if a.json:
        json.dump(res, open(a.json, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
