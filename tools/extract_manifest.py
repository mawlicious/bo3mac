#!/usr/bin/env python3
"""
M0 Manifest Extractor for CoDBlkOps3_Exe (Mach-O x86_64).
Produces structured JSON manifests (containing zero game bytes) for the lifter and runtime:
  - segments & sections
  - all 59,804 LC_FUNCTION_STARTS
  - all 1,015 LC_DATA_IN_CODE (DICE_KIND_JUMP_TABLE32) entries
  - all 1,104 __stubs + 289 __got + bind symbols with dylib provenance
  - all 732 __mod_init_func entries (partitioned into ASL/SDL vs Engine)
  - all 28 __thread_vars descriptors + __thread_data/__thread_bss layout
  - Mach-O entry point (LC_MAIN)
"""
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bo3_paths import find_bo3_exe

ENGINE_SPLIT = 0x100250000

def read_uleb128(buf, i):
    val = 0
    shift = 0
    while i < len(buf):
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return val, i

def main():
    bin_path = sys.argv[1] if len(sys.argv) > 1 else find_bo3_exe()
    if not bin_path:
        sys.exit("Could not locate CoDBlkOps3_Exe. Pass its path as argv[1] or set BO3_GAME_DIR.")
    out_path = sys.argv[2] if len(sys.argv) > 2 else "manifests/bo3_manifest.json"

    with open(bin_path, "rb") as f:
        data = f.read()

    sha256 = hashlib.sha256(data).hexdigest()
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IIIIIIII", data, 0)
    assert magic == 0xFEEDFACF, f"Unexpected Mach-O magic: 0x{magic:x}"

    segments = []
    sections = {}
    fs_off = fs_sz = dice_off = dice_sz = entry_off = 0
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[off+8:off+24].rstrip(b"\x00").decode("ascii")
            vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, sflags = struct.unpack_from("<QQQQIIII", data, off+24)
            segments.append({
                "name": segname,
                "vmaddr": vmaddr,
                "vmsize": vmsize,
                "fileoff": fileoff,
                "filesize": filesize,
                "maxprot": maxprot,
                "initprot": initprot,
            })
            so = off + 72
            for _s in range(nsects):
                sectname = data[so:so+16].rstrip(b"\x00").decode("ascii")
                sname = data[so+16:so+32].rstrip(b"\x00").decode("ascii")
                saddr, ssize, soff, align, reloff, nreloc, secflags, r1, r2, r3 = struct.unpack_from("<QQIIIIIIII", data, so+32)
                sections[f"{sname},{sectname}"] = {
                    "seg": sname, "sect": sectname,
                    "addr": saddr, "size": ssize, "offset": soff,
                    "flags": secflags, "reserved2": r2,
                }
                so += 80
        elif cmd == 0x26:  # LC_FUNCTION_STARTS
            fs_off, fs_sz = struct.unpack_from("<II", data, off+8)
        elif cmd == 0x29:  # LC_DATA_IN_CODE
            dice_off, dice_sz = struct.unpack_from("<II", data, off+8)
        elif cmd == 0x80000028:  # LC_MAIN
            entry_off, _stacksize = struct.unpack_from("<QQ", data, off+8)
        off += cmdsize

    # Parse LC_FUNCTION_STARTS
    funcs = []
    cur = 0x100000000
    i = 0
    fs_buf = data[fs_off:fs_off+fs_sz]
    while i < len(fs_buf):
        delta, i = read_uleb128(fs_buf, i)
        if delta == 0:
            break
        cur += delta
        funcs.append(cur)

    # Parse LC_DATA_IN_CODE
    dice = []
    for pos in range(0, dice_sz, 8):
        doff, dlen, dkind = struct.unpack_from("<IHH", data, dice_off + pos)
        dice.append({"va": 0x100000000 + doff, "len": dlen, "kind": dkind})

    # Parse __mod_init_func
    mif = sections["__DATA,__mod_init_func"]
    n_inits = mif["size"] // 8
    init_addrs = list(struct.unpack_from(f"<{n_inits}Q", data, mif["offset"]))

    # Parse __thread_vars (each Mach-O tlv_descriptor is 24 bytes: thunk, key, offset)
    tv = sections["__DATA,__thread_vars"]
    td = sections["__DATA,__thread_data"]
    tb = sections["__DATA,__thread_bss"]
    tlv_vars = []
    for idx in range(tv["size"] // 24):
        thunk, key, offset = struct.unpack_from("<QQQ", data, tv["offset"] + idx * 24)
        tlv_vars.append({
            "va": tv["addr"] + idx * 24,
            "thunk": thunk,
            "key": key,
            "offset": offset,
        })

    # Parse stubs, GOT, and dylib imports via otool + nm
    nm_out = subprocess.check_output(["nm", "-m", bin_path], text=True)
    sym_to_lib = {}
    weak_syms = set()
    for line in nm_out.splitlines():
        if "(undefined)" in line and "(from " in line:
            lib = line.split("(from ")[1].split(")")[0]
            sym = line.split("external ")[-1].split(" (from")[0].strip()
            sym_to_lib[sym] = lib
            if "weak external" in line:
                weak_syms.add(sym)

    iv_out = subprocess.check_output(["otool", "-Iv", bin_path], text=True)
    stubs = []
    got = []
    la_ptrs = []
    mode = None
    for line in iv_out.splitlines():
        if "Indirect symbols for (__TEXT,__stubs)" in line:
            mode = "stubs"; continue
        elif "Indirect symbols for (__DATA,__got)" in line:
            mode = "got"; continue
        elif "Indirect symbols for (__DATA,__la_symbol_ptr)" in line:
            mode = "la"; continue
        elif line.startswith("Indirect symbols for"):
            mode = None; continue
        m = re.match(r'^0x([0-9a-f]+)\s+\d+\s+(\S+)', line)
        if m:
            va = int(m.group(1), 16)
            sym = m.group(2)
            entry = {"va": va, "sym": sym, "lib": sym_to_lib.get(sym, "local_or_weak"), "weak": sym in weak_syms}
            if mode == "stubs": stubs.append(entry)
            elif mode == "got": got.append(entry)
            elif mode == "la": la_ptrs.append(entry)

    # Parse dyld bind opcodes for data-pointer binds in __DATA (vtables/typeinfo/cfstring/etc.)
    binds = []
    try:
        di_out = subprocess.check_output(["xcrun", "objdump", "--macho", "--bind", bin_path], text=True)
        for line in di_out.splitlines():
            m = re.match(r'^(__\w+)\s+(__\w+)\s+0x([0-9a-fA-F]+)\s+(\S+)\s+(-?\d+)\s+(\S+)\s+(\S+)(.*)$', line.strip())
            if m:
                binds.append({
                    "seg": m.group(1),
                    "sect": m.group(2),
                    "va": int(m.group(3), 16),
                    "type": m.group(4),
                    "addend": int(m.group(5)),
                    "lib": m.group(6),
                    "sym": m.group(7),
                    "weak": "weak_import" in m.group(8),
                })
    except Exception as e:
        print(f"Warning: objdump --bind failed: {e}", file=sys.stderr)

    manifest = {
        "binary_sha256": sha256,
        "entry_va": 0x100000000 + entry_off,
        "engine_split_va": ENGINE_SPLIT,
        "segments": segments,
        "sections": sections,
        "function_count": len(funcs),
        "functions": funcs,
        "dice_count": len(dice),
        "dice": dice,
        "mod_init_func": {
            "total": len(init_addrs),
            "aspyr_sdl": [a for a in init_addrs if a < ENGINE_SPLIT],
            "engine": [a for a in init_addrs if a >= ENGINE_SPLIT],
        },
        "tlv": {
            "thread_data_va": td["addr"],
            "thread_data_size": td["size"],
            "thread_bss_va": tb["addr"],
            "thread_bss_size": tb["size"],
            "vars": tlv_vars,
        },
        "stubs": stubs,
        "got": got,
        "la_symbol_ptr": la_ptrs,
        "binds": binds,
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(manifest, f, indent=1)

    print(f"Wrote {out_path} ({os.path.getsize(out_path) / 1024:.1f} KiB)")
    print(f"  SHA256: {sha256}")
    print(f"  Entry:  0x{manifest['entry_va']:x}")
    print(f"  Funcs:  {len(funcs)} (ASL/SDL: {sum(1 for a in funcs if a < ENGINE_SPLIT)}, Engine: {sum(1 for a in funcs if a >= ENGINE_SPLIT)})")
    print(f"  DICE:   {len(dice)}")
    print(f"  Inits:  {len(init_addrs)} (ASL/SDL: {len(manifest['mod_init_func']['aspyr_sdl'])}, Engine: {len(manifest['mod_init_func']['engine'])})")
    print(f"  TLVs:   {len(tlv_vars)} (data={td['size']}B, bss={tb['size']}B)")
    print(f"  Stubs:  {len(stubs)} | GOT: {len(got)} | LA: {len(la_ptrs)} | Binds: {len(binds)}")

if __name__ == "__main__":
    main()
