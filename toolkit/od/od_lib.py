# Библиотека для сборки листа «Общие данные» (ОД) по образцу через accoreconsole.
# Генератор проекта (см. example_gen_od.py) импортирует её, собирает текст и таблицы и пишет два .scr:
#   <key>_od.scr — правка ОД (MTEXT указаний, атрибуты Лист/Листов, удаление старых и построение новых ведомостей),
#   <key>_sh.scr — правка внешней ссылки штампа (наименование, шифр).
# Handle-ы объектов — из конкретного образца ОД (найти: dump_layout_texts.ps1 / ezdxf по DXF образца).
import math

# ---------- строки LISP
def ls(s):
    """Строка Python -> строковый литерал LISP. ^I (как в DXF) -> табуляция."""
    s = s.replace('^I', '\t')
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\t', '\\t') + '"'


def set_mtext(handle, text, chunk=200):
    """Заменить содержимое MTEXT целиком. Длинный текст режется на куски <=200 (группы 3 + последняя 1):
    длинная строка в .scr ломает ввод консоли. Коды MTEXT (\\P, \\pi…, {\\C256;…}) передаются как есть."""
    text = text.replace('^I', '\t')
    ch = [text[i:i + chunk] for i in range(0, len(text), chunk)] or ['']
    g3 = ''.join(f'(setq g3 (append g3 (list (cons 3 {ls(c)}))))\n' for c in ch[:-1])
    return (f'(setq ed (entget (handent "{handle}")))\n'
            f'(setq ed (vl-remove-if (function (lambda (x) (member (car x) (quote (1 3))))) ed))\n'
            f'(setq g3 nil)\n{g3}'
            f'(setq ed (append ed g3 (list (cons 1 {ls(ch[-1])}))))\n'
            f'(if (entmod ed) (princ "\\nOK-{handle}") (princ "\\nFAIL-{handle}"))\n')


def set_attr(handle, text):
    """Заменить значение атрибута (handle самого ATTRIB)."""
    return (f'(setq ed (entget (handent "{handle}")))\n'
            f'(setq ed (subst (cons 1 {ls(text)}) (assoc 1 ed) ed))\n'
            f'(if (entmod ed) (princ "\\nOK-{handle}") (princ "\\nFAIL-{handle}"))\n')


def delete_handles(handles):
    return ''.join(f'(entdel (handent "{h}"))\n' for h in handles)


def old_table_entities(base_dxf, layout, layer, xmax=None, xmin=None):
    """Handle-ы LINE/TEXT старых ведомостей в образце (по слою и, при необходимости, по X), чтобы их удалить.
    Работает, если таблицы СПДС в образце взорваны (в консоли объекты СПДС — прокси, не правятся)."""
    import ezdxf
    doc = ezdxf.readfile(base_dxf)
    res = []
    for e in doc.layouts.get(layout):
        if e.dxftype() not in ('LINE', 'TEXT') or e.dxf.layer != layer:
            continue
        x = e.dxf.start[0] if e.dxftype() == 'LINE' else e.dxf.insert[0]
        if (xmax is None or x < xmax) and (xmin is None or x > xmin):
            res.append(e.dxf.handle)
    return res


