# ШАБЛОН генератора ОД. Скопировать в _claude проекта, заполнить HANDLES (из своего образца) и DATA (по своим листам).
# Запуск через build_od.ps1:  python -I gen.py <base.dxf> <out_dir> <key>
# Живые примеры: «РОИНГ\Архыз ВО…\Водопропуски\_claude\скрипты\gen_od.py» и «…\площадной дренаж\_claude\скрипты\gen_od_pd.py».
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')  # python -I игнорирует PYTHONIOENCODING; в pwsh: [Console]::OutputEncoding = [Text.Encoding]::UTF8
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # od_lib рядом; если генератор лежит в проекте — указать путь к od
from od_lib import Tables, set_mtext, set_attr, delete_handles, old_table_entities, write_scr, BULLET, ITEM, SUBHEAD

BASE, OUT, KEY = sys.argv[1], sys.argv[2], sys.argv[3]

# ---- 1. Привязка к образцу ОД (найти один раз: dump_layout_texts.ps1 -Dwg образец; handle — в 2-й колонке вывода)
HANDLES = dict(
    general='2A49E',     # MTEXT «Общие указания»
    hidden='2B948',      # MTEXT «Виды работ, по которым необходимо составление актов…»
    sheet='2A493',       # ATTRIB «Лист» в штампе ОД
    sheets='2B05C',      # ATTRIB «Листов»
    stamp_title='157',   # MTEXT наименования во внешней ссылке штамп.dwg
    stamp_code='15B',    # MTEXT шифра в штамп.dwg
)
LAYOUT, LAYER = 'ОД', 'КЖ-текст'                           # макет ОД и слой взорванных ведомостей образца
GRID = dict(x0=4538.15, x1=4553.15, xn=4693.15, x2=4723.15, xo=4604.33, top=1699.57, xmax_old=4735)  # сетка ведомостей образца

# ---- 2. Данные сооружения (ключ -> параметры)
DATA = {
    'demo': dict(code='01/B590.000000.0.0-ИЗ0', title='Водоотведение. \\PГорнолыжная трасса T0.\\PСооружение X',
                 sheets=['Общие данные', 'Схема расположения', 'Продольный профиль'],
                 specs=[('3', 'Спецификация к профилю')],
                 refs=[('СП 45.13330.2017', ['«Земляные сооружения, основания и', 'фундаменты»'])],
                 L='100,0'),
}
S = DATA[KEY]

# ---- 3. Текст «Общих указаний» — коды MTEXT как в образце (\\P — абзац, ^I — табуляция, \\pi… — отступы)
general = (
    '\\A1;{\\C256;1.^IРабочая документация разработана на основании …}'
    f'\\P5.^IКонструктивные решения: … длиной {S["L"]}м …'
    f'{ITEM}{BULLET}СП 45.13330.2017 «Земляные сооружения, основания и фундаменты».'
)
hidden = '\\pxi-3,l3,t3;' + '\\P'.join(f'{i}.^I{t}' for i, t in enumerate(['Разработка котлована…', 'Обратная засыпка…'], 1))

# ---- 4. Ведомости
g = GRID; tb = Tables(LAYOUT, LAYER)
bot = tb.sheet_table('ВЕДОМОСТЬ РАБОЧИХ ЧЕРТЕЖЕЙ ОСНОВНОГО КОМПЛЕКТА', g['top'],
                     [(str(i), s) for i, s in enumerate(S['sheets'], 1)], g['x0'], g['x1'], g['xn'], g['x2'])
bot = tb.sheet_table('ВЕДОМОСТЬ СПЕЦИФИКАЦИЙ', bot - 12, S['specs'], g['x0'], g['x1'], g['xn'], g['x2'])
low = tb.refs_table('ВЕДОМОСТЬ ССЫЛОЧНЫХ И ПРИЛАГАЕМЫХ ДОКУМЕНТОВ', bot - 16.88, S['refs'], g['x0'], g['xo'], g['xn'], g['x2'])
# assert low > <низ рамки + запас>, 'ведомости не помещаются'

old = old_table_entities(BASE, LAYOUT, LAYER, xmax=g['xmax_old'])
H = HANDLES
write_scr(os.path.join(OUT, f'{KEY}_od.scr'),
          set_mtext(H['general'], general) + set_mtext(H['hidden'], hidden)
          + set_attr(H['sheet'], '1') + set_attr(H['sheets'], str(len(S['sheets'])))
          + delete_handles(old) + tb.lisp())
write_scr(os.path.join(OUT, f'{KEY}_sh.scr'), set_mtext(H['stamp_title'], S['title']) + set_mtext(H['stamp_code'], S['code']))
print(KEY, 'листов', len(S['sheets']), 'удалить старых', len(old), 'низ ведомостей', round(low, 1))
