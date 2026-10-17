"""Лист 006 (КВ-1): состав рядов ГСИ по DWG.

- ряд 1: плоские контуры слоя inf_gsi_apron_mat (+ 3D-тела, объёмы — из .mpr);
- ряд 2: 3D-тела слоя inf_gsi_ditch_wall (объёмы — из .mpr);
- ряд 3: рёбра — прямоугольники шириной 0,17 м на слое inf_gsi_ditch_rib.

Запуск: python analyze_006_gsi.py d006.dxf <папка с .mpr>
Тела ezdxf не читает (формат SAB этого DWG) — объёмы берутся из MASSPROP (massprop_006.ps1).
"""
import glob
import math
import re
import sys
import ezdxf
from ezdxf import path as P
from ezdxf.math import area

doc = ezdxf.readfile(sys.argv[1])
msp = doc.modelspace()
mp_dir = sys.argv[2] if len(sys.argv) > 2 else "mp"
dist = lambda a, b: math.hypot(a.x - b.x, a.y - b.y)

ribs = []
for e in msp.query('LWPOLYLINE[layer=="inf_gsi_ditch_rib"]'):
    if e.closed and len(e) == 4:
        p = list(e.vertices_in_wcs())
        s = sorted(dist(p[i], p[(i + 1) % 4]) for i in range(4))
        if s[0] < 0.3:
            ribs.append(s[-1])
print(f"Ряд 3: рёбер {len(ribs)}, суммарная длина {sum(ribs):.2f} пм")

mats = 0.0
n = 0
for e in msp.query('LWPOLYLINE[layer=="inf_gsi_apron_mat"]'):
    pts = [(v.x, v.y) for v in P.make_path(e).flattening(0.005)]
    a = abs(area(pts)) if len(pts) > 2 else 0
    mats += a
    n += 1
print(f"Ряд 1: плоских контуров {n}, площадь {mats:.2f} м²")

for lay in ("inf_gsi_apron_mat", "inf_gsi_ditch_wall"):
    vols = []
    for f in glob.glob(f"{mp_dir}/{lay}_*.mpr"):
        t = open(f, encoding="cp1251", errors="ignore").read()
        m = re.search(r"(Объем|Volume)\s*:\s*([\d.]+)", t)
        if m:
            vols.append(float(m.group(2)))
    print(f"{lay}: тел {len(vols)}, объём {sum(vols):.2f} м³")
