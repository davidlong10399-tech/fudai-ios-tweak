#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Minimal Mach-O / FAT + Objective-C metadata parser for static RE.
Handles: FAT slices, LC_SEGMENT_64, LC_SYMTAB, LC_DYLD_INFO(_ONLY),
LC_DYLD_CHAINED_FIXUPS (pointer formats 1/2/7/8, rebase+bind),
LC_FUNCTION_STARTS, objc class/category/method/ivar lists (pointer & relative).
"""
import struct
from collections import OrderedDict

MH_MAGIC_64 = b'\xCF\xFA\xED\xFE'
FAT_MAGIC = b'\xCA\xFE\xBA\xBE'
FAT_MAGIC_64 = b'\xCA\xFE\xBA\xBF'
CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_ARM64E = 0x0100000D

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_FUNCTION_STARTS = 0x26


class Section(object):
    __slots__ = ('seg', 'name', 'addr', 'size', 'offset', 'flags')

    def __init__(self, seg, name, addr, size, offset, flags):
        self.seg = seg
        self.name = name
        self.addr = addr
        self.size = size
        self.offset = offset
        self.flags = flags

    @property
    def fullname(self):
        return '%s,%s' % (self.seg, self.name)

    def data(self, f):
        return f[self.offset:self.offset + self.size]

    def contains(self, addr):
        return self.addr <= addr < self.addr + self.size


class Slice(object):
    def __init__(self, data, offset=0, name='slice'):
        self.f = data
        self.offset = offset  # file offset of this slice (fat)
        self.name = name
        magic = data[offset:offset + 4]
        if magic != MH_MAGIC_64:
            raise ValueError('not 64-bit macho slice at %d (magic=%r)' % (offset, magic))
        (self.cputype, self.cpusubtype, self.filetype, self.ncmds,
         self.sizeofcmds, self.flags) = struct.unpack_from('<IiIIII', data, offset + 4)
        self.segments = []          # dicts
        self.sections = []          # Section
        self.segments_by_name = OrderedDict()
        self.cmds = []              # (cmd, cmdsize, rawoff)
        self.symtab = None          # (symoff, nsyms, stroff, strsize)
        self.dyld_info = None       # dict
        self.chained = None         # dict with pointer_format per segment
        self.imports = []           # symbol names from chained fixups
        self.bind_map = {}          # vmaddr -> symbol name (got/slp entries)
        self.func_starts = []       # list of vmaddrs
        self._parse_load_commands()

    # ---------- low level ----------
    def vm2off(self, addr):
        for seg in self.segments:
            if seg['vmaddr'] <= addr < seg['vmaddr'] + seg['vmsize']:
                fo = seg['fileoff'] + (addr - seg['vmaddr'])
                if fo < len(self.f):
                    return fo
        return None

    def read(self, addr, n):
        off = self.vm2off(addr)
        if off is None:
            return None
        return self.f[off:off + n]

    def u64(self, addr):
        b = self.read(addr, 8)
        if b is None or len(b) < 8:
            return None
        return struct.unpack('<Q', b)[0]

    def u32(self, addr):
        b = self.read(addr, 4)
        if b is None or len(b) < 4:
            return None
        return struct.unpack('<I', b)[0]

    def i32(self, addr):
        b = self.read(addr, 4)
        if b is None or len(b) < 4:
            return None
        return struct.unpack('<i', b)[0]

    def cstr(self, addr, maxlen=4096):
        b = self.read(addr, maxlen)
        if b is None:
            return None
        i = b.find(b'\x00')
        if i >= 0:
            b = b[:i]
        return b.decode('utf-8', 'replace')

    def section(self, segname, sectname):
        for s in self.sections:
            if s.seg == segname and s.name == sectname:
                return s
        return None

    def sections_in(self, segname):
        return [s for s in self.sections if s.seg == segname]

    def section_of_addr(self, addr):
        for s in self.sections:
            if s.contains(addr):
                return s
        return None

    # ---------- chained fixups ----------
    def _parse_chained_fixups(self, dataoff, datasize):
        f = self.f
        base = self.offset
        rawoff = base + dataoff
        hdr = struct.unpack_from('<IIIIIII', f, rawoff)
        # fixups_version, starts_offset, imports_offset, symbols_offset,
        # imports_count, imports_format, symbols_format
        starts_off = rawoff + hdr[1]
        imports_off = rawoff + hdr[2]
        symbols_off = rawoff + hdr[3]
        imports_count, imports_format, symbols_format = hdr[4], hdr[5], hdr[6]
        self.chained = {'dataoff': dataoff, 'datasize': datasize,
                        'imports_count': imports_count,
                        'imports_format': imports_format}
        def symstr(o):
            end = f.find(b'\x00', symbols_off + o, rawoff + datasize)
            return f[symbols_off + o:end].decode('utf-8', 'replace')
        def import_name(ordinal):
            return self._chained_import_name(ordinal, imports_off, imports_count,
                                             imports_format, symstr)
        self._import_resolver = import_name
        # dyld_chained_starts_in_image
        seg_count = struct.unpack_from('<I', f, starts_off)[0]
        seg_info_offsets = struct.unpack_from('<%dI' % seg_count, f, starts_off + 4)
        for sio in seg_info_offsets:
            if sio == 0:
                continue
            so = starts_off + sio
            # dyld_chained_starts_in_segment:
            # size(u32) page_size(u16) pointer_format(u16) seg_offset(u64)
            # max_valid_pointer(u32) page_count(u8) chain_starts[]
            size, page_size, pointer_format = struct.unpack_from('<IHH', f, so)
            seg_offset, = struct.unpack_from('<Q', f, so + 8)
            maxvalid, = struct.unpack_from('<I', f, so + 16)
            page_count = f[so + 20]
            chain_starts = struct.unpack_from('<%dH' % page_count, f, so + 21)
            self._decode_chain_segment(seg_offset, page_size, chain_starts,
                                       pointer_format,
                                       imports_off, imports_count, imports_format, symstr)

    def _decode_chain_segment(self, seg_offset, page_size, chain_starts,
                              pointer_format, imports_off, imports_count,
                              imports_format, symstr):
        f = self.f
        # pointer_format 1 = DYLD_CHAINED_PTR_ARM64E (observed in these dylibs)
        # entry bits: auth=63, bind=62, next=51..61 (stride 8 bytes)
        #  rebase:     target:43 (bits 0-42) | high8:8 (43-50)
        #  bind:       ordinal:16 (0-15) | zero:16 | addend:19 (32-50)
        #  auth_rebase: target:32 | diversity:16 | addrDiv:1 | key:2
        #  auth_bind:   ordinal:16 | zero:16 | diversity:16 | addrDiv:1 | key:2
        stride = 8
        for i, start in enumerate(chain_starts):
            if start == 0xFFFF:
                continue
            page_vmaddr = seg_offset + i * page_size
            slot = page_vmaddr + start * 4 if pointer_format == 2 else page_vmaddr + start
            guard = 0
            while slot is not None and guard < 500000:
                guard += 1
                raw = self.u64(slot)
                if raw is None:
                    break
                auth = (raw >> 63) & 1
                bind = (raw >> 62) & 1
                nxt = (raw >> 51) & 0x7FF
                target = None
                sym = None
                if not bind and not auth:  # rebase: target:43 | high8:8
                    t = raw & 0x7FFFFFFFFFF
                    high8 = (raw >> 43) & 0xFF
                    target = t | (high8 << 43)
                elif bind and not auth:  # bind: ordinal:16
                    target = raw & 0xFFFF
                    sym = self._chained_import_name(target, imports_off,
                                                    imports_count, imports_format, symstr)
                    if sym:
                        self.bind_map[slot] = sym
                elif auth and not bind:  # auth_rebase: target:32
                    target = raw & 0xFFFFFFFF
                else:  # auth_bind: ordinal:16
                    target = raw & 0xFFFF
                    sym = self._chained_import_name(target, imports_off,
                                                    imports_count, imports_format, symstr)
                    if sym:
                        self.bind_map[slot] = sym
                self._record_fixed_ptr(slot, target, bind == 1, sym, fmt=pointer_format)
                if nxt == 0:
                    slot = None
                else:
                    slot = slot + nxt * stride

    def _record_fixed_ptr(self, slot, target, is_bind, sym, fmt):
        self.fixups[slot] = (target, is_bind, sym, fmt)

    def _chained_import_name(self, ordinal, imports_off, imports_count, fmt, symstr):
        if ordinal >= imports_count:
            return None
        if fmt == 1:  # DYLD_CHAINED_IMPORT: lib_ordinal:8 | weak:1 | name_offset:23
            v = struct.unpack_from('<I', self.f, imports_off + ordinal * 4)[0]
            return symstr((v >> 9) & 0x7FFFFF)
        elif fmt == 2:  # DYLD_CHAINED_IMPORT_ADDEND
            v, _add = struct.unpack_from('<Ii', self.f, imports_off + ordinal * 8)
            return symstr((v >> 9) & 0x7FFFFF)
        elif fmt == 3:  # DYLD_CHAINED_IMPORT_ADDEND64
            v = struct.unpack_from('<Iiq', self.f, imports_off + ordinal * 16)
            return symstr(v[1])
        return None

    # ---------- load commands ----------
    def _parse_load_commands(self):
        f = self.f
        base = self.offset
        self.fixups = {}  # slot vmaddr -> (target, is_bind, symbol, fmt)
        off = base + 32
        end = off + self.sizeofcmds
        while off + 8 <= end:
            cmd, cmdsize = struct.unpack_from('<II', f, off)
            self.cmds.append((cmd, cmdsize, off))
            if cmd == LC_SEGMENT_64:
                segname = f[off + 8:off + 24].rstrip(b'\x00').decode('ascii', 'replace')
                vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, sflags = \
                    struct.unpack_from('<QQQQIIII', f, off + 24)
                seg = {'name': segname, 'vmaddr': vmaddr, 'vmsize': vmsize,
                       'fileoff': fileoff, 'filesize': filesize, 'initprot': initprot}
                self.segments.append(seg)
                self.segments_by_name.setdefault(segname, seg)
                so = off + 72
                for i in range(nsects):
                    sectname = f[so:so + 16].rstrip(b'\x00').decode('ascii', 'replace')
                    seg2 = f[so + 16:so + 32].rstrip(b'\x00').decode('ascii', 'replace')
                    addr, size = struct.unpack_from('<QQ', f, so + 32)
                    offset = struct.unpack_from('<I', f, so + 48)[0]
                    flags = struct.unpack_from('<I', f, so + 72)[0]
                    self.sections.append(Section(seg2, sectname, addr, size, offset, flags))
                    so += 80
            elif cmd == LC_SYMTAB:
                symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', f, off + 8)
                self.symtab = (symoff, nsyms, stroff, strsize)
            elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                fields = struct.unpack_from('<10I', f, off + 8)
                self.dyld_info = {
                    'rebase_off': fields[0], 'rebase_size': fields[1],
                    'bind_off': fields[2], 'bind_size': fields[3],
                    'weak_bind_off': fields[4], 'weak_bind_size': fields[5],
                    'lazy_bind_off': fields[6], 'lazy_bind_size': fields[7],
                    'export_off': fields[8], 'export_size': fields[9],
                }
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                dataoff, datasize = struct.unpack_from('<II', f, off + 8)
                self._parse_chained_fixups(dataoff, datasize)
            elif cmd == LC_FUNCTION_STARTS:
                data_off, size = struct.unpack_from('<II', f, off + 8)
                self._parse_function_starts(base + data_off, size)
            off += cmdsize

        # classic dyld_info binds -> bind_map
        if self.dyld_info:
            self._parse_dyld_binds()

    def _parse_function_starts(self, off, size):
        f = self.f
        i = 0
        addr = 0
        end = min(size, 4096 * 1024)
        data = f[off:off + size]
        while i < len(data):
            delta = 0
            shift = 0
            while True:
                if i >= len(data):
                    return
                b = data[i]
                i += 1
                delta |= (b & 0x7F) << shift
                shift += 7
                if not (b & 0x80):
                    break
            if delta == 0:
                break
            addr += delta
            self.func_starts.append(addr)

    # classic dyld_info bind opcode parser (for __got / __nl_symbol_ptr)
    def _parse_dyld_binds(self):
        di = self.dyld_info
        f = self.f
        results = []
        for key in ('bind', 'weak_bind', 'lazy_bind'):
            o, size = di.get(key + '_off'), di.get(key + '_size')
            if not o or not size:
                continue
            seg_index = 0
            seg_addr = 0
            seg_off = 0
            ordinal = 0
            addend = 0
            i = 0
            data = f[o:o + size]
            done = False
            while i < len(data) and not done:
                b = data[i]
                i += 1
                imm = b & 0x0F
                opc = b & 0xF0
                if opc == 0x00:  # DONE
                    done = True
                elif opc == 0x10:  # PUSH
                    i += imm
                elif opc == 0x20:  # SET segment
                    seg_index = imm
                    seg = self.segments[seg_index] if seg_index < len(self.segments) else None
                    seg_addr = seg['vmaddr'] if seg else 0
                    seg_off = seg['fileoff'] if seg else 0
                elif opc == 0x30:  # SET section type (ignore)
                    pass
                elif opc == 0x40:  # SET address
                    v = 0
                    shift = 0
                    while True:
                        b2 = data[i]
                        i += 1
                        v |= (b2 & 0x7F) << shift
                        shift += 7
                        if not (b2 & 0x80):
                            break
                    seg_addr = v
                elif opc == 0x50:  # SET symbol ordinal
                    ordinal = imm
                elif opc == 0x60:  # SET symbol ordinal uleb
                    v = 0
                    shift = 0
                    while True:
                        b2 = data[i]
                        i += 1
                        v |= (b2 & 0x7F) << shift
                        shift += 7
                        if not (b2 & 0x80):
                            break
                    ordinal = v
                elif opc == 0x70:  # SET type
                    pass
                elif opc == 0x80:  # SET addend sleb
                    v = 0
                    shift = 0
                    while True:
                        b2 = data[i]
                        i += 1
                        v |= (b2 & 0x7F) << shift
                        shift += 7
                        if not (b2 & 0x80):
                            break
                    if v & (1 << (shift - 1)):
                        v -= (1 << shift)
                    addend = v
                elif opc == 0x90:  # SET offset in segment
                    v = 0
                    shift = 0
                    while True:
                        b2 = data[i]
                        i += 1
                        v |= (b2 & 0x7F) << shift
                        shift += 7
                        if not (b2 & 0x80):
                            break
                    seg_off = v
                elif opc == 0xA0:  # ADD bind offset
                    seg_addr += imm
                elif opc == 0xB0:  # DO bind
                    slot_vm = seg_addr + seg_off
                    sym = self._symbol_for_ordinal(ordinal)
                    if sym:
                        self.bind_map[slot_vm] = sym
                    seg_off += 8
                elif opc == 0xC0:  # DO bind add size
                    seg_addr += imm * 8
                elif opc == 0xD0:  # DO bind add
                    seg_addr += imm
                elif opc == 0xE0:  # DO bind then add size
                    slot_vm = seg_addr + seg_off
                    sym = self._symbol_for_ordinal(ordinal)
                    if sym:
                        self.bind_map[slot_vm] = sym
                    seg_addr += imm * 8
                else:
                    pass

    def _symbol_for_ordinal(self, ordinal):
        # undefined symbols from symtab, ordered by n_desc reference index
        if not self.symtab:
            return None
        symoff, nsyms, stroff, strsize = self.symtab
        undefined = []
        for i in range(nsyms):
            e = struct.unpack_from('<IBBHQ', self.f, self.offset + symoff + i * 16)
            n_strx, n_type, n_sect, n_desc, n_value = e
            if (n_type & 0x0E) == 0 and n_type & 0x01:  # N_UNDF + N_EXT
                undefined.append((n_desc >> 8, n_strx))
        undefined.sort()
        for idx, (lib, n_strx) in enumerate(undefined):
            if idx == ordinal - 1:
                end = self.f.find(b'\x00', self.offset + stroff + n_strx)
                return self.f[self.offset + stroff + n_strx:end].decode('utf-8', 'replace')
        return None

    # ---------- pointer resolution ----------
    def max_vmaddr(self):
        m = 0
        for seg in self.segments:
            m = max(m, seg['vmaddr'] + seg['vmsize'])
        return m

    def _decode_arm64e_entry(self, raw):
        """Decode a raw 64-bit value as DYLD_CHAINED_PTR_ARM64E entry.
        Returns (target_or_None, symbol_or_None)."""
        if raw is None:
            return (None, None)
        if raw < self.max_vmaddr():
            return (raw, None)  # already a plain vmaddr
        auth = (raw >> 63) & 1
        bind = (raw >> 62) & 1
        if not bind and not auth:  # rebase
            t = raw & 0x7FFFFFFFFFF
            high8 = (raw >> 43) & 0xFF
            return (t | (high8 << 43), None)
        elif bind and not auth:  # bind
            return (None, self._import_name_by_ordinal(raw & 0xFFFF))
        elif auth and not bind:  # auth rebase
            return (raw & 0xFFFFFFFF, None)
        else:  # auth bind
            return (None, self._import_name_by_ordinal(raw & 0xFFFF))

    def _import_name_by_ordinal(self, ordinal):
        # only valid when chained fixups parsed; store resolver closure
        resolver = getattr(self, '_import_resolver', None)
        return resolver(ordinal) if resolver else None

    def ptr(self, addr):
        """Resolve pointer value at vmaddr, transparently handling chained fixups.
        Returns (target_vmaddr, bind_symbol_name_or_None) or (None, None)."""
        if addr in self.fixups:
            target, is_bind, sym, fmt = self.fixups[addr]
            if is_bind:
                return (None, sym)
            return (target, sym)
        raw = self.u64(addr)
        if raw is None:
            return (None, None)
        if self.chained:
            return self._decode_arm64e_entry(raw)
        return (raw, None)

    def cstr_at(self, addr):
        if addr is None:
            return None
        return self.cstr(addr)


class Fat(object):
    def __init__(self, path):
        with open(path, 'rb') as fp:
            self.data = fp.read()
        self.path = path
        self.slices = []
        if self.data[:4] in (FAT_MAGIC, FAT_MAGIC_64):
            n = struct.unpack_from('>I', self.data, 4)[0]
            for i in range(n):
                if self.data[:4] == FAT_MAGIC:
                    cputype, cpusub, off, size, align = struct.unpack_from('>IIIII', self.data, 8 + i * 20)
                else:
                    cputype, cpusub, off, size, align = struct.unpack_from('>QQQQQ', self.data, 8 + i * 32)
                try:
                    sl = Slice(self.data, off, name='arch%d_cputype_0x%x' % (i, cputype))
                except ValueError:
                    sl = None
                self.slices.append((cputype, cpusub, off, size, sl))
        else:
            sl = Slice(self.data, 0, name='thin')
            self.slices.append((sl.cputype, sl.cpusubtype, 0, len(self.data), sl))

    def arm64(self):
        for cputype, cpusub, off, size, sl in self.slices:
            if cputype == CPU_TYPE_ARM64 and sl is not None:
                return sl
        for cputype, cpusub, off, size, sl in self.slices:
            if sl is not None:
                return sl
        return None


# ---------------- Objective-C metadata ----------------

class ObjCParser(object):
    def __init__(self, sl):
        self.sl = sl
        self.class_by_addr = {}
        self.classes = []
        self.categories = []
        self.sel_by_addr = {}

    def _method_list(self, addr, is_meta=False):
        """Returns list of dicts {name, types, imp} or None."""
        sl = self.sl
        if not addr:
            return None
        entsize = sl.u32(addr)
        count = sl.u32(addr + 4)
        if entsize is None or count is None or count > 200000:
            return None
        out = []
        base = addr + 8
        if (entsize & 0x40000000) or (entsize & 0x80000000) or (entsize & 0xFFFF) == 12:
            # relative (small) method list; small flag may be 0x40000000 or 0x80000000
            for i in range(count):
                e = base + i * 12
                name_off = sl.i32(e)
                types_off = sl.i32(e + 4)
                imp_off = sl.i32(e + 8)
                if name_off is None:
                    continue
                name_addr = e + name_off
                # name may be a direct C-string (in __objc_methname) or an
                # indirect pointer into __objc_selrefs (pointer-kind entries)
                name = None
                if name_addr:
                    sec = sl.section_of_addr(name_addr)
                    if sec is not None and sec.name == '__objc_selrefs':
                        name_ptr, _ = sl.ptr(name_addr)
                        name = sl.cstr(name_ptr) if name_ptr else None
                    else:
                        name = sl.cstr(name_addr)
                types = None
                if types_off is not None:
                    types_ptr, _ = sl.ptr(e + 4 + types_off)
                    types = sl.cstr(types_ptr) if types_ptr else None
                imp = (e + 8 + imp_off) if imp_off is not None else 0
                out.append({'name': name, 'types': types, 'imp': imp,
                            'name_addr': name_addr, 'kind': 'rel'})
        elif entsize == 24:
            for i in range(count):
                e = base + i * 24
                name_ptr, types_ptr, imp = sl.ptr(e)
                name = sl.cstr(name_ptr) if name_ptr else None
                types = sl.cstr(types_ptr) if types_ptr else None
                out.append({'name': name, 'types': types, 'imp': imp,
                            'name_addr': name_ptr, 'kind': 'ptr'})
        else:
            return None
        return out

    def _class_ro(self, bits_ptr):
        sl = self.sl
        ro = bits_ptr
        if ro is None or not ro:
            return None
        flags, instanceStart, instanceSize, reserved = struct.unpack(
            '<IIII', sl.read(ro, 16) or b'\x00' * 16)
        ivarLayout, = struct.unpack('<Q', sl.read(ro + 16, 8) or b'\x00' * 8)
        name_ptr, _ = sl.ptr(ro + 24)
        ml_ptr, _ = sl.ptr(ro + 32)
        proto_ptr, _ = sl.ptr(ro + 40)
        ivars_ptr, _ = sl.ptr(ro + 48)
        name = sl.cstr(name_ptr) if name_ptr else None
        methods = self._method_list(ml_ptr)
        ivars = []
        if ivars_ptr:
            iesize = sl.u32(ivars_ptr)
            icount = sl.u32(ivars_ptr + 4)
            if iesize == 32 and icount and icount < 4096:
                for i in range(icount):
                    e = ivars_ptr + 8 + i * 32
                    off_ptr, = struct.unpack('<I', sl.read(e, 4) or b'\x00' * 4)
                    name_ptr2, _ = sl.ptr(e + 8)
                    type_ptr, _ = sl.ptr(e + 16)
                    _align, size = struct.unpack('<II', sl.read(e + 24, 8) or b'\x00' * 8)
                    ivars.append({
                        'name': sl.cstr(name_ptr2) if name_ptr2 else None,
                        'type': sl.cstr(type_ptr) if type_ptr else None,
                        'size': size})
        return {'name': name, 'flags': flags, 'methods': methods, 'ivars': ivars,
                'ro_addr': ro, 'instanceSize': instanceSize}

    def _parse_class(self, addr):
        sl = self.sl
        isa, _ = sl.ptr(addr)
        superclass, _ = sl.ptr(addr + 8)
        bits, _ = sl.ptr(addr + 32)
        if bits is None:
            return None
        if bits & 1:
            # rw: bits points to class_rw_t
            rw = bits - 1
            ro_ptr, _ = sl.ptr(rw + 8)
            try:
                if ro_ptr & 1:
                    ro = self._class_ro(sl.u64(ro_ptr - 1))
                else:
                    ro = self._class_ro(ro_ptr)
            except Exception:
                ro = None
        else:
            ro = self._class_ro(bits)
        meta_ro = None
        if isa:
            meta_bits, _ = sl.ptr(isa + 32)
            if meta_bits:
                try:
                    if meta_bits & 1:
                        ro_ptr2, _ = sl.ptr(meta_bits + 8)
                        meta_ro = self._class_ro(ro_ptr2)
                    else:
                        meta_ro = self._class_ro(meta_bits)
                except Exception:
                    meta_ro = None
        return {'addr': addr, 'isa': isa, 'super': superclass, 'ro': ro, 'meta_ro': meta_ro}

    def parse(self):
        sl = self.sl
        # classlist
        for sectname in ('__objc_classlist', '__objc_nlclslist'):
            sec = sl.section('__DATA_CONST', sectname) or sl.section('__DATA', sectname) or \
                sl.section('__DATA_DIRTY', sectname)
            if not sec:
                continue
            for i in range(sec.size // 8):
                a = sec.addr + i * 8
                cls_addr, _ = sl.ptr(a)
                if cls_addr and cls_addr not in self.class_by_addr:
                    c = self._parse_class(cls_addr)
                    if c:
                        self.class_by_addr[cls_addr] = c
        # order: non-lazy first set union
        seen = set()
        for sectname in ('__objc_nlclslist', '__objc_classlist'):
            sec = sl.section('__DATA_CONST', sectname) or sl.section('__DATA', sectname) or \
                sl.section('__DATA_DIRTY', sectname)
            if not sec:
                continue
            for i in range(sec.size // 8):
                a = sec.addr + i * 8
                cls_addr, _ = sl.ptr(a)
                if cls_addr and cls_addr not in seen:
                    seen.add(cls_addr)
                    c = self.class_by_addr.get(cls_addr)
                    if c:
                        self.classes.append(c)
        # categories
        for sectname in ('__objc_nlcatlist', '__objc_catlist'):
            sec = sl.section('__DATA_CONST', sectname) or sl.section('__DATA', sectname) or \
                sl.section('__DATA_DIRTY', sectname)
            if not sec:
                continue
            for i in range(sec.size // 8):
                a = sec.addr + i * 8
                cat_addr, _ = sl.ptr(a)
                if not cat_addr:
                    continue
                name_ptr, cls_ptr, iml_ptr, cml_ptr, protos = struct.unpack(
                    '<QQQQQ', sl.read(cat_addr, 40) or b'\x00' * 40)
                # resolve via fixups
                name_ptr2, _ = sl.ptr(cat_addr)
                cls_ptr2, _ = sl.ptr(cat_addr + 8)
                iml_ptr2, _ = sl.ptr(cat_addr + 16)
                cml_ptr2, _ = sl.ptr(cat_addr + 24)
                cat_name = sl.cstr(name_ptr2) if name_ptr2 else None
                cls = self.class_by_addr.get(cls_ptr2)
                cls_name = None
                if cls and cls.get('ro'):
                    cls_name = cls['ro']['name']
                else:
                    # try parse class ro directly
                    bits = sl.u64(cls_ptr2 + 32) if cls_ptr2 else None
                    if bits and not (bits & 1):
                        ro = self._class_ro(bits)
                        cls_name = ro['name'] if ro else None
                im = self._method_list(iml_ptr2) if iml_ptr2 else None
                cm = self._method_list(cml_ptr2) if cml_ptr2 else None
                self.categories.append({'addr': cat_addr, 'name': cat_name,
                                        'cls_name': cls_name, 'cls_addr': cls_ptr2,
                                        'imethods': im or [], 'cmethods': cm or []})
        # selrefs
        for s in sl.sections:
            if s.name == '__objc_selrefs' or s.name == '__objc_methref':
                for i in range(s.size // 8):
                    a = s.addr + i * 8
                    v, _ = sl.ptr(a)
                    if v:
                        self.sel_by_addr[a] = sl.cstr(v)

    def class_name_of(self, classref_addr):
        """classref slot -> class object addr -> name"""
        sl = self.sl
        target, _ = sl.ptr(classref_addr)
        if target is None:
            return None
        c = self.class_by_addr.get(target)
        if c and c.get('ro'):
            return c['ro']['name']
        bits = sl.u64(target + 32) if target else None
        if bits and not (bits & 1):
            ro = self._class_ro(bits)
            return ro['name'] if ro else None
        return None

    def all_imps(self):
        """yield (imp_addr, class_name, method_name, is_meta)"""
        for c in self.classes:
            ro = c.get('ro')
            mro = c.get('meta_ro')
            nm = ro['name'] if ro else '?'
            if ro and ro['methods']:
                for m in ro['methods']:
                    yield (m['imp'], nm, m['name'], False, m['types'])
            if mro and mro['methods']:
                for m in mro['methods']:
                    yield (m['imp'], nm, m['name'], True, m['types'])
        for cat in self.categories:
            for m in cat['imethods']:
                yield (m['imp'], cat['cls_name'], m['name'], False, m['types'])
            for m in cat['cmethods']:
                yield (m['imp'], cat['cls_name'], m['name'], True, m['types'])
