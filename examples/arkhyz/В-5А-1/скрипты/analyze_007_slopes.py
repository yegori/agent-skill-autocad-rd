"""Лист 007: площади зон защиты откосов в плане и по 3D-поверхности котлована.

Поверхность строится триангуляцией (TIN) по 3D-линиям блока «Котлован_В-5А-1».
Запуск: python analyze_007_slopes.py d007.dxf
Нужны: ezdxf, numpy, scipy, shapely.
"""
import sys
import ezdxf
import numpy as np
from ezdxf import path as P
from scipy.spatial import Delaunay
from shapely.geometry import Polygon

doc = ezdxf.readfile(sys.argv[1])
msp = doc.modelspace()
blk = doc.blocks.get("Котлован_В-5А-1")

pts, outline = [], None
for e in blk:
    if e.dxftype() == "LINE":
        pts += [tuple(e.dxf.start), tuple(e.dxf.end)]
    elif e.dxftype() == "POLYLINE":
        vs = [tuple(v.dxf.location) for v in e.vertices]
        pts += vs
        outline = Polygon([(x, y) for x, y, _ in vs])
pts = np.unique(np.round(np.array(pts), 3), axis=0)
tri = Delaunay(pts[:, :2])
print(f"точек TIN: {len(pts)}, z {pts[:, 2].min():.2f}–{pts[:, 2].max():.2f}, контур котлована {outline.area:.2f} м²")


def surface_area(poly):
    plan = a3 = 0.0
    for s in tri.simplices:
        p3 = pts[s]
        t = Polygon(p3[:, :2])
        if not t.is_valid or t.area < 1e-9:
            continue
        inter = t.intersection(poly)
        if inter.is_empty:
            continue
        n = np.cross(p3[1] - p3[0], p3[2] - p3[0])
        k = np.linalg.norm(n) / abs(n[2]) if abs(n[2]) > 1e-9 else 1.0
        plan += inter.area
        a3 += inter.area * k
    return plan, a3


for e in msp.query("HATCH"):
    if e.dxf.layer not in ("inf_anti_errosion", "!габион"):
        continue
    for bp in P.from_hatch(e):
        poly = Polygon([(v.x, v.y) for v in bp.flattening(0.005)]).buffer(0)
        plan, a3 = surface_area(poly)
        print(f"{e.dxf.layer:18s} план {poly.area:8.2f}  по откосу {a3:8.2f}  k={a3 / plan:.3f}  "
              f"в контуре котлована {poly.intersection(outline).area:.2f}")
