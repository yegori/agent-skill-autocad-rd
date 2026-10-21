r"""Показать таблицы СПДС и поиск по журналу.  tblshow.py <log> <N> [--handle H] [--grep RX]"""
import re, sys, collections, argparse
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
ap = argparse.ArgumentParser(); ap.add_argument('log'); ap.add_argument('n'); ap.add_argument('--handle', nargs='*', default=[]); ap.add_argument('--grep')
a = ap.parse_args()
cur = None; T = collections.defaultdict(dict); hits = []
for l in open(a.log, encoding='utf-8'):
    l = l.rstrip('\n')
    m = re.match(r'FILE\|.*~(\d+)\.dwg', l)
    if m:
        cur = m.group(1); continue
    if cur != a.n or not l.startswith('HIT|'):
        continue
    body = l.split(' => ')[0]
    m = re.match(r'HIT\|([^|]*)\|mcsDbObjectTable2\|(\w+)\|McTable\|cell (\d+),(\d+)\|(.*)$', body)
    if m:
        T[m.group(2)][(int(m.group(3)), int(m.group(4)))] = m.group(5)
    if a.grep and re.search(a.grep, body, re.I):
        hits.append(body[:260])
for h in a.handle:
    t = T[h]; R = max(r for r, c in t) + 1 if t else 0
    print(f'== таблица {h}')
    for r in range(R):
        row = [t.get((r, c), '') for c in range(max(c for _, c in t) + 1)]
        if any(row): print(f'  {r:>3}: ' + ' | '.join(x.replace('\\P', ' ')[:60] for x in row))
for h in hits:
    print('  ' + h)
