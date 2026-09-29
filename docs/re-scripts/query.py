#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Query the xref engine for autoplay-related evidence."""
import sys, os, io, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xref import Xref, OFFICIAL, EMBEDDED

KEY_SELS = ['scrollToNextVideo', 'YYYisEnableAutoPlay', 'consumeNextTap',
            'setConsumeNextTap:', 'setNextSlideDistance:', 'swipeToNextStory',
            'scrollViewWillEndDragging:withVelocity:targetContentOffset:']


def run(path, dump, tag, out):
    x = Xref(path, dump)
    print('[%s] stubs: %d auth, %d objc' % (tag, len(x.stub_symbol), len(x.objc_stub_sel)))
    x.scan()
    w = open(out, 'w', encoding='utf-8')
    P = lambda s: (w.write(s + '\n'), print(s))

    # 1. which key selectors exist
    P('==== KEY SELECTORS ====')
    allsels = set(x.sel_by_addr.values())
    for k in KEY_SELS:
        P('%-55s selrefs=%d' % (k, len(x.selref_addrs.get(k, []))))

    # 2. xrefs for key selectors
    for k in KEY_SELS:
        addrs = x.selref_addrs.get(k, [])
        if not addrs:
            continue
        P('---- %s' % k)
        for a in addrs:
            sites = x.sites_referencing(a)
            for site, kind in sites:
                f = x.func_of(site)
                P('   ref@0x%x (%s) in [0x%x] %s' % (site, kind, f or 0, x.fn_label(f) if f else '?'))
            csites = []
            for stub_addr, sel in x.objc_stub_sel.items():
                if sel == k:
                    csites += x.sites_calling(stub_addr)
            for site in csites:
                f = x.func_of(site)
                P('   call(stub)@0x%x in [0x%x] %s' % (site, f or 0, x.fn_label(f) if f else '?'))

    # 3. autoplay-ish selectors by keyword
    P('==== AUTOPLAY-ISH SELECTORS (referenced) ====')
    import re
    kw = re.compile(r'(?i)(autoplay|autoslide|nextslide|nextvideo|scrollnext|swipenext|autonext|wakeslide|smoothswipe|nextmedia|feedscroll|switchvideo|nextstory|autobrowse|autoscroll|autoread)')
    hits = sorted(s for s in allsels if kw.search(s))
    for s in hits:
        nref = sum(len(x.sites_referencing(a)) for a in x.selref_addrs.get(s, []))
        P('   %-70s selrefs=%d refs=%d' % (s, len(x.selref_addrs.get(s, [])), nref))

    # 4. hook installers: functions calling method_setImplementation/class_addMethod
    P('==== HOOK INSTALLERS (call method_setImplementation / class_addMethod) ====')
    hookapi = {}
    for sa, sym in x.stub_symbol.items():
        if sym in ('_method_setImplementation', '_class_addMethod', '_method_exchangeImplementations',
                   '_class_getInstanceMethod', '_class_getClassMethod', '_objc_getClass',
                   '_method_getImplementation'):
            hookapi.setdefault(sym, set()).add(sa)
    installer_funcs = set()
    for sym, stubs in hookapi.items():
        for st in stubs:
            for site in x.sites_calling(st):
                f = x.func_of(site)
                if f is not None:
                    installer_funcs.add(f)
    print('installer funcs: %d' % len(installer_funcs))
    for f in sorted(installer_funcs):
        callsyms = []
        for site, tgt in x.calls_in_func(f):
            sym = x.stub_symbol.get(tgt)
            if sym:
                callsyms.append(sym[1:])
        # referenced classrefs and selrefs in this function
        clss, sels = [], []
        for site, kind, t in x.refs_in_func(f):
            c = x.classref_by_addr.get(t)
            if c:
                clss.append(c)
            s2 = x.sel_by_addr.get(t)
            if s2:
                sels.append(s2)
        P('[0x%x] %s' % (f, x.fn_label(f)))
        P('    api: %s' % ','.join(sorted(set(callsyms))))
        P('    classes: %s' % ','.join(sorted(set(clss))))
        P('    sels(%d): %s' % (len(set(sels)), ','.join(sorted(set(sels))[:40])))

    w.close()
    return x


if __name__ == '__main__':
    base = os.path.dirname(os.path.abspath(__file__))
    run(OFFICIAL, os.path.join(base, 'dump_official.json'), 'official',
        os.path.join(base, 'q_official.txt'))
    run(EMBEDDED, os.path.join(base, 'dump_embedded.json'), 'embedded',
        os.path.join(base, 'q_embedded.txt'))
