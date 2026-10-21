r"""Разница текстов между двумя журналами: xdiff.py <logA> <NA> <logB> <NB> [--width 250]"""
import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
def load(log, n):
    cur = None; d = {}
    for l in open(log, encoding='utf-8'):
        l = l.rstrip('\n')
        m = re.match(r'FILE\|.*~(\d+)\.dwg', l)
        if m:
            cur = m.group(1); continue
        if cur == n and l.startswith('HIT|'):
            p = l.split(' => ')[0].split('|')
            if p[2] in ('MTEXT', 'TEXT') or p[2].startswith('INSERT'):
                key = '|'.join(p[1:4]); txt = '|'.join(p[4:])
            else:
                key = '|'.join(p[1:6]); txt = '|'.join(p[6:])
            d[key] = txt
    return d
A, B = load(sys.argv[1], sys.argv[2]), load(sys.argv[3], sys.argv[4])
W = 250
print(f'было {len(A)}, стало {len(B)}')
for k in sorted(set(A) | set(B)):
    a, b = A.get(k), B.get(k)
    if a == b:
        continue
    if a is None: print(f'  + {k} :: {b[:W]}')
    elif b is None: print(f'  - {k} :: {a[:W]}')
    else:
        # показать окрестность первого отличия
        i = next((j for j in range(min(len(a), len(b))) if a[j] != b[j]), min(len(a), len(b)))
        print(f'  ~ {k}\n      было:  …{a[max(0, i-80):i+150]}\n      стало: …{b[max(0, i-80):i+150]}')
