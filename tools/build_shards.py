#!/usr/bin/env python3
"""Parallel sharded lift + Apple Clang 21 ARM64 compilation of Core BO3+Havok."""
import concurrent.futures
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bo3_paths import detect_apple_mcpu, detect_workers, find_bo3_exe, find_cache_dir

EXE = find_bo3_exe()
if not EXE:
    sys.exit("build_shards: could not find Steam BO3 CoDBlkOps3_Exe (set BO3_GAME_DIR)")
CACHE_DIR = find_cache_dir()
OUT_DIR = os.path.join(CACHE_DIR, "core_shards")

try:
    NUM_SHARDS = int(sys.argv[1]) if len(sys.argv) > 1 else 80
except ValueError:
    sys.exit("build_shards: num_shards must be an integer")
if not 1 <= NUM_SHARDS <= 2**31 - 1:
    sys.exit("build_shards: num_shards must be between 1 and 2147483647")

try:
    WORKERS = int(sys.argv[2]) if len(sys.argv) > 2 else detect_workers()
except ValueError:
    sys.exit("build_shards: workers must be an integer")
if WORKERS <= 0:
    sys.exit("build_shards: workers must be positive")

TSO = sys.argv[3] if len(sys.argv) > 3 else "strict"
OPT = sys.argv[4] if len(sys.argv) > 4 else "-O2"
MCPU = detect_apple_mcpu()

MIN_VA = "0x1004a0000"
MAX_VA = "0x1016263d8"
LIFTER = os.path.join(ROOT, "build", "bo3_lift")
WRAP_VAS = [
    "0x100e09aa9",  # HKAI_InitMapData (native Havok nav conversion wrapper)
    "0x101345b12",  # DB_FindXAssetHeader (Roulette V2 script callback fix)
    "0x100f16d9a",  # Com_GetBuildIntField (Mac! compatibility probe)
]
WRAP_ARGS = [arg for va in WRAP_VAS for arg in ("--wrap-va", va)]

def build_one(idx):
    t0 = time.time()
    ll_path = os.path.join(OUT_DIR, f"shard_{idx:03d}.ll")
    o_path  = os.path.join(OUT_DIR, f"shard_{idx:03d}.o")
    tmp_o   = f"{o_path}.tmp.{os.getpid()}"
    r1 = subprocess.run(
        [LIFTER, "--shard", EXE, MIN_VA, MAX_VA, str(idx), str(NUM_SHARDS),
         "--tso", TSO, "--mcpu", MCPU, *WRAP_ARGS, "-o", ll_path],
        capture_output=True, text=True
    )
    if r1.returncode != 0:
        return (idx, False, f"lift failed: {r1.stderr.strip()}", 0, 0)
    t1 = time.time()
    r2 = subprocess.run(
        ["clang", "-arch", "arm64", f"-mcpu={MCPU}", "-mmacosx-version-min=13.0", OPT, "-Wno-override-module", "-x", "ir", "-c", ll_path, "-o", tmp_o],
        capture_output=True, text=True
    )
    t2 = time.time()
    if r2.returncode != 0:
        if os.path.exists(tmp_o):
            os.remove(tmp_o)
        return (idx, False, f"clang failed on {ll_path}:\n{r2.stderr[:1200]}", t2 - t0, 0)
    os.replace(tmp_o, o_path)
    os.remove(ll_path)
    osz = os.path.getsize(o_path)
    return (idx, True, f"lift={t1-t0:.1f}s clang={t2-t1:.1f}s o={osz//1024}KB", t2 - t0, osz)

def build_extra_44a():
    t0 = time.time()
    ll_path = os.path.join(OUT_DIR, "shard_extra_44a.ll")
    o_path  = os.path.join(OUT_DIR, "shard_extra_44a.o")
    tmp_o   = f"{o_path}.tmp.{os.getpid()}"
    r1 = subprocess.run(
        [LIFTER, "--shard", EXE, "0x10044a000", "0x1004a0000", "0", "1",
         "--tso", TSO, "--mcpu", MCPU, "-o", ll_path],
        capture_output=True, text=True
    )
    if r1.returncode != 0:
        return ("extra_44a", False, f"lift failed: {r1.stderr.strip()}", 0, 0)
    t1 = time.time()
    r2 = subprocess.run(
        ["clang", "-arch", "arm64", f"-mcpu={MCPU}", "-mmacosx-version-min=13.0", OPT, "-Wno-override-module", "-x", "ir", "-c", ll_path, "-o", tmp_o],
        capture_output=True, text=True
    )
    t2 = time.time()
    if r2.returncode != 0:
        if os.path.exists(tmp_o):
            os.remove(tmp_o)
        return ("extra_44a", False, f"clang failed on {ll_path}:\n{r2.stderr[:1200]}", t2 - t0, 0)
    os.replace(tmp_o, o_path)
    os.remove(ll_path)
    osz = os.path.getsize(o_path)
    return ("extra_44a", True, f"lift={t1-t0:.1f}s clang={t2-t1:.1f}s o={osz//1024}KB", t2 - t0, osz)

os.makedirs(OUT_DIR, exist_ok=True)
print(f"[build_shards] Building {NUM_SHARDS} core shards + extra_44a for {MCPU} ({WORKERS} workers, {OPT}, tso={TSO})...", flush=True)
t_start = time.time()
ok_cnt = 0
fail_cnt = 0
total_bytes = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
    futs = [ex.submit(build_one, i) for i in range(NUM_SHARDS)]
    futs.append(ex.submit(build_extra_44a))
    total_jobs = len(futs)
    for f in concurrent.futures.as_completed(futs):
        idx, ok, msg, dt, osz = f.result()
        label = f"{idx:03d}" if isinstance(idx, int) else str(idx)
        if ok:
            ok_cnt += 1
            total_bytes += osz
            if ok_cnt % 10 == 0 or ok_cnt == total_jobs:
                print(f"[{ok_cnt}/{total_jobs}] shard {label} OK ({msg}) elapsed={time.time()-t_start:.1f}s", flush=True)
        else:
            fail_cnt += 1
            print(f"FAIL shard {label}: {msg}", file=sys.stderr, flush=True)

elapsed = time.time() - t_start
print(f"\n=== FULL CORE BO3+HAVOK BUILD SUMMARY ===")
print(f"Shards: {ok_cnt}/{total_jobs} OK, {fail_cnt} FAILED")
print(f"Total ARM64 .o size: {total_bytes / (1024*1024):.2f} MiB")
print(f"Wall time ({WORKERS} workers, {MCPU}, {OPT}, tso={TSO}): {elapsed:.1f}s")
sys.exit(0 if fail_cnt == 0 else 1)
