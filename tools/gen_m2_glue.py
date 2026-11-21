#!/usr/bin/env python3
"""
Generate M2 glue files in <cache>/m2_gen/:
  1. gen_registry.c  : registers all lifted Core BO3+Havok functions + Aspyr shims into bo3_resolve()
  2. gen_aspyr_weak.c: weak tracing stubs for all below-core _g_* targets so any function implemented
                       in runtime/shim_aspyr_os.c overrides it automatically with zero link conflicts.
  3. gen_binds.c     : applies the exact LC_DYLD_INFO __DATA/__got binds needed by Core BO3
                       (__stack_chk_guard, __stderrp/__stdoutp/__stdinp, _DefaultRuneLocale,
                        mach_task_self_, plus synthetic guest VAs for bound function pointers like malloc/free!)
  4. gen_extra_reg.c : registers all extra shard functions (shard_extra_44a.o) into bo3_resolve()
"""
from __future__ import annotations
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bo3_paths import find_bo3_exe, find_cache_dir

CACHE = find_cache_dir()
SHARDS_DIR = os.path.join(CACHE, "core_shards")
GEN_DIR = os.path.join(CACHE, "m2_gen")
os.makedirs(GEN_DIR, exist_ok=True)

core_objs = sorted(glob.glob(os.path.join(SHARDS_DIR, "shard_[0-9][0-9][0-9].o")))
if not core_objs:
    sys.exit(f"gen_m2_glue: no core shards found in {SHARDS_DIR} (run tools/build_shards.py first)")

def _scan_g_symbols(objs, defined: bool) -> set[str]:
    flag = "-gU" if defined else "-gu"
    out = subprocess.check_output(["nm", flag] + objs, text=True)
    syms: set[str] = set()
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        sym = parts[-1]
        if sym.startswith("_g_"):
            syms.add(sym)
    return syms

def_set = _scan_g_symbols(core_objs, defined=True)
undef_set = _scan_g_symbols(core_objs, defined=False)
extra_obj = os.path.join(SHARDS_DIR, "shard_extra_44a.o")
extra_def: list[str] = []
if os.path.isfile(extra_obj):
    extra_def_set = _scan_g_symbols([extra_obj], defined=True)
    extra_undef_set = _scan_g_symbols([extra_obj], defined=False)
    extra_def = sorted(extra_def_set)
    undef_set = (undef_set | extra_undef_set) - extra_def_set

def_g = sorted(def_set)
need_g = sorted(undef_set - def_set)

with open(os.path.join(CACHE, "m2_def_g.txt"), "w") as f:
    f.write("\n".join(def_g) + "\n")
with open(os.path.join(CACHE, "m2_need_g.txt"), "w") as f:
    f.write("\n".join(need_g) + "\n")

manifest_path = os.path.join(ROOT, "manifests/bo3_manifest.json")
if not os.path.isfile(manifest_path):
    exe = find_bo3_exe()
    if not exe:
        sys.exit("gen_m2_glue: manifests/bo3_manifest.json missing and CoDBlkOps3_Exe not found")
    subprocess.check_call([sys.executable, os.path.join(ROOT, "tools/extract_manifest.py"), exe, manifest_path], cwd=ROOT)
m = json.load(open(manifest_path))

# 1. gen_aspyr_weak.c
with open(os.path.join(GEN_DIR, "gen_aspyr_weak.c"), "w") as f:
    f.write('#include "shim_helpers.h"\n#include <stdio.h>\n#include <stdlib.h>\n\n')
    for sym in need_g:
        # sym is like _g_100109a36 -> C name is g_100109a36
        cname = sym[1:]
        va_hex = cname[2:]
        f.write(f'__attribute__((weak)) SHIM_DEF({cname}) {{\n')
        f.write('    SHIM_UNUSED_ALL();\n')
        f.write(f'    fprintf(stderr, "[ASPYR_UNIMPL] 0x{va_hex} rdi=0x%llx rsi=0x%llx rdx=0x%llx rcx=0x%llx\\n",\n')
        f.write('            (unsigned long long)rdi, (unsigned long long)rsi, (unsigned long long)rdx, (unsigned long long)rcx);\n')
        f.write('    fflush(stderr);\n')
        f.write(f'    bo3_trap(0x{va_hex}ULL, 88, ctx);\n')
        f.write('}\n')

# 2. gen_registry.c (registers all 41,044 lifted functions + 252 below-core shims + 709 engine mod_init_func list)
with open(os.path.join(GEN_DIR, "gen_registry.c"), "w") as f:
    f.write('#include "cpu_state.h"\n#include <stdint.h>\n#include <stddef.h>\n\n')
    all_g = def_g + need_g
    for sym in all_g:
        cname = sym[1:]
        f.write(f'extern GuestRet {cname}(GuestContext*,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,GuestXmm,GuestXmm,GuestXmm,GuestXmm,GuestXmm,GuestXmm,GuestXmm,GuestXmm);\n')
    f.write('\nvoid bo3_register_all_functions(void) {\n')
    for sym in all_g:
        cname = sym[1:]
        va_hex = cname[2:]
        f.write(f'    bo3_register_fn(0x{va_hex}ULL, {cname});\n')
    f.write('}\n\n')

    # Engine __mod_init_func list (>= 0x1004a0000)
    eng_inits = [int(x, 16) if isinstance(x, str) else x for x in m["mod_init_func"]["engine"]]
    eng_inits = [x for x in eng_inits if x >= 0x1004a0000]
    f.write(f'const uint64_t g_bo3_engine_init_funcs[{len(eng_inits)}] = {{\n')
    for va in eng_inits:
        f.write(f'    0x{va:x}ULL,\n')
    f.write('};\n')
    f.write(f'const size_t g_bo3_engine_init_count = {len(eng_inits)};\n')

