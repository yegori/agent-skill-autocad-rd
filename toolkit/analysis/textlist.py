r"""Все тексты файла N из журнала run_txtfix -Dry (кроме Model, если не --model).  textlist.py <log> <N> [--model]"""
import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
log, n = sys.argv[1], sys.argv[2]; model = '--model' in sys.argv
cur = None
for l in open(log, encoding='utf-8'):
    l = l.rstrip('\n')
    m = re.match(r'FILE\|.*~(\d+)\.dwg', l)
    if m:
        cur = m.group(1); continue
    if cur == n and l.startswith('HIT|'):
        body = l.split(' => ')[0]; p = body.split('|')
        if p[1] == 'Model' and not model:
            continue
        if p[2] == 'mcsDbObjectTable2':
            print(f'  {p[2][:5]} {p[3]} {p[5]:<11} {"|".join(p[6:])}')
        else:
            print(f'  {p[2]:<6} {p[3]:<6} {"|".join(p[4:])}')
