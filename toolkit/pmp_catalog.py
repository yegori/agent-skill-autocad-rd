"""Read-only PMP discovery/catalog shared by diagnostics and the explicit writer.
No CAD, registry writes or configuration changes. Ambiguous profiles never pick a winner.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

TOLERANCE_MM = 0.05
DIMENSIONS = re.compile(r'\((\d+(?:[.,]\d+)?)\s*[xх×]\s*(\d+(?:[.,]\d+)?)', re.I)


def dimensions(text):
    match = DIMENSIONS.search(text or '')
    return tuple(float(x.replace(',', '.')) for x in match.groups()) if match else None


def same_size(a, b):
    # Orientation remains significant; do not silently rotate a media definition.
    return bool(a and b and all(abs(x-y) <= TOLERANCE_MM for x, y in zip(a, b)))


def current_profile_dirs():
    """Current profile(s) of installed R24.3 products; not the active CAD process.
    Several products/profiles may yield different directories: caller must disambiguate.
    """
    if os.name != 'nt':
        return []
    import winreg
    result = []
    root = r'Software\Autodesk\AutoCAD\R24.3'
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, root) as key:
            products = []
            i = 0
            while True:
                try:
                    products.append(winreg.EnumKey(key, i)); i += 1
                except OSError:
                    break
    except FileNotFoundError:
        return []
    for product in products:
        base = root + '\\' + product
        profile = None
        for location in (base, base + r'\Profiles'):
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, location) as key:
                    profile = winreg.QueryValueEx(key, 'CurProfile')[0]
                if profile:
                    break
            except FileNotFoundError:
                continue
        if not isinstance(profile, str) or not profile or '\\' in profile:
            continue
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, base + '\\Profiles\\' + profile + r'\General') as key:
                value = winreg.QueryValueEx(key, 'PrinterDescDir')[0]
            if isinstance(value, str):
                result.extend(os.path.expandvars(p.strip()) for p in value.split(';') if p.strip())
        except FileNotFoundError:
            continue
    return result


def resolve_pmp(explicit=None, *, appdata=None, profile_dirs=None):
    if explicit:
        candidates = [Path(os.path.expandvars(str(explicit))).absolute()]
        source = 'explicit'
    else:
        dirs = current_profile_dirs() if profile_dirs is None else profile_dirs
        if dirs:
            candidates = [Path(p) / 'DWG To PDF.pmp' for p in dirs]
            source = 'current_registered_profiles'
        else:
            base = Path(appdata if appdata is not None else os.environ.get('APPDATA', ''))
            candidates = []
            if str(base) != '.':
                for product in ('AutoCAD 2024/R24.3', 'C3D 2024'):
                    for lang in ('rus', 'enu'):
                        candidates.append(base/'Autodesk'/product/lang/'Plotters'/'PMP Files'/'DWG To PDF.pmp')
            source = 'known_locations'
    unique = {os.path.normcase(str(p.absolute())): p.absolute() for p in candidates}
    existing = [p for p in unique.values() if p.is_file()]
    status = 'found' if len(existing) == 1 else 'ambiguous' if len(existing) > 1 else 'missing'
    if source == 'current_registered_profiles' and len(unique) > 1:
        # Even a missing PMP in another current profile is not permission to
        # modify the one existing product's configuration on its behalf.
        status = 'ambiguous'
    return dict(status=status, source=source, path=str(existing[0]) if status == 'found' else None,
                candidates=[str(p) for p in unique.values()], existing=[str(p) for p in existing])


def read_catalog(path):
    raw = Path(path).read_text(encoding='utf-8-sig')
    head, body = raw.split('\n', 1)
    data = json.loads(body)
    media = data.get('data', {}).get('udm', {}).get('media', {})
    descriptions = {v.get('name'): v for v in media.get('description', {}).values()}
    entries = []
    for value in media.get('size', {}).values():
        dim = dimensions(value.get('name')) or dimensions(value.get('localized_name'))
        if dim is None:
            desc = descriptions.get(value.get('media_description_name'), {})
            try:
                dim = (float(desc['media_bounds_urx']) - float(desc.get('media_bounds_llx', 0)),
                       float(desc['media_bounds_ury']) - float(desc.get('media_bounds_lly', 0)))
            except (KeyError, TypeError, ValueError):
                pass
        entries.append(dict(name=value.get('name'), localized_name=value.get('localized_name'), dimensions_mm=dim))
    return head, data, entries


def match_paper(entries, paper):
    if any(e['name'] == paper for e in entries):
        return 'exact_name'
    if any(same_size(dimensions(paper), e['dimensions_mm']) for e in entries):
        return 'dimensions_only'
    return 'missing'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pmp')
    parser.add_argument('--inspect', action='store_true')
    args = parser.parse_args()
    result = resolve_pmp(args.pmp)
    if args.inspect and result['status'] == 'found':
        _, _, result['entries'] = read_catalog(result['path'])
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    main()
