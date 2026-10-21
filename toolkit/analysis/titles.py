r"""Кандидаты в наименования листов: тексты в макетах (не Model), похожие на заголовок штампа.  titles.py <log> <map>"""
import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
log, mp = sys.argv[1], sys.argv[2]
src = {}
for l in open(mp, encoding='utf-8-sig'):
    if '\t' in l:
        n, p = l.rstrip('\n').split('\t', 1); src[n] = p.split('\\')[-1]
RX = re.compile(r'(?i)водоприемн|армирован|схема|ограждени|кровл|опалубк|щит|закладн|шандор|рама|деталь|изделие|МН\d|^-?[А-Я]{1,3}-?\d')
cur = None
for l in open(log, encoding='utf-8'):
    l = l.rstrip('\n')
    m = re.match(r'FILE\|.*~(\d+)\.dwg', l)
    if m:
        cur = src.get(m.group(1)); print('=====', cur); continue
    if not l.startswith('HIT|'):
        continue
    p = l.split(' => ')[0].split('|')
    if p[1] == 'Model' or p[2] not in ('MTEXT', 'TEXT'):
        continue
    t = '|'.join(p[4:]); clean = re.sub(r'\\P', ' / ', t); clean = re.sub(r'\\[A-Za-z][^;\\{}]*;', '', clean).replace('{', '').replace('}', '')
    if RX.search(clean) and len(clean) < 260:
        print(f'  [{p[1]}] {clean}')
