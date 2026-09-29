#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Annotate and disassemble a function with resolved references."""
import sys, os, io, json, bisect
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xref import Xref, OFFICIAL, EMBEDDED
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
import struct, re

BR = re.compile(r'\[(\w+)(?:,\s*#(-?0x[0-9a-fA-F]+|-?\d+))?\]')


def explain(x, fstart, maxins=4000, show=True):
    i = bisect.bisect_right(x.func_starts, fstart)
    fend = x.func_starts[i] if i < len(x.func_starts) else fstart + 0x80000
    md = x.md
    lines = []
    pc = fstart
    code = x.f[pc:fend]
    for ins in md.disasm(code, pc):
        if ins.address >= fend or (maxins and ins.address - fstart > maxins * 4):
            break
        m, ops = ins.mnemonic, ins.op_str
        ann = []
        # adrp/add/ldr resolution
        if m == 'adrp':
            reg, page = ops.split(', ')
            x._cur_page = getattr(x, '_cur_page', {})
            x._cur_page[reg] = int(page.lstrip('#'), 16)
        elif m == 'add':
            parts = [p.strip() for p in ops.split(',')]
            if len(parts) == 3 and parts[1] in getattr(x, '_cur_page', {}):
                try:
                    imm = int(parts[2].lstrip('#'), 0)
                    tgt = x._cur_page[parts[1]] + imm
                    x._cur_page[parts[0]] = tgt
                    lbl = x.target_label(tgt)
                    if lbl:
                        ann.append('%s = %s' % (tgt and hex(tgt), lbl))
                except Exception:
                    pass
        elif m.startswith('ldr') or m.startswith('ldur'):
            mm = BR.search(ops)
            if mm and mm.group(1) in getattr(x, '_cur_page', {}):
                imm = int(mm.group(2), 0) if mm.group(2) else 0
                tgt = x._cur_page[mm.group(1)] + imm
                lbl = x.target_label(tgt)
                if lbl:
                    ann.append('%s -> %s' % (hex(tgt), lbl))
        elif m == 'bl':
            try:
                tgt = int(ops.lstrip('#'), 0)
                lbl = x.target_label(tgt)
                if lbl:
                    ann.append('=> %s' % lbl)
                else:
                    ann.append('=> sub_0x%x' % tgt)
            except Exception:
                pass
        elif m.startswith('ret') or m == 'brk':
            x._cur_page = {}
        if ann:
            lines.append('  0x%x: %-8s %-46s ; %s' % (ins.address, m, ops, ' ; '.join(ann)))
        else:
            lines.append('  0x%x: %-8s %s' % (ins.address, m, ops))
    if show:
        print('==== FUNC 0x%x  %s (end 0x%x)' % (fstart, x.fn_label(fstart), fend))
        print('\n'.join(lines[:maxins]))
        if len(lines) > maxins:
            print('  ... (%d more)' % (len(lines) - maxins))
    return lines


if __name__ == '__main__':
    which = sys.argv[1] if len(sys.argv) > 1 else 'official'
    addrs = [int(a, 16) for a in sys.argv[2:]]
    path = OFFICIAL if which == 'official' else EMBEDDED
    x = Xref(path, r'F:/Lenovo/Documents/fudai-ios-tweak/docs/re-scripts/dump_%s.json' % which)
    for a in addrs:
        explain(x, a)
        print()
