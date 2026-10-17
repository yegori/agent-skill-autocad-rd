# Добавить пользовательский формат листа в PMP плоттера «DWG To PDF» (AutoCAD 2024), чтобы печатались макеты
# с нестандартным форматом. Признак проблемы в логе accoreconsole: «Нет подходящего носителя».
# Имя формата должно совпадать с тем, что записано в макете (группа 4 объекта Layout), например
#   "UserDefinedMetric (594.00 x 1682.00мм)"  — ширина x высота, мм.
# python -I add_pmp_size.py "UserDefinedMetric (594.00 x 1682.00мм)" ["UserDefinedMetric (841.00 x 1783.00мм)" …] [--pmp путь]
# Перед записью кладёт копию рядом: «DWG To PDF.pmp.bak_ГГГГММДД_ЧЧММСС». Уже существующие имена пропускает.
import json, os, re, shutil, sys, datetime

args = sys.argv[1:]
pmp = os.path.expandvars(r'%APPDATA%\Autodesk\AutoCAD 2024\R24.3\rus\Plotters\PMP Files\DWG To PDF.pmp')
if '--pmp' in args:
    i = args.index('--pmp'); pmp = args[i + 1]; del args[i:i + 2]
raw = open(pmp, encoding='utf-8').read()
head, body = raw.split('\n', 1)                        # 1-я строка: PIAFILEVERSION_3.0,json
d = json.loads(body)
m = d['data'].setdefault('udm', {}).setdefault('media', {})
desc, size = m.setdefault('description', {}), m.setdefault('size', {})
have = {v.get('name') for v in size.values()}
added = []
for name in args:
    if name in have:
        print('уже есть:', name); continue
    w, h = map(float, re.search(r'\(([\d.]+)\s*x\s*([\d.]+)', name).groups())
    dn = f'User-{int(w)}x{int(h)}'
    desc[str(len(desc))] = {"caps_type": 2, "dimensional": True, "media_bounds_urx": w, "media_bounds_ury": h,
                            "name": dn, "printable_area": w * h, "printable_bounds_llx": 0.0, "printable_bounds_lly": 0.0,
                            "printable_bounds_urx": w, "printable_bounds_ury": h}
    size[str(len(size))] = {"caps_type": 2, "landscape_mode": True, "localized_name": f'Пользовательский ({w:.2f} x {h:.2f} мм)',
                            "media_description_name": dn, "media_group": 15, "name": name}
    added.append(name)
if added:
    bak = pmp + '.bak_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    shutil.copy2(pmp, bak)
    with open(pmp, 'w', encoding='utf-8', newline='\r\n') as f:
        f.write(head.rstrip('\r') + '\n' + json.dumps(d, ensure_ascii=False, indent=1))
    print('добавлено:', *added, sep='\n  '); print('копия до правки:', bak)