# ---------- ведомости из LINE + TEXT
class Tables:
    """Построитель ведомостей ОД из отрезков и однострочных текстов на листе (paper space, макет `layout`).
    Сетка задаётся координатами колонок; высота строк 8 (3-строчные ссылочные — 11.35), шапка 12 / 15."""

    def __init__(self, layout, layer, style='ГОСТ 2.304', h=2.5, oblique_deg=15):
        self.layout, self.layer, self.style, self.h, self.obl = layout, layer, style, h, math.radians(oblique_deg)
        self.items = []

    def line(self, x1, y1, x2, y2, lw=None):
        lwp = f' (cons 370 {lw})' if lw else ''
        self.items.append(f'(entmake (list (cons 0 "LINE") (cons 67 1) (cons 410 {ls(self.layout)}) (cons 8 {ls(self.layer)})'
                          f' (list 10 {x1:.4f} {y1:.4f} 0.0) (list 11 {x2:.4f} {y2:.4f} 0.0){lwp}))')

    def text(self, s, x, y, center=False, h=None):
        h = h or self.h
        self.items.append(f'(entmake (list (cons 0 "TEXT") (cons 67 1) (cons 410 {ls(self.layout)}) (cons 8 {ls(self.layer)})'
                          f' (cons 7 {ls(self.style)}) (cons 40 {h}) (cons 51 {self.obl:.6f}) (cons 1 {ls(s)})'
                          f' (list 10 {x:.4f} {y:.4f} 0.0) (list 11 {x:.4f} {y:.4f} 0.0)'
                          f' (cons 72 {1 if center else 0}) (cons 73 2)))')

    def sheet_table(self, title, top, rows, x0, x1, xn, x2, heads=('Лист', 'Наименование', 'Примечание')):
        """Ведомость «Лист | Наименование | Примечание». rows = [(номер, наименование)]. Возвращает низ таблицы."""
        self.text(title, (x0 + x2) / 2, top + 6, True, 3.5)
        hdr = top - 12; bot = hdr - 8 * len(rows)
        self.line(x0, top, x2, top, 40); self.line(x0, hdr, x2, hdr, 40)
        for i in range(1, len(rows)):
            self.line(x0, hdr - 8 * i, x2, hdr - 8 * i, 20)
        self.line(x0, bot, x2, bot, 40)
        for x in (x0, x1, xn, x2):
            self.line(x, top, x, bot, 40)
        for s, x in zip(heads, ((x0 + x1) / 2, (x1 + xn) / 2, (xn + x2) / 2)):
            self.text(s, x, top - 6, True)
        for i, (n, name) in enumerate(rows):
            y = hdr - 8 * i - 4
            self.text(n, (x0 + x1) / 2, y, True); self.text(name, x1 + 2, y)
        return bot

    def refs_table(self, title, top, refs, x0, xo, xn, x2, section='Ссылочные документы'):
        """Ведомость ссылочных документов. refs = [(обозначение, [строка1, строка2, …])], до 3 строк наименования."""
        self.text(title, (x0 + x2) / 2, top + 3.96, True, 3.5)
        hdr = top - 15
        for s, x in (('Обозначение', (x0 + xo) / 2), ('Наименование', (xo + xn) / 2), ('Примечание', (xn + x2) / 2)):
            self.text(s, x, top - 7.5, True)
        self.line(x0, top, x2, top, 40); self.line(x0, hdr, x2, hdr, 40)
        y = hdr
        self.text('%%u' + section, (xo + xn) / 2, y - 4, True)
        y -= 8
        for code, name in refs:
            self.line(x0, y, x2, y)
            h = 11.35 if len(name) == 3 else 8
            mid = y - h / 2
            self.text(code, (x0 + xo) / 2, mid, True)
            step = 3.8 if len(name) == 3 else 3.7
            for k, s in enumerate(name):
                self.text(s, xo + 1, mid + step * ((len(name) - 1) / 2 - k))
            y -= h
        self.line(x0, y, x2, y, 40)
        for x in (x0, xo, xn, x2):
            self.line(x, top, x, y, 40)
        return y

    def lisp(self):
        return '\n'.join(self.items) + '\n'


# ---------- обвязка .scr
HEAD = '(vl-load-com)\n(setvar "FILEDIA" 0)\n(setvar "CMDECHO" 0)\n'
TAIL = '(princ "\\nDONE-EDIT")\n(command "_.QSAVE")\n(command "_.QUIT" "_N")\n'


def write_scr(path, body):
    """.scr для accoreconsole — только cp1251 и CRLF."""
    with open(path, 'w', encoding='cp1251', newline='\r\n') as f:
        f.write(HEAD + body + TAIL)


# Полезные куски форматирования MTEXT (из ОД образца): маркер-точка и отступы пунктов.
BULLET = '{\\fSymbol|b0|i0|c2|p18;·^I}'
SUBHEAD = '\\P\\pi3,l0,tz;'
ITEM = '\\P\\pi-3,l6,t6;'
DIAMETER = '\\U+2205'   # знак Ø (его нет в cp1251)
