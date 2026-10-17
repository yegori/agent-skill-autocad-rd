"""Площадь зон (штриховок) в плане и по 3D-поверхности откоса — проверка «посчитано по плану вместо откоса».

  python -I slope_area.py <файл.dxf> --hatch-layers "inf_anti_errosion" "!габион" (--tin-block "Котлован_В-5А-1" | --tin-layers L1 L2)

Поверхность — триангуляция Делоне (TIN) по вершинам 3D-линий/полилиний блока или слоёв. Для каждой штриховки:
площадь в плане, площадь по поверхности (каждый треугольник с наклоном), коэффициент k = 3D/план.
Пример (В-5А-1, л.7): противоэрозия 211,34 м² в плане → 298,5 м² по откосу; ГСИ на откосе 80,95 → 108,6 м² (k≈1,34) —
количества анкеров/геоматов, посчитанные по плану, занижены.
Нужны: ezdxf, numpy, scipy, shapely.
"""
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')  # python -I игнорирует PYTHONIOENCODING; в pwsh: [Console]::OutputEncoding = [Text.Encoding]::UTF8
import argparse
import ezdxf
import numpy as np
from ezdxf import path as P
from scipy.spatial import Delaunay
from shapely.geometry import Polygon


def collect(entities):
    pts = []
    for e in entities:
        t = e.dxftype()
        if t == 'LINE':
            pts += [tuple(e.dxf.start), tuple(e.dxf.end)]
        elif t == 'POLYLINE':
            pts += [tuple(v.dxf.location) for v in e.vertices]
        elif t == '3DFACE':
            pts += [tuple(e.dxf.get(f'vtx{i}')) for i in range(4)]
    return pts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dxf'); ap.add_argument('--hatch-layers', nargs='+', required=True)
    ap.add_argument('--tin-block'); ap.add_argument('--tin-layers', nargs='+')
    a = ap.parse_args()
    doc = ezdxf.readfile(a.dxf); msp = doc.modelspace()
    if a.tin_block:
        pts = collect(doc.blocks.get(a.tin_block))
    else:
        pts = collect(e for e in msp if e.dxf.layer in a.tin_layers)
    pts = np.unique(np.round(np.array(pts, dtype=float), 3), axis=0)
    if len(pts) < 3:
        raise SystemExit('мало точек для поверхности')
    tri = Delaunay(pts[:, :2])
    print(f'точек TIN: {len(pts)}, z {pts[:, 2].min():.2f}–{pts[:, 2].max():.2f}')
    tris = []
    for s in tri.simplices:
        p3 = pts[s]; t = Polygon(p3[:, :2])
        if not t.is_valid or t.area < 1e-9:
            continue
        n = np.cross(p3[1] - p3[0], p3[2] - p3[0])
        tris.append((t, np.linalg.norm(n) / abs(n[2]) if abs(n[2]) > 1e-9 else 1.0))
    tot_p = tot_3 = 0.0
    for e in msp.query('HATCH'):
        if e.dxf.layer not in a.hatch_layers:
            continue
        for bp in P.from_hatch(e):
            poly = Polygon([(v.x, v.y) for v in bp.flattening(0.005)]).buffer(0)
            plan = a3 = 0.0
            for t, k in tris:
                inter = t.intersection(poly)
                if not inter.is_empty:
                    plan += inter.area; a3 += inter.area * k
            tot_p += poly.area; tot_3 += a3
            print(f'{e.dxf.layer:20s} план {poly.area:9.2f}  по поверхности {a3:9.2f}  k={a3 / plan if plan else 0:.3f}'
                  + ('' if abs(plan - poly.area) < 0.01 * poly.area else f'  (вне TIN {poly.area - plan:.2f})'))
    print(f'ИТОГО план {tot_p:.2f}, по поверхности {tot_3:.2f}')


if __name__ == '__main__':
    main()
