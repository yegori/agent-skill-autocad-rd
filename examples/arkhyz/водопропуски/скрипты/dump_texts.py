import sys, re, ezdxf
doc = ezdxf.readfile(sys.argv[1])
skip = re.compile(r'^[\s\d.,+\-–=%т×xх/()]*$|^т\.\d+$|^[xyz]=')
for lay in doc.layouts:
    items = []
    for e in lay:
        t = e.dxftype()
        if t == 'MTEXT': s = e.plain_text()
        elif t == 'TEXT': s = e.dxf.text
        elif t == 'INSERT':
            for a in e.attribs:
                if not skip.match(a.dxf.text.strip()): items.append((e.dxf.insert, 'A', a.dxf.text))
            continue
        else: continue
        if skip.match(s.strip()): continue
        items.append((e.dxf.insert, t[0], s))
    items.sort(key=lambda i: (-round(i[0][1], -1), i[0][0]))
    print('=====', lay.name, len(items))
    for p, t, s in items:
        print(f'[{p[0]:.0f},{p[1]:.0f}] {t}: {s}')