# 3. gen_binds.c (applies libSystem/libc++ __DATA/__got binds + TLV descriptors!)
data_binds = []
fn_binds = []
fn_sym_set = {
    "_malloc", "_calloc", "_realloc", "_free", "_strcmp",
    "_sin", "_cos", "_tan", "_exp", "_log", "_acos", "_asin", "_atan", "_cosh", "_sinh", "_tanh", "_fabs",
}
data_sym_map = {
    "___stack_chk_guard": "&__stack_chk_guard",
    "___stderrp":         "&__stderrp",
    "___stdoutp":         "&__stdoutp",
    "___stdinp":          "&__stdinp",
    "__DefaultRuneLocale":"&_DefaultRuneLocale",
    "_mach_task_self_":   "&mach_task_self_",
}
for b in m["binds"]:
    sym = b["sym"]
    if sym in data_sym_map:
        data_binds.append((b["va"], data_sym_map[sym], b["addend"]))
    elif sym in fn_sym_set and b["sect"] in ("__got", "__data"):
        fn_binds.append((b["va"], sym))

with open(os.path.join(GEN_DIR, "gen_binds.c"), "w") as f:
    f.write('''#include "shim_helpers.h"
#include <ctype.h>
#include <mach/mach.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

extern uintptr_t __stack_chk_guard;
extern GuestRet shim__malloc(SHIM_PARAMS);
extern GuestRet shim__calloc(SHIM_PARAMS);
extern GuestRet shim__realloc(SHIM_PARAMS);
extern GuestRet shim__free(SHIM_PARAMS);
extern GuestRet shim__strcmp(SHIM_PARAMS);
extern GuestRet shim__cos(SHIM_PARAMS);
extern GuestRet shim__tan(SHIM_PARAMS);
extern GuestRet shim__acos(SHIM_PARAMS);
extern GuestRet shim__atan(SHIM_PARAMS);
extern GuestRet shim__log(SHIM_PARAMS);
extern GuestRet shim__exp(SHIM_PARAMS);

static SHIM_DEF(shim_bind_sin)  { SHIM_UNUSED_ALL(); return ret_f64(sin(xmm_to_f64(xmm0))); }
static SHIM_DEF(shim_bind_asin) { SHIM_UNUSED_ALL(); return ret_f64(asin(xmm_to_f64(xmm0))); }
static SHIM_DEF(shim_bind_sinh) { SHIM_UNUSED_ALL(); return ret_f64(sinh(xmm_to_f64(xmm0))); }
static SHIM_DEF(shim_bind_cosh) { SHIM_UNUSED_ALL(); return ret_f64(cosh(xmm_to_f64(xmm0))); }
static SHIM_DEF(shim_bind_tanh) { SHIM_UNUSED_ALL(); return ret_f64(tanh(xmm_to_f64(xmm0))); }
static SHIM_DEF(shim_bind_fabs) { SHIM_UNUSED_ALL(); return ret_f64(fabs(xmm_to_f64(xmm0))); }

void bo3_apply_data_binds(void) {
''')
    for va, expr, addend in data_binds:
        f.write(f'    *(uint64_t *)(0x{va:x}ULL) = (uint64_t)(uintptr_t)({expr}) + {addend}ULL;\n')

    fn_map = {
        "_malloc": "shim__malloc", "_calloc": "shim__calloc",
        "_realloc": "shim__realloc", "_free": "shim__free",
        "_strcmp": "shim__strcmp", "_cos": "shim__cos", "_tan": "shim__tan",
        "_acos": "shim__acos", "_atan": "shim__atan", "_log": "shim__log", "_exp": "shim__exp",
        "_sin": "shim_bind_sin", "_asin": "shim_bind_asin", "_sinh": "shim_bind_sinh",
        "_cosh": "shim_bind_cosh", "_tanh": "shim_bind_tanh", "_fabs": "shim_bind_fabs",
    }
    synth_va = 0x100001000
    sym_to_synth = {}
    for va, sym in fn_binds:
        if sym not in sym_to_synth:
            sym_to_synth[sym] = synth_va
            f.write(f'    bo3_register_fn(0x{synth_va:x}ULL, {fn_map[sym]});\n')
            synth_va += 8
        f.write(f'    *(uint64_t *)(0x{va:x}ULL) = 0x{sym_to_synth[sym]:x}ULL;\n')
    f.write('}\n')

# 4. gen_extra_reg.c (registers shard_extra_44a.o functions)
with open(os.path.join(GEN_DIR, "gen_extra_reg.c"), "w") as f:
    f.write('#include "cpu_state.h"\n')
    for sym in extra_def:
        cname = sym[1:]
        f.write(f'extern GuestRet {cname}(GuestContext*,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,GuestXmm,GuestXmm,GuestXmm,GuestXmm,GuestXmm,GuestXmm,GuestXmm,GuestXmm);\n')
    f.write('\nvoid bo3_register_extra_shards(void) {\n')
    for sym in extra_def:
        cname = sym[1:]
        va_hex = cname[2:]
        f.write(f'    bo3_register_fn(0x{va_hex}ULL, {cname});\n')
    f.write('}\n')

print(f"Generated M2 glue: {len(def_g)} core + {len(extra_def)} extra + {len(need_g)} weak Aspyr + {len(data_binds)} data binds + {len(fn_binds)} fn binds")
