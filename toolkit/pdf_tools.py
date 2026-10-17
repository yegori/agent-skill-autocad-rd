"""Инструменты для PDF комплекта (текст в листах — SHX, читается только рендером; текст штампа часто TrueType и извлекается).

  python -I pdf_tools.py render <pdf> <out.png> [--dpi 110] [--page 1] [--box x0 y0 x1 y1]
      рендер страницы (box — доли страницы 0..1, слева-сверху). Для листов А0 с поворотом — берётся видимая ориентация.
  python -I pdf_tools.py stamps <pdf|папка> <out.png> [--w-mm 70 --h-mm 40 --from-right 5 --from-bottom 5] [--cols 7] [--skip 0]
      сводная картинка правых нижних углов (графа «Лист», штамп) всех страниц — для глазной проверки номеров.
  python -I pdf_tools.py grep <pdf|папка> <regex> [--missing]
      поиск по текстовому слою страниц (шифр, «Вн-ссылка», …); --missing — страницы, где совпадений НЕТ (P3: шифр на каждой странице).
  python -I pdf_tools.py sizes <pdf|папка>
      форматы страниц в мм.
"""
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')  # python -I игнорирует PYTHONIOENCODING; в pwsh: [Console]::OutputEncoding = [Text.Encoding]::UTF8
import argparse, glob, os, re, sys
import pymupdf


def files_of(path):
    return sorted(glob.glob(os.path.join(path, '*.pdf'))) if os.path.isdir(path) else [path]


def all_pages(path):
    for f in files_of(path):
        for i, p in enumerate(pymupdf.open(f)):
            yield f, i, p


def to_img(p, dpi):
    from PIL import Image
    pm = p.get_pixmap(dpi=dpi)
    return Image.frombytes('RGB', (pm.width, pm.height), pm.samples)


def cmd_render(a):
    p = pymupdf.open(a.pdf)[a.page - 1]
    im = to_img(p, a.dpi)
    if a.box:
        x0, y0, x1, y1 = a.box
        im = im.crop((int(x0 * im.width), int(y0 * im.height), int(x1 * im.width), int(y1 * im.height)))
    im.save(a.out); print(a.out, im.size)


def cmd_stamps(a):
    from PIL import Image, ImageDraw
    tiles = []
    for f, i, p in all_pages(a.path):
        if i < a.skip and not os.path.isdir(a.path):
            continue
        im = to_img(p, 100); k = 100 / 25.4
        c = im.crop((int(im.width - (a.from_right + a.w_mm) * k), int(im.height - (a.from_bottom + a.h_mm) * k),
                     int(im.width - a.from_right * k), int(im.height - a.from_bottom * k)))
        lab = Image.new('RGB', (c.width, c.height + 16), 'white'); lab.paste(c, (0, 16))
        ImageDraw.Draw(lab).text((2, 2), f'{os.path.basename(f)[:28]} p{i + 1}', fill='red'); tiles.append(lab)
    if not tiles:
        print('нет страниц'); return
    tw = max(t.width for t in tiles); th = max(t.height for t in tiles); cols = a.cols
    out = Image.new('RGB', (cols * (tw + 6), ((len(tiles) + cols - 1) // cols) * (th + 6)), 'gray')
    for n, t in enumerate(tiles):
        out.paste(t, ((n % cols) * (tw + 6), (n // cols) * (th + 6)))
    out.save(a.out); print(a.out, len(tiles), 'стр.')


def cmd_grep(a):
    rx = re.compile(a.regex); bad = 0
    for f, i, p in all_pages(a.path):
        found = rx.findall(p.get_text())
        if a.missing:
            if not found:
                bad += 1; print(f'НЕТ: {os.path.basename(f)} стр.{i + 1}')
        elif found:
            print(f'{os.path.basename(f)} стр.{i + 1}: {sorted(set(found))}')
    if a.missing:
        print('страниц без совпадений:', bad)


def cmd_sizes(a):
    for f, i, p in all_pages(a.path):
        r = p.rect
        print(f'{os.path.basename(f)} стр.{i + 1}: {round(r.width / 72 * 25.4)}x{round(r.height / 72 * 25.4)} мм, поворот {p.rotation}')


def main():
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest='cmd', required=True)
    r = sp.add_parser('render'); r.add_argument('pdf'); r.add_argument('out'); r.add_argument('--dpi', type=int, default=110)
    r.add_argument('--page', type=int, default=1); r.add_argument('--box', type=float, nargs=4)
    s = sp.add_parser('stamps'); s.add_argument('path'); s.add_argument('out')
    s.add_argument('--w-mm', type=float, default=70); s.add_argument('--h-mm', type=float, default=40)
    s.add_argument('--from-right', type=float, default=5); s.add_argument('--from-bottom', type=float, default=5)
    s.add_argument('--cols', type=int, default=7); s.add_argument('--skip', type=int, default=0)
    g = sp.add_parser('grep'); g.add_argument('path'); g.add_argument('regex'); g.add_argument('--missing', action='store_true')
    z = sp.add_parser('sizes'); z.add_argument('path')
    a = ap.parse_args()
    {'render': cmd_render, 'stamps': cmd_stamps, 'grep': cmd_grep, 'sizes': cmd_sizes}[a.cmd](a)


if __name__ == '__main__':
    main()
