r"""Ключевые слова по макетам файла N:  kw.py <log> <N> <regex>... — сколько раз и примеры (тексты, таблицы и выноски СПДС)."""
import re, sys, collections
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
log, n, pats = sys.argv[1], sys.argv[2], sys.argv[3:]
cur = None; hits = collections.defaultdict(list); lays = set()
for l in open(log, encoding='utf-8'):
    l = l.rstrip('\n')
    m = re.match(r'FILE\|.*~(\d+)\.dwg', l)
    if m:
        cur = m.group(1); continue
    if cur != n or not l.startswith('HIT|'):
        continue
    p = l.split(' => ')[0].split('|'); lay = p[1]; lays.add(lay)
    txt = re.sub(r'\\P', ' / ', '|'.join(p[4:]))
    for rx in pats:
        for mm in re.finditer(rx, txt, re.I):
            s = max(0, mm.start() - 50); hits[(lay, rx)].append(txt[s:mm.end() + 60])
for lay in sorted(lays):
    print(f'== макет {lay}')
    for rx in pats:
        h = hits.get((lay, rx), [])
        print(f'   {rx:<28} {len(h):>3}  ' + (' ‖ '.join(sorted(set(x.strip() for x in h))[:2])[:230] if h else ''))
