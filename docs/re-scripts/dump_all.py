#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Full metadata dump of a dylib into JSON + strings extraction."""
import sys, io, json, struct, re, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sjj_macho import Fat, ObjCParser

FILES = {
    'official': r'F:/Lenovo/Documents/fudai-ios-tweak/analysis/payload/var/jb/Library/MobileSubstrate/DynamicLibraries/siwenjiajia.dylib',
    'embedded': r'F:/Lenovo/Documents/fudai-ios-tweak/dist/sjj_embedded.dylib',
}
OUT = r'F:/Lenovo/Documents/fudai-ios-tweak/docs/re-scripts'

CH_RE = re.compile(
    rb'(?:[\xe4-\xe9][\x80-\xbf]{2})+(?:[\x20-\x7e\xe4-\xe9][\x80-\xbf]{2})*')  # utf-8 CJK runs


def extract_cstrings(sl):
    """Return list of (addr, string) from cstring-like sections."""
    out = []
    for s in sl.sections:
        if s.seg != '__TEXT':
            continue
        data = s.data(sl.f)
        i = 0
        n = len(data)
        while i < n:
            j = data.find(b'\x00', i)
            if j < 0:
                j = n
            if j > i:
                b = data[i:j]
                if 2 <= len(b) <= 512:
                    try:
                        t = b.decode('utf-8')
                        # printable-ish filter
                        if all((0x20 <= ord(c) < 0x10000) or c in '\n\t' for c in t):
                            out.append((s.addr + i, t))
                    except UnicodeDecodeError:
                        pass
            i = j + 1
    return out


def dump(tag, path):
    fat = Fat(path)
    sl = fat.arm64()
    p = ObjCParser(sl)
    p.parse()

    classes = []
    for c in p.classes:
        ro = c.get('ro')
        mro = c.get('meta_ro')
        entry = {
            'addr': c['addr'],
            'name': ro['name'] if ro else None,
            'super': None,
            'instanceSize': ro['instanceSize'] if ro else None,
            'ivars': ro['ivars'] if ro else [],
            'methods': [],
            'class_methods': [],
        }
        if c['super']:
            sup, _ = sl.ptr(c['super'])
            if sup:
                supc = p.class_by_addr.get(sup)
                if supc and supc.get('ro'):
                    entry['super'] = supc['ro']['name']
        if ro and ro['methods']:
            for m in ro['methods']:
                entry['methods'].append({'name': m['name'], 'types': m['types'],
                                         'imp': m['imp']})
        if mro and mro['methods']:
            for m in mro['methods']:
                entry['class_methods'].append({'name': m['name'], 'types': m['types'],
                                               'imp': m['imp']})
        classes.append(entry)

    cats = []
    for cat in p.categories:
        cats.append({'name': cat['name'], 'cls': cat['cls_name'],
                     'imethods': cat['imethods'], 'cmethods': cat['cmethods']})

    # classrefs: slot -> resolved name
    classrefs = {}
    for s in sl.sections:
        if s.name == '__objc_classrefs':
            for i in range(s.size // 8):
                a = s.addr + i * 8
                tgt, sym = sl.ptr(a)
                if sym:
                    classrefs['0x%x' % a] = {'bind': sym}
                elif tgt:
                    nm = p.class_name_of(a)
                    classrefs['0x%x' % a] = {'target': '0x%x' % tgt, 'name': nm}

    # superrefs
    superrefs = {}
    for s in sl.sections:
        if s.name == '__objc_superrefs':
            for i in range(s.size // 8):
                a = s.addr + i * 8
                nm = p.class_name_of(a)
                superrefs['0x%x' % a] = nm

    data = {
        'path': path,
        'classes': classes,
        'categories': cats,
        'classrefs': classrefs,
        'superrefs': superrefs,
        'selref_count': len(p.sel_by_addr),
        'selrefs': {'0x%x' % k: v for k, v in p.sel_by_addr.items()},
        'imports': sorted(set(sl.bind_map.values())),
        'func_starts_count': len(sl.func_starts),
    }
    with open(os.path.join(OUT, 'dump_%s.json' % tag), 'w', encoding='utf-8') as fp:
        json.dump(data, fp, ensure_ascii=False, indent=1)

    # strings: config keys + chinese
    cstrs = extract_cstrings(sl)
    keys = [(hex(a), t) for a, t in cstrs if 'siwenjiajia' in t.lower()]
    chinese = [(hex(a), t) for a, t in cstrs if CH_RE.search(t.encode('utf-8'))]
    with open(os.path.join(OUT, 'keys_%s.txt' % tag), 'w', encoding='utf-8') as fp:
        for a, t in keys:
            fp.write('%s\t%s\n' % (a, t))
    with open(os.path.join(OUT, 'chinese_%s.txt' % tag), 'w', encoding='utf-8') as fp:
        for a, t in chinese:
            fp.write('%s\t%s\n' % (a, t))
    # all cstrings for later grep
    with open(os.path.join(OUT, 'cstrings_%s.txt' % tag), 'w', encoding='utf-8') as fp:
        for a, t in cstrs:
            fp.write('%s\t%s\n' % (a, t))

    print('[%s] classes=%d cats=%d selrefs=%d classrefs=%d imports=%d cstrings=%d keys=%d chinese=%d'
          % (tag, len(classes), len(cats), len(p.sel_by_addr), len(classrefs),
             len(set(sl.bind_map.values())), len(cstrs), len(keys), len(chinese)))


if __name__ == '__main__':
    for tag, path in FILES.items():
        dump(tag, path)
