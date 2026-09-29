#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Extract hook tables: for each call to a generic hook helper, recover
(class, selector, newImp, origOut) via backward window dataflow."""
import sys, os, io, json, struct, bisect, re
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xref import Xref, OFFICIAL, EMBEDDED
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

BR = re.compile(r'\[(\w+)(?:,\s*#(-?0x[0-9a-fA-F]+|-?\d+))?\]')

# helper funcs: addr -> {cls_reg, sel_reg, imp_reg, out_reg}
HOOK_HELPERS_OFFICIAL = {0x2e8f00: ('x0', 'x1', 'x2', 'x3')}


def window_values(x, site, window=90):
    """Disassemble [site-window*4, site) tracking reg -> value."""
    md = x.md
    start = site - window * 4
    if start < 0:
        start = 0
    vals = {}
    pend_page = {}
    try:
        code = x.f[start:site]
    except Exception:
        return vals
    for ins in md.disasm(code, start):
        m, ops = ins.mnemonic, ins.op_str
        try:
            if m == 'adrp':
                reg, page = ops.split(', ')
                pend_page[reg] = int(page.lstrip('#'), 16)
                vals[reg] = ('page', int(page.lstrip('#'), 16))
            elif m == 'add':
                parts = [p.strip() for p in ops.split(',')]
                if len(parts) == 3 and parts[1] in pend_page:
                    imm = int(parts[2].lstrip('#'), 0)
                    tgt = pend_page[parts[1]] + imm
                    pend_page[parts[0]] = tgt
                    vals[parts[0]] = ('addr', tgt)
            elif m.startswith('ldr') or m.startswith('ldur'):
                mm = BR.search(ops)
                if mm:
                    dst = ops.split(',')[0].strip()
                    base = mm.group(1)
                    imm = int(mm.group(2), 0) if mm.group(2) else 0
                    if base in pend_page:
                        tgt = pend_page[base] + imm
                        vals[dst] = ('load', tgt)
                    elif base in vals:
                        vals[dst] = ('load', vals[base][1] + imm)
            elif m == 'mov':
                parts = [p.strip() for p in ops.split(',')]
                if len(parts) == 2 and parts[1] in vals:
                    vals[parts[0]] = vals[parts[1]]
                elif len(parts) == 2 and parts[1].startswith('#0x'):
                    vals[parts[0]] = ('imm', int(parts[1].lstrip('#'), 0))
                elif len(parts) == 3 and parts[1] == 'x29':  # frame var
                    vals[parts[0]] = ('frame', parts[2])
            elif m == 'blr' or m == 'bl':
                pass
        except Exception:
            continue
    return vals


def classify(x, val):
    if not val:
        return None
    kind, v = val
    if kind == 'addr':
        lbl = x.target_label(v)
        return ('addr', v, lbl)
    if kind == 'load':
        # selref / classref / got load
        lbl = x.target_label(v)
        return ('load', v, lbl or 'data_0x%x' % v)
    if kind == 'imm':
        return ('imm', v, None)
    return (kind, v, None)


def extract_hooks(x, helper_addr, argregs, out_list):
    sites = x.sites_calling(helper_addr)
    for site in sites:
        vals = window_values(x, site)
        rec = {'site': site, 'func': x.func_of(site)}
        for name, reg in zip(('cls', 'sel', 'imp', 'out'), argregs):
            rec[name] = classify(x, vals.get(reg))
        # enrich: imp owner
        if rec['imp'] and rec['imp'][0] in ('addr', 'load'):
            v = rec['imp'][1]
            own = x._imp_of.get(v)
            if own:
                rec['imp_owner'] = '%s %s%s' % (own[0], '+' if own[2] else '-', own[1])
        out_list.append(rec)


def main(which='official'):
    path = OFFICIAL if which == 'official' else EMBEDDED
    x = Xref(path, r'F:/Lenovo/Documents/fudai-ios-tweak/docs/re-scripts/dump_%s.json' % which)
    x.scan()
    # find all helpers: functions that call _method_setImplementation stub
    msi_stubs = [sa for sa, sym in x.stub_symbol.items() if sym == '_method_setImplementation']
    helper_funcs = set()
    for st in msi_stubs:
        for site in x.sites_calling(st):
            f = x.func_of(site)
            if f:
                helper_funcs.add(f)
    print('hook helper funcs:', [hex(f) for f in sorted(helper_funcs)])
    hooks = []
    for hf in sorted(helper_funcs):
        # determine arg registers: look at first calls in helper: after entry, bl class_getInstanceMethod with x0,x1 -> cls,sel; method_setImplementation(m, x?)-> newImp; store to [x?]
        # default assume same convention as 0x2e8f00 but detect via disasm of helper
        argregs = detect_argregs(x, hf)
        extract_hooks(x, hf, argregs, hooks)
    print('total hook records: %d' % len(hooks))
    with open(r'F:/Lenovo/Documents/fudai-ios-tweak/docs/re-scripts/hooks_%s.json' % which, 'w', encoding='utf-8') as fp:
        json.dump(hooks, fp, ensure_ascii=False, indent=1, default=str)
    return x, hooks


def detect_argregs(x, hf):
    """Disassemble helper, find which registers feed class_getInstanceMethod (x0,x1)
    and method_setImplementation."""
    i = bisect.bisect_right(x.func_starts, hf)
    fend = x.func_starts[i] if i < len(x.func_starts) else hf + 0x400
    code = x.f[hf:fend]
    regmov = {}
    cls_sel = ('x0', 'x1')
    imp = 'x2'
    for ins in x.md.disasm(code, hf):
        m, ops = ins.mnemonic, ins.op_str
        try:
            if m == 'bl':
                tgt = int(ops.lstrip('#'), 0)
                sym = x.stub_symbol.get(tgt, '')
                if sym == '_class_getInstanceMethod':
                    cls_sel = (regmov.get('x0', 'x0'), regmov.get('x1', 'x1'))
                elif sym == '_method_setImplementation':
                    imp = regmov.get('x1', 'x1')
                    break
            elif m == 'mov':
                parts = [p.strip() for p in ops.split(',')]
                if len(parts) == 2:
                    regmov[parts[0]] = parts[1]
        except Exception:
            continue
    return (cls_sel[0], cls_sel[1], imp, 'x3')


if __name__ == '__main__':
    for w in (sys.argv[1:] or ['official']):
        main(w)
