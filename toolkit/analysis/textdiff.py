r"""Разница текстов двух версий DWG по журналу run_txtfix -Find '[\s\S]+' -Dry.  textdiff.py <log> <N_old>:<N_new> ..."""
import re, sys, collections
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
log, pairs = sys.argv[1], [p.split(':') for p in sys.argv[2:]]
F = collections.defaultdict(dict); cur = None
for l in open(log, encoding='utf-8'):
    l = l.rstrip('\n')
    m = re.match(r'FILE\|.*~(\d+)\.dwg', l)
    if m:
        cur = m.group(1); continue
    if l.startswith('HIT|') and cur:
        parts = l.split('|'); key = '|'.join(parts[1:-1]); F[cur][key] = parts[-1].split(' => ')[0]
for a, b in pairs:
    A, B = F[a], F[b]
    print(f'===== {a} -> {b}: было {len(A)}, стало {len(B)}')
    for k in sorted(set(A) | set(B)):
        if A.get(k) != B.get(k):
            if k not in A: print(f'  + {k} :: {B[k][:300]}')
            elif k not in B: print(f'  - {k} :: {A[k][:300]}')
            else: print(f'  ~ {k}\n      было:  {A[k][:300]}\n      стало: {B[k][:300]}')
