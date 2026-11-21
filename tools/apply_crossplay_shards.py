#!/usr/bin/env python3
"""Relift only the 17 Core BO3 shards affected by Windows v100 cross-play & 30s join timeout.

Creates a verified exclusive temporary copy of CoDBlkOps3_Exe in the local cache directory,
applies only the 28 verified protocol/changelist/timeout byte edits (never mutating the stock
game binary on disk), relifts+compiles all 17 affected shards into a staging directory tuned
for the host Apple Silicon CPU, and atomically replaces all 17 .o files ONLY if every shard succeeds.
"""
import concurrent.futures
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bo3_paths import detect_apple_mcpu, detect_workers, find_bo3_exe, find_cache_dir

STOCK_EXE = find_bo3_exe()
STOCK_SHA256 = "932f0918fb9871bc625b69a587135a5c2976e9f9e6b7289cfadda8ab996e1cd0"
CACHE_DIR = find_cache_dir()
OUT_DIR = os.path.join(CACHE_DIR, "core_shards")
LIFTER = os.path.join(ROOT, "build", "bo3_lift")

NUM_SHARDS = 80
WORKERS = detect_workers()
TSO = "strict"
OPT = "-O2"
MCPU = detect_apple_mcpu()
MIN_VA = "0x1004a0000"
MAX_VA = "0x1016263d8"

# Exact file-offset byte edits: (file_offset, expected_old_hex, new_hex, description)
# Verified against stock macOS Steam CoDBlkOps3_Exe (SHA-256 932f0918...).
PATCHES = [
    # 24x wire protocol version 0x4862 (18530) -> 0x4864 (18532)
    (0x0e078e4, "6248",     "6448",     "protocol 0x4862->0x4864 (g_100e07879, shard 047)"),
    (0x0e181d3, "6248",     "6448",     "protocol 0x4862->0x4864 (g_100e17e98, shard 071)"),
    (0x0e83e4e, "6248",     "6448",     "protocol 0x4862->0x4864 (g_100e83cb0, shard 049)"),
    (0x0eb8389, "6248",     "6448",     "protocol 0x4862->0x4864 (g_100eb8310, shard 064)"),
    (0x0eb91a9, "6248",     "6448",     "protocol 0x4862->0x4864 (g_100eb90d9, shard 055)"),
    (0x0f988a0, "6248",     "6448",     "protocol 0x4862->0x4864 (g_100f987fe, shard 064)"),
    (0x104e0cb, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10104e0b9, shard 025)"),
    (0x105973d, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10105965d, shard 047)"),
    (0x1059844, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10105965d, shard 047)"),
    (0x105c368, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10105c2a0, shard 059)"),
    (0x105c5dc, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10105c451, shard 041)"),
    (0x11f7c3e, "6248",     "6448",     "protocol 0x4862->0x4864 (g_1011f7b98, shard 049)"),
    (0x11f7c43, "6248",     "6448",     "protocol 0x4862->0x4864 (g_1011f7b98, shard 049)"),
    (0x11f7c49, "6248",     "6448",     "protocol 0x4862->0x4864 (g_1011f7b98, shard 049)"),
    (0x120b547, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10120b4b2, shard 076)"),
    (0x120b56a, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10120b4b2, shard 076)"),
    (0x123244c, "6248",     "6448",     "protocol 0x4862->0x4864 (g_1012321fd, shard 032)"),
    (0x126f78c, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10126f750, shard 074)"),
    (0x126f897, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10126f86f, shard 072)"),
    (0x126f8bc, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10126f86f, shard 072)"),
    (0x126f90d, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10126f86f, shard 072)"),
    (0x126f96f, "6248",     "6448",     "protocol 0x4862->0x4864 (g_10126f921, shard 053)"),
    (0x12d35da, "6248",     "6448",     "protocol 0x4862->0x4864 (g_1012d3542, shard 028)"),
    (0x13b5c1d, "6248",     "6448",     "protocol 0x4862->0x4864 (g_1013b5bdb, shard 036)"),
    # Lua_CoD_LuaCall_GetProtocolVersion IEEE float 18530 -> 18532 (shard 053)
    (0x0e1fcab, "00c49046", "00c89046", "Lua protocol float 18530->18532 (g_100e1fca0, shard 053)"),
    # LPC_GetRemoteManifest online manifest category 0x514 -> 0x528 (shard 017)
    (0x0ea8c0a, "14050000", "28050000", "LPC manifest category 0x514->0x528 (g_100ea8b0c, shard 017)"),
    # LobbyHostMsg_SendJoinRequest changelist call -> mov eax, 0x00d3fc12 (shard 032)
    (0x1232458, "e8c046ceff", "b812fcd300", "JoinRequest changelist 0x00d3fc12 (g_1012321fd, shard 032)"),
    # Lobby join-info timeout default 10000 -> 30000 ms (shard 063)
    (0x1315ffc, "10270000", "30750000", "Lobby join-info timeout 10000->30000ms (g_101315623, shard 063)"),
]

