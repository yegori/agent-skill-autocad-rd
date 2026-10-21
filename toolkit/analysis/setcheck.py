r"""Сводный PDF ↔ PDF по листам: каждая страница сводного = какому листу (по совпадению отрисовки), шифр в штампе."""
import sys, glob, os, re
import numpy as np, pymupdf
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
setpdf, sheets = sys.argv[1], sys.argv[2]
def img(p):
    pm = p.get_pixmap(dpi=20, colorspace=pymupdf.csGRAY)
    return np.frombuffer(pm.samples, np.uint8).reshape(pm.height, pm.width).astype(np.int16)
S = {}
for f in sorted(glob.glob(os.path.join(sheets, '*.pdf'))):
    d = pymupdf.open(f)
    for i, p in enumerate(d):
        S[f'{os.path.basename(f)[:40]}#{i+1}'] = (img(p), p.get_text())
D = pymupdf.open(setpdf)
print(f'страниц в сводном: {len(D)}')
for i, p in enumerate(D):
    a = img(p); best = None
    for k, (b, t) in S.items():
        if a.shape == b.shape:
            d = float(np.abs(a - b).mean())
            if best is None or d < best[1]: best = (k, d)
    codes = sorted(set(re.findall(r'ИЗ\s?\d+', p.get_text())))
    print(f'  стр.{i+1:>2}: {best[0] if best and best[1] < 1.0 else "—"}  (откл. {best[1]:.2f})' if best else f'  стр.{i+1:>2}: формат не совпадает ни с одним листом', ' шифр:', codes)
