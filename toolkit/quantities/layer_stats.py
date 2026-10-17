"""Сводка геометрии по слоям DXF — для сверки «количество в модели против спецификации».

  python -I layer_stats.py <файл.dxf> [--layers L1 L2 …] [--space model|paper|all] [--narrow 0.3]

По каждому слою: число объектов по типам; замкнутые полилинии — число и суммарная площадь; штриховки — площадь;
линии/полилинии — суммарная длина; «узкие прямоугольники» (короткая сторона < --narrow) — число и сумма длинных сторон
(так считались рёбра ГСИ 0,17 м: 23 ребра, 54,42 пм против 4 шт в спецификации, В-5А-1 л.6); блоки — число вставок по имени.
3D-тела (3DSOLID) только считаются — объёмы через massprop.ps1.
"""
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')  # python -I игнорирует PYTHONIOENCODING; в pwsh: [Console]::OutputEncoding = [Text.Encoding]::UTF8
import argparse, collections, math
import ezdxf
from ezdxf import path as P
from ezdxf.math import area


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dxf'); ap.add_argument('--layers', nargs='+'); ap.add_argument('--space', default='model')
    ap.add_argument('--narrow', type=float, default=0.3)
    a = ap.parse_args()
    doc = ezdxf.readfile(a.dxf)
    spaces = [doc.modelspace()] if a.space == 'model' else ([l for l in doc.layouts if l.name != 'Model'] if a.space == 'paper' else list(doc.layouts))
    st = collections.defaultdict(lambda: {'типы': collections.Counter(), 'замкн': 0, 'S_замкн': 0.0, 'S_штрих': 0.0,
                                          'L': 0.0, 'узких': 0, 'L_узких': 0.0, 'блоки': collections.Counter()})
    for sp in spaces:
        for e in sp:
            lay = e.dxf.layer
            if a.layers and lay not in a.layers:
                continue
            s = st[lay]; t = e.dxftype(); s['типы'][t] += 1
            try:
                if t in ('LWPOLYLINE', 'POLYLINE'):
                    pts = [(v.x, v.y) for v in P.make_path(e).flattening(0.005)]
                    s['L'] += sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))
                    if e.is_closed and len(pts) > 2:
                        s['замкн'] += 1; s['S_замкн'] += abs(area(pts))
                        if t == 'LWPOLYLINE' and len(e) == 4:
                            v = list(e.vertices_in_wcs()); sides = sorted(math.dist(v[i], v[(i + 1) % 4]) for i in range(4))
                            if sides[0] < a.narrow:
                                s['узких'] += 1; s['L_узких'] += sides[-1]
                elif t == 'LINE':
                    s['L'] += math.dist(e.dxf.start, e.dxf.end)
                elif t == 'HATCH':
                    s['S_штрих'] += sum(abs(area([(v.x, v.y) for v in bp.flattening(0.005)])) for bp in P.from_hatch(e))
                elif t == 'INSERT':
                    s['блоки'][e.dxf.name] += 1
            except Exception:
                pass
    for lay, s in sorted(st.items()):
        print(f'== {lay}: ' + ', '.join(f'{k} {v}' for k, v in s['типы'].most_common()))
        if s['замкн']:
            print(f'   замкнутых контуров {s["замкн"]}, площадь {s["S_замкн"]:.2f}')
        if s['S_штрих']:
            print(f'   штриховки: площадь {s["S_штрих"]:.2f}')
        if s['L']:
            print(f'   длина линий/полилиний {s["L"]:.2f}')
        if s['узких']:
            print(f'   узких прямоугольников (< {a.narrow}) {s["узких"]}, сумма длин {s["L_узких"]:.2f}')
        if s['блоки']:
            print('   блоки: ' + ', '.join(f'{k}×{v}' for k, v in s['блоки'].most_common(10)))


if __name__ == '__main__':
    main()
