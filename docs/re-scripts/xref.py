#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Capstone-based xref engine: scans functions, tracks adrp/add/ldr pairs,
objc_stubs (sel) mapping, auth_stubs (import) mapping, bl calls."""
import sys, os, json, struct, bisect, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sjj_macho import Fat, ObjCParser
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

OFFICIAL = r'F:/Lenovo/Documents/fudai-ios-tweak/analysis/payload/var/jb/Library/MobileSubstrate/DynamicLibraries/siwenjiajia.dylib'
EMBEDDED = r'F:/Lenovo/Documents/fudai-ios-tweak/dist/sjj_embedded.dylib'

TEXT_RANGES = {OFFICIAL: [(0x4000, 0x6423bc)], EMBEDDED: [(0x4000, 0x613f74)]}
STUB_RANGES = {  # (auth_stubs_start, auth_stubs_end, objc_stubs_start, objc_stubs_end)
    OFFICIAL: (0x6463bc, 0x6463bc + 0x16a0, 0x647a60, 0x647a60 + 0x1fc00),
    EMBEDDED: (0x617f74, 0x617f74 + 0x15f0, 0x619580, 0x619580 + 0x1e520),
}


class Xref(object):
    def __init__(self, path, dump_json):
        self.fat = Fat(path)
        self.sl = self.fat.arm64()
        self.f = self.sl.f
        self.dump = json.load(open(dump_json, encoding='utf-8'))
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        self.md.detail = False
        self._build_selref()
        self._build_classref()
        self._build_stubs()
        self._imp_of = {}
        for c in self.dump['classes']:
            nm = c['name']
            for m in c['methods']:
                self._imp_of[m['imp']] = (nm, m['name'], False)
            for m in c['class_methods']:
                self._imp_of[m['imp']] = (nm, m['name'], True)
        self._build_functions()

    # ---------- metadata ----------
    def _build_selref(self):
        self.sel_by_addr = {int(k, 16): v for k, v in self.dump['selrefs'].items()}
        # also map string -> selref addr list
        self.selref_addrs = {}
        for a, v in self.sel_by_addr.items():
            self.selref_addrs.setdefault(v, []).append(a)

    def _build_classref(self):
        self.classref_by_addr = {}
        for k, v in self.dump['classrefs'].items():
            self.classref_by_addr[int(k, 16)] = v.get('name') or v.get('bind')
        # superrefs too (they point to classes)
        for k, v in self.dump.get('superrefs', {}).items():
            if v:
                self.classref_by_addr[int(k, 16)] = v + ' (super)'

    def _got_symbol(self, got_addr):
        # bind_map from fixups: slot -> symbol
        return self.sl.bind_map.get(got_addr)

    def _build_stubs(self):
        """auth_stubs: 12-byte entries -> got addr -> import symbol.
        objc_stubs: 32-byte entries: adrp x1,page; ldr x1,[x1,off] -> selref; got -> objc_msgSend"""
        self.stub_symbol = {}    # stub addr -> import symbol
        self.objc_stub_sel = {}  # stub addr -> selector name
        sr = STUB_RANGES.get(self.fat.path)
        if not sr:
            return
        a_start, a_end, o_start, o_end = sr
        addr = a_start
        while addr + 16 <= a_end:
            code = self.f[addr:addr + 16]
            ins = list(self.md.disasm(code, addr))
            if len(ins) >= 2 and ins[0].mnemonic == 'adrp' and ins[1].mnemonic == 'add':
                page = int(ins[0].op_str.split(', ')[-1].lstrip('#'), 16)
                try:
                    off = int(ins[1].op_str.split(', ')[-1].lstrip('#'), 0)
                except Exception:
                    off = 0
                got = page + off
                sym = self._got_symbol(got)
                if sym:
                    self.stub_symbol[addr] = sym
            addr += 16
        addr = o_start
        while addr + 32 <= o_end:
            code = self.f[addr:addr + 32]
            ins = list(self.md.disasm(code, addr))
            if len(ins) >= 2 and ins[0].mnemonic == 'adrp' and ins[1].mnemonic.startswith('ldr'):
                try:
                    page = int(ins[0].op_str.split(', ')[-1].lstrip('#'), 16)
                    off_s = ins[1].op_str.split(', ')[-1].lstrip('#').rstrip(']')
                    off = int(off_s, 0)
                    selref = page + off
                    sel = self.sel_by_addr.get(selref)
                    if sel:
                        self.objc_stub_sel[addr] = sel
                except Exception:
                    pass
            addr += 32

    def _build_functions(self):
        starts = set(self.sl.func_starts)
        for imp in self._imp_of:
            starts.add(imp)
        self.func_starts = sorted(starts)
        self._fs_array = self.func_starts

    def func_of(self, addr):
        i = bisect.bisect_right(self._fs_array, addr) - 1
        if i < 0:
            return None
        return self._fs_array[i]

    def imp_name(self, addr):
        return self._imp_of.get(addr)

    # ---------- scanning ----------
    def scan(self, text_ranges=None):
        self.refs = {}    # site -> list of (kind, target)
        self.calls = {}   # site -> target
        t0 = time.time()
        ranges = text_ranges or TEXT_RANGES[self.fat.path]
        total_ins = 0
        for start, size in ranges:
            end = start + size
            code = self.f[start:end]
            # disassemble in one pass with restart-on-error; track adrp pages
            adrp_page = {}
            pc = start
            while pc < end:
                last = None
                for ins in self.md.disasm(code[pc - start:], pc):
                    total_ins += 1
                    m, ops = ins.mnemonic, ins.op_str
                    if m == 'adrp':
                        reg, page = ops.split(', ')
                        adrp_page[reg] = int(page.lstrip('#'), 16)
                    elif m == 'add':
                        parts = [p.strip() for p in ops.split(',')]
                        if len(parts) == 3 and parts[1] in adrp_page:
                            try:
                                imm = int(parts[2].lstrip('#'), 0)
                            except Exception:
                                pass
                            else:
                                tgt = adrp_page[parts[1]] + imm
                                adrp_page[parts[0]] = tgt
                                self.refs.setdefault(ins.address, []).append(('adrp_add', tgt))
                    elif m.startswith('ldr') or m.startswith('ldrb') or m.startswith('ldur'):
                        import re as _re
                        mm = _re.search(r'\[(\w+)(?:,\s*#(-?0x[0-9a-fA-F]+|-?\d+))?\]', ops)
                        if mm:
                            base = mm.group(1)
                            if base in adrp_page:
                                imm_s = mm.group(2)
                                try:
                                    imm = int(imm_s, 0) if imm_s else 0
                                except Exception:
                                    pass
                                else:
                                    tgt = adrp_page[base] + imm
                                    self.refs.setdefault(ins.address, []).append(('ldr', tgt))
                    elif m in ('bl', 'b'):
                        try:
                            tgt = int(ops.lstrip('#'), 0)
                        except Exception:
                            pass
                        else:
                            self.calls[ins.address] = tgt
                    last = ins
                if last is not None:
                    pc = last.address + last.size
                else:
                    pc += 4
                    adrp_page = {}
        print('scan: %d insns in %.1fs; %d ref sites, %d calls'
              % (total_ins, time.time() - t0, len(self.refs), len(self.calls)))
        # build site -> sel / symbol resolution helpers
        self._bl_sel = {}
        for site, tgt in self.calls.items():
            sel = self.objc_stub_sel.get(tgt)
            if sel:
                self._bl_sel[site] = sel

    def target_label(self, tgt):
        sel = self.sel_by_addr.get(tgt)
        if sel is not None:
            return 'sel:%s' % sel
        cls = self.classref_by_addr.get(tgt)
        if cls:
            return 'cls:%s' % cls
        sym = self.stub_symbol.get(tgt)
        if sym:
            return 'stub:%s' % sym
        sel2 = self.objc_stub_sel.get(tgt)
        if sel2:
            return 'msgsend_stub:%s' % sel2
        # function start?
        imp = self._imp_of.get(tgt)
        if imp:
            return 'func:%s(%s)' % (imp[0], imp[1])
        if tgt in self.func_starts:
            return 'sub_0x%x' % tgt
        # data string?
        s = self.sl.cstr(tgt, 80)
        if s and all(32 <= ord(c) < 127 or ord(c) > 0x2e80 for c in s[:40]) and len(s) > 0:
            return 'str:"%s"' % s[:60]
        return None

    def sites_referencing(self, target):
        out = []
        for site, lst in self.refs.items():
            for kind, t in lst:
                if t == target:
                    out.append((site, kind))
        return out

    def sites_calling(self, target):
        return [site for site, t in self.calls.items() if t == target]

    def calls_in_func(self, fstart, limit=100000):
        """All call sites within function starting at fstart (until next func start)."""
        i = bisect.bisect_right(self._fs_array, fstart)
        end = self._fs_array[i] if i < len(self._fs_array) else fstart + 0x100000
        out = []
        for site, tgt in self.calls.items():
            if fstart <= site < end:
                out.append((site, tgt))
        return sorted(out)

    def refs_in_func(self, fstart):
        i = bisect.bisect_right(self._fs_array, fstart)
        end = self._fs_array[i] if i < len(self._fs_array) else fstart + 0x100000
        out = []
        for site, lst in self.refs.items():
            if fstart <= site < end:
                for kind, t in lst:
                    out.append((site, kind, t))
        return sorted(out)

    def fn_label(self, fstart):
        imp = self._imp_of.get(fstart)
        if imp:
            return '%s %s%s' % (imp[0], '+' if imp[2] else '-', imp[1])
        return 'sub_0x%x' % fstart


if __name__ == '__main__':
    x = Xref(OFFICIAL, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dump_official.json'))
    print('stubs: %d auth, %d objc-stubs' % (len(x.stub_symbol), len(x.objc_stub_sel)))
    ms = [s for s in set(x.stub_symbol.values()) if 'method_' in s or 'class_' in s or 'objc_getClass' in s]
    print('runtime stubs sample:', ms[:20])
    x.scan()