AFFECTED_SHARDS = [17, 25, 28, 32, 36, 41, 47, 49, 53, 55, 59, 63, 64, 71, 72, 74, 76]


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "apply"
    if mode not in ("apply", "revert"):
        sys.exit("Usage: apply_crossplay_shards.py [apply|revert]")

    if not STOCK_EXE:
        sys.exit("Could not locate Steam BO3 CoDBlkOps3_Exe (set BO3_GAME_DIR)")
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(STOCK_EXE, "rb") as f:
        data = bytearray(f.read())
    digest = hashlib.sha256(data).hexdigest()
    if digest != STOCK_SHA256:
        sys.exit(f"Stock executable SHA-256 mismatch: got {digest}, expected {STOCK_SHA256}")

    stage_dir = tempfile.mkdtemp(prefix=".crossplay_stage_", dir=OUT_DIR)
    tmp_exe = None
    try:
        if mode == "apply":
            for off, old_hex, new_hex, desc in PATCHES:
                old_b = bytes.fromhex(old_hex)
                new_b = bytes.fromhex(new_hex)
                assert len(old_b) == len(new_b), desc
                cur = bytes(data[off : off + len(old_b)])
                if cur != old_b:
                    sys.exit(f"Byte mismatch at 0x{off:x} ({desc}): got {cur.hex()}, expected {old_hex}")
                data[off : off + len(new_b)] = new_b
            fd, tmp_exe = tempfile.mkstemp(prefix="CoDBlkOps3_Exe.xp_", dir=stage_dir)
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(data)
            except BaseException:
                os.unlink(tmp_exe)
                raise
            lift_exe = tmp_exe
            print(f"[crossplay-shards] Verified & patched {len(PATCHES)} sites -> staging {len(AFFECTED_SHARDS)} shards (mcpu={MCPU})...", flush=True)
        else:
            lift_exe = STOCK_EXE
            print(f"[crossplay-shards] Reverting {len(AFFECTED_SHARDS)} shards to stock v98 in staging (mcpu={MCPU})...", flush=True)

        def build_one(idx):
            t0 = time.time()
            ll_path = os.path.join(stage_dir, f"shard_{idx:03d}.ll")
            o_path  = os.path.join(stage_dir, f"shard_{idx:03d}.o")
            r1 = subprocess.run(
                [LIFTER, "--shard", lift_exe, MIN_VA, MAX_VA, str(idx), str(NUM_SHARDS),
                 "--tso", TSO, "--mcpu", MCPU, "-o", ll_path],
                capture_output=True, text=True,
            )
            if r1.returncode != 0:
                return (idx, False, f"lift failed: {r1.stderr.strip()}")
            t1 = time.time()
            r2 = subprocess.run(
                ["clang", "-arch", "arm64", f"-mcpu={MCPU}", "-mmacosx-version-min=13.0", OPT, "-Wno-override-module", "-x", "ir", "-c", ll_path, "-o", o_path],
                capture_output=True, text=True,
            )
            t2 = time.time()
            if r2.returncode != 0:
                return (idx, False, f"clang failed:\n{r2.stderr[:1200]}")
            os.remove(ll_path)
            return (idx, True, f"lift={t1-t0:.1f}s clang={t2-t1:.1f}s o={os.path.getsize(o_path)//1024}KB")

        t_start = time.time()
        ok = 0
        fail = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
            futs = [ex.submit(build_one, i) for i in AFFECTED_SHARDS]
            for fut in concurrent.futures.as_completed(futs):
                idx, is_ok, msg = fut.result()
                if is_ok:
                    ok += 1
                    print(f"[{ok}/{len(AFFECTED_SHARDS)}] shard {idx:03d} OK ({msg})", flush=True)
                else:
                    fail += 1
                    print(f"FAIL shard {idx:03d}: {msg}", file=sys.stderr, flush=True)

        if fail != 0:
            sys.exit(f"[crossplay-shards] Aborted: {fail} shard(s) failed; live cache untouched.")

        # Atomically publish all 17 staged objects only after every shard succeeded.
        for idx in AFFECTED_SHARDS:
            os.replace(
                os.path.join(stage_dir, f"shard_{idx:03d}.o"),
                os.path.join(OUT_DIR, f"shard_{idx:03d}.o"),
            )
        print(f"[crossplay-shards] Published {ok}/{len(AFFECTED_SHARDS)} shards atomically in {time.time()-t_start:.1f}s")
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
