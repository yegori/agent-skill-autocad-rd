r"""Арифметика спецификаций (таблицы СПДС из журнала run_txtfix -Dry):
  кол × масса ед. = масса общая; масса ед. стержня = погонная масса(Ø) × L; итоги разделов.
  specarith.py <log> <map>"""
import re, sys, collections
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
log, mp = sys.argv[1], sys.argv[2]
src = {}
for l in open(mp, encoding='utf-8-sig'):
    if '\t' in l:
        n, p = l.rstrip('\n').split('\t', 1); src[n] = p.split('\\')[-1]
KG_M = {5: 0.154, 6: 0.222, 8: 0.395, 10: 0.617, 12: 0.888, 14: 1.208, 16: 1.578, 18: 1.998, 20: 2.466, 22: 2.984, 25: 3.853, 28: 4.834, 32: 6.313}
T = collections.defaultdict(dict); cur = None; lay = {}
for l in open(log, encoding='utf-8'):
    l = l.rstrip('\n')
    m = re.match(r'FILE\|.*~(\d+)\.dwg', l)
    if m:
        cur = src.get(m.group(1)); continue
    m = re.match(r'HIT\|([^|]*)\|mcsDbObjectTable2\|(\w+)\|McTable\|cell (\d+),(\d+)\|(.*?)( => .*)?$', l)
    if m:
        k = (cur, m.group(2)); T[k][(int(m.group(3)), int(m.group(4)))] = m.group(5); lay[k] = m.group(1)
def num(s):
    s = (s or '').strip().replace(',', '.')
    return float(s) if re.fullmatch(r'-?\d+(\.\d+)?', s) else None
for (f, h), t in T.items():
    R = max(r for r, _ in t) + 1; C = max(c for _, c in t) + 1
    head = ' '.join(t.get((r, c), '') for r in range(min(R, 3)) for c in range(C)).lower()
    if 'кол' not in head or 'масс' not in head:
        continue
    # колонки: ищем Кол, Масса ед., и следующую числовую (общая/примечание)
    hdr = {c: ' '.join(t.get((r, c), '') for r in range(min(R, 3))).lower() for c in range(C)}
    ck = next((c for c in range(C) if 'кол' in hdr[c]), None)
    cm = next((c for c in range(C) if 'масс' in hdr[c]), None)
    if ck is None or cm is None:
        continue
    title = t.get((0, 0), '')[:60]
    probs = []
    for r in range(R):
        row = [t.get((r, c), '') for c in range(C)]
        k, me = num(row[ck]), num(row[cm])
        if k is None or me is None:
            continue
        tot = next((num(x) for x in row[cm + 1:] if num(x) is not None), None)
        name = ' | '.join(row)
        if tot is not None and abs(k * me - tot) > max(0.02, 0.006 * tot):
            probs.append(f'стр.{r}: {k:g} × {me:g} = {k*me:.2f}, а указано {tot:g}   [{row[ck-1][:50]}]')
        mm = re.search(r'(?:%%[cC]|Ø|ø|ф)\s*(\d+)[^|]*?L\s*=\s*(\d[\d ]*\d|\d)', name)
        if mm and int(mm.group(1)) in KG_M:
            Lmm = int(mm.group(2).replace(' ', '')); calc = KG_M[int(mm.group(1))] * Lmm / 1000
            if abs(calc - me) > max(0.02, 0.015 * calc):
                probs.append(f'стр.{r}: Ø{mm.group(1)} L={Lmm} → {calc:.3f} кг/шт, а указано {me:g}')
    print(f'== {f} | {lay[(f, h)]} | {h} | {title}')
    for p in probs:
        print('   ! ' + p)
    if not probs:
        print('   арифметика строк в порядке')
