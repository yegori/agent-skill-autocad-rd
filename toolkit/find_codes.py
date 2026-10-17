r"""Проверка C1: коды «чужих» сооружений на листах — разбор журнала пробного поиска run_txtfix.ps1.

1) Пробный поиск всех кодов:   .\spds_text\run_txtfix.ps1 -Files <DWG…> -Find '<regex кодов>' -Repl '$0' -Dry
   (run_txtfix пишет журнал <WorkRoot>\txtfix\txtfix.log и соответствие копий исходникам map.txt)
2) Разбор:  python -I find_codes.py --codes "В-[45][АA]-\\d" --own "[\\\\/](В-\\d[АA]-\\d)[\\\\/]" [--extra "цементно-грунт\\w*|3402\\d"] [--include-model]
   --own — регулярка, извлекающая СВОЙ код из пути файла (группа 1).
   По умолчанию совпадения в пространстве модели (Model) не считаются: это обычно подписи соседних сооружений на общей подложке.
Латинская/кириллическая «А» в кодах приравниваются.
"""
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')  # python -I игнорирует PYTHONIOENCODING; в pwsh: [Console]::OutputEncoding = [Text.Encoding]::UTF8
import argparse, collections, os, re

W = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Temp', 'acc', 'txtfix')


def norm(s):
    return s.replace('A', 'А').replace('B', 'В')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--log', default=os.path.join(W, 'txtfix.log')); ap.add_argument('--map', default=os.path.join(W, 'map.txt'))
    ap.add_argument('--codes', required=True); ap.add_argument('--own', required=True)
    ap.add_argument('--extra', default=''); ap.add_argument('--include-model', action='store_true')
    a = ap.parse_args()
    src = {}
    for l in open(a.map, encoding='utf-8-sig'):
        if '\t' in l:
            n, p = l.rstrip('\n').split('\t', 1); src[n] = p
    rx_codes, rx_own = re.compile(a.codes), re.compile(a.own)
    rx_extra = re.compile(a.extra) if a.extra else None
    cur = None; res = collections.defaultdict(list); seen_lay = set()
    for l in open(a.log, encoding='utf-8'):
        l = l.rstrip('\n')
        m = re.match(r'FILE\|.*~(\d+)\.dwg', l)
        if m:
            cur = src.get(m.group(1), m.group(1)); continue
        if not l.startswith('HIT|') or cur is None:
            continue
        parts = l.split('|'); where = '|'.join(parts[1:-1]); text = parts[-1].split(' => ')[0]
        if parts[1] == 'Model' and not a.include_model:
            continue
        mo = rx_own.search(cur); own = norm(mo.group(1)) if mo else None
        lay_foreign = sorted({norm(c) for c in rx_codes.findall(parts[1])} - ({own} if own else set()))
        if lay_foreign and (cur, parts[1]) not in seen_lay:   # имя макета с чужим кодом (видно, только если на макете есть HIT)
            seen_lay.add((cur, parts[1]))
            res[(own, os.path.basename(cur))].append((', '.join(lay_foreign), parts[1], '(имя макета)'))
        foreign = sorted({norm(c) for c in rx_codes.findall(text)} - ({own} if own else set()))
        extra = rx_extra.findall(text) if rx_extra else []
        if foreign or extra:
            res[(own, os.path.basename(cur))].append((', '.join(foreign + [e if isinstance(e, str) else e[0] for e in extra]), where, text[:160]))
    if not res:
        print('Чужих кодов на листах не найдено.')
    for (own, f), items in sorted(res.items(), key=lambda x: (str(x[0][0]), x[0][1])):
        print(f'== {own} | {f}')
        for k, w, t in items:
            print(f'   [{k}] {w} :: {t}')


if __name__ == '__main__':
    main()
