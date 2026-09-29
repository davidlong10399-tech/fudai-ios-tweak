#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Probe the FAT structure and objc metadata stats of a dylib."""
import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.path.insert(0, r'F:/Lenovo/Documents/fudai-ios-tweak/docs/re-scripts')
from sjj_macho import Fat, ObjCParser

for path in (r'F:/Lenovo/Documents/fudai-ios-tweak/analysis/payload/var/jb/Library/MobileSubstrate/DynamicLibraries/siwenjiajia.dylib',
             r'F:/Lenovo/Documents/fudai-ios-tweak/dist/sjj_embedded.dylib'):
    print('=' * 70)
    print(path.split('/')[-1])
    fat = Fat(path)
    for cputype, cpusub, off, size, sl in fat.slices:
        print('  arch cputype=0x%x cpusub=0x%x off=%d size=%d parsed=%s' % (cputype, cpusub, off, size, sl is not None))
    sl = fat.arm64()
    print('  using slice: %s cputype=0x%x filetype=%d' % (sl.name, sl.cputype, sl.filetype))
    print('  segments:')
    for seg in sl.segments:
        print('    %-16s vmaddr=0x%x vmsize=0x%x fileoff=0x%x filesize=0x%x' %
              (seg['name'], seg['vmaddr'], seg['vmsize'], seg['fileoff'], seg['filesize']))
    print('  sections:')
    for s in sl.sections:
        print('    %-24s addr=0x%x size=0x%x' % (s.fullname, s.addr, s.size))
    print('  dyld_info: %s' % ('yes' if sl.dyld_info else 'no'))
    print('  chained fixups: %s' % ('yes' if sl.chained is not None else 'no'))
    print('  chained fixups entries: %d' % (len(sl.fixups) if hasattr(sl, 'fixups') else -1))
    print('  bind_map entries: %d' % len(sl.bind_map))
    print('  func_starts: %d' % len(sl.func_starts))
    if sl.symtab:
        symoff, nsyms, stroff, strsize = sl.symtab
        print('  symtab: nsyms=%d strsize=%d' % (nsyms, strsize))
    p = ObjCParser(sl)
    p.parse()
    print('  classes: %d  categories: %d  selrefs: %d' % (len(p.classes), len(p.categories), len(p.sel_by_addr)))
    # sample own-class prefixes
    from collections import Counter
    pref = Counter()
    for c in p.classes:
        nm = c['ro']['name'] if c.get('ro') and c['ro']['name'] else '?'
        pref[nm[:3]] += 1
    print('  class name prefixes (top20):', pref.most_common(20))
    # sample imports
    syms = sorted(set(sl.bind_map.values()))
    ms = [s for s in syms if 'MSHook' in s or 'substrate' in s.lower() or 'fishhook' in s.lower()]
    print('  MSHook-ish imports:', ms[:20])
    print('  total unique imports: %d' % len(syms))
