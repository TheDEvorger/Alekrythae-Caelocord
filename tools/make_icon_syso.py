#!/usr/bin/env python3
"""Make a standalone .rsrc COFF object for a Windows amd64 Go EXE.

Uses only Python stdlib and an ICO file. Run before `go build`:
  python Source-Code/tools/make_icon_syso.py Source-Code/launcher/Cælōcord.ico Source-Code/launcher/icon_windows_amd64.syso

The output contains RT_ICON and RT_GROUP_ICON resources (not a launcher shortcut).
"""
import struct
import sys
from pathlib import Path


def get_icons(path):
    data = Path(path).read_bytes()
    reserved, kind, count = struct.unpack_from('<HHH', data)
    if (reserved, kind) != (0, 1) or count < 1:
        raise ValueError('Expected Windows ICO file')
    icons = []
    for i in range(count):
        w, h, colors, res, planes, bpp, size, start = struct.unpack_from('<BBBBHHII', data, 6 + 16*i)
        img = data[start:start+size]
        if len(img) != size:
            raise ValueError('ICO data is truncated')
        icons.append((w,h,colors,res,planes,bpp,img))
    return icons


def build_resources(icons):
    group = struct.pack('<HHH', 0, 1, len(icons))
    for i,(w,h,colors,res,planes,bpp,img) in enumerate(icons,1):
        group += struct.pack('<BBBBHHIH',w,h,colors,res,planes,bpp,len(img),i)
    tree = {3:{i:{1033:image[-1]} for i,image in enumerate(icons,1)},14:{1:{1033:group}}}
    buf = bytearray()
    leafs = []
    reloc_offsets = []
    def alloc(n):
        start = len(buf)
        buf.extend(b'\0'*n)
        return start
    def directory(node):
        off = alloc(16 + 8*len(node))
        struct.pack_into('<IIHHHH', buf, off, 0, 0, 0, 0, 0, len(node))
        for i,(item_id,content) in enumerate(sorted(node.items())):
            entry = off+16+i*8
            if isinstance(content,dict):
                childoff = directory(content)
                struct.pack_into('<II',buf,entry,item_id,childoff|0x80000000)
            else:
                dataent = alloc(16)
                struct.pack_into('<II',buf,entry,item_id,dataent)
                leafs.append((dataent,content))
        return off
    directory(tree)
    for dataent,content in leafs:
        while len(buf)%4: alloc(1)
        datastart=alloc(len(content))
        buf[datastart:datastart+len(content)]=content
        struct.pack_into('<IIII',buf,dataent,datastart,len(content),0,0)
        reloc_offsets.append(dataent)
    return bytes(buf), reloc_offsets


def coff_object(resource, reloc_offsets):
    # AMD64 COFF containing one section (.rsrc), two symbols (section + aux).
    file_hdr_len=20
    section_hdr_len=40
    raw_off=file_hdr_len+section_hdr_len
    reloc_off=raw_off+len(resource)
    symtab_off=reloc_off+10*len(reloc_offsets)
    hdr=struct.pack('<HHIIIHH',0x8664,1,0,symtab_off,2,0,0)
    sec=struct.pack('<8sIIIIIIHHI', b'.rsrc\0\0\0',0,0,len(resource),raw_off,reloc_off,0,len(reloc_offsets),0,0x40300040)
    reloc=b''.join(struct.pack('<IIH',r,0,0x0003) for r in reloc_offsets) # IMAGE_REL_AMD64_ADDR32NB
    symbol=struct.pack('<8sIhHBB',b'.rsrc\0\0\0',0,1,0,3,1)
    aux=struct.pack('<IHHIhBBH',len(resource),len(reloc_offsets),0,0,0,0,0,0)
    return hdr+sec+resource+reloc+symbol+aux+struct.pack('<I',4)


def main():
    if len(sys.argv)!=3:
        print('Usage: make_icon_syso.py input.ico output.syso',file=sys.stderr)
        sys.exit(2)
    icons=get_icons(sys.argv[1])
    resource, relocs=build_resources(icons)
    Path(sys.argv[2]).write_bytes(coff_object(resource,relocs))
    print(f'Wrote {sys.argv[2]} ({len(icons)} icons, {len(resource)} resource bytes, {len(relocs)} relocations)')

if __name__=='__main__':
    main()
