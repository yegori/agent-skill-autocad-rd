"""Explicitly add custom metric paper sizes to an existing DWG To PDF PMP.
Uses shared AutoCAD/Civil 3D discovery; never creates a missing PMP or chooses
between several candidates. Exact names OR existing same-orientation dimensions
prevent duplicate additions. Availability of a dimension is not plot acceptance.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

_spec = importlib.util.spec_from_file_location('pmp_catalog', Path(__file__).with_name('pmp_catalog.py'))
catalog = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(catalog)


def add_sizes(path, names):
    pmp = Path(path)
    before = pmp.read_bytes()
    head, data, entries = catalog.read_catalog(pmp)
    media = data['data'].setdefault('udm', {}).setdefault('media', {})
    desc, size = media.setdefault('description', {}), media.setdefault('size', {})
    added = []
    for name in names:
        match = catalog.match_paper(entries, name)
        if match != 'missing':
            print('уже есть:', name, '(' + match + ')')
            continue
        dims = catalog.dimensions(name)
        if not name.startswith('UserDefinedMetric') or not dims or min(dims) <= 0:
            raise ValueError('invalid_metric_paper: ' + name)
        w, h = dims
        # Numeric keys can have gaps; len(collection) can overwrite existing entries.
        def next_key(values):
            n = 0
            while str(n) in values:
                n += 1
            return str(n)
        key = next_key(desc)
        dn = 'RDCI-' + key
        existing_names = {v.get('name') for v in desc.values()}
        while dn in existing_names:
            dn += '_'
        desc[key] = dict(caps_type=2, dimensional=True, media_bounds_urx=w, media_bounds_ury=h,
                         name=dn, printable_area=w*h, printable_bounds_llx=0.0, printable_bounds_lly=0.0,
                         printable_bounds_urx=w, printable_bounds_ury=h)
        size[next_key(size)] = dict(caps_type=2, landscape_mode=True,
            localized_name=f'Пользовательский ({w:.2f} x {h:.2f} мм)',
            media_description_name=dn, media_group=15, name=name)
        entries.append(dict(name=name, dimensions_mm=dims))
        added.append(name)
    if not added:
        return []
    if pmp.read_bytes() != before:
        raise ValueError('pmp_changed_during_read')
    backup = Path(str(pmp) + '.bak_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    with backup.open('xb') as out:
        out.write(before)
    if hashlib.sha256(backup.read_bytes()).digest() != hashlib.sha256(before).digest():
        raise ValueError('pmp_backup_failed')
    # Keep original line convention; don't touch any other product/profile PMP.
    newline = '\r\n' if b'\r\n' in before else '\n'
    text = head.rstrip('\r') + '\n' + json.dumps(data, ensure_ascii=False, indent=1)
    with pmp.open('w', encoding='utf-8', newline=newline) as out:
        out.write(text)
    print('добавлено:', *added, sep='\n  ')
    print('копия до правки:', backup)
    return added


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('names', nargs='+')
    parser.add_argument('--pmp')
    args = parser.parse_args()
    resolution = catalog.resolve_pmp(args.pmp)
    if resolution['status'] != 'found':
        parser.error('PMP ' + resolution['status'] + '; specify --pmp explicitly. Candidates: ' + '; '.join(resolution['candidates']))
    try:
        add_sizes(resolution['path'], args.names)
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    main()
