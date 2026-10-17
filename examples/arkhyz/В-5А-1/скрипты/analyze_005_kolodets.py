"""Лист 005 (колодец Км-1): габариты бетонных контуров и штриховок сечений.

Единицы чертежа — мм. Запуск: python analyze_005_kolodets.py d005.dxf
Расчёт бетона по найденным габаритам — на листе «Проверочные расчёты» сводной.
"""
import sys
import ezdxf
from ezdxf import bbox, path as P
from ezdxf.math import area

doc = ezdxf.readfile(sys.argv[1])
msp = doc.modelspace()

print("--- замкнутые контуры слоя !бетон")
for e in msp.query('LWPOLYLINE[layer=="!бетон"]'):
    b = bbox.extents([e])
    a = ""
    if e.closed:
        a = f"{abs(area([(v.x, v.y) for v in P.make_path(e).flattening(0.001)])) / 1e6:.3f} м²"
    print(f"closed={e.closed!s:5} {b.size.x:8.0f} × {b.size.y:8.0f}  {a}")

print("--- штриховки слоя «штриховка» (подготовка, сечения)")
for e in msp.query('HATCH[layer=="штриховка"]'):
    loops = [abs(area([(v.x, v.y) for v in bp.flattening(0.001)])) / 1e6 for bp in P.from_hatch(e)]
    b = bbox.extents([e])
    print(f"{e.dxf.pattern_name:8s} {b.size.x:8.0f} × {b.size.y:6.0f}  контуры, м²: {[round(x, 3) for x in loops]}")
