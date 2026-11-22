#!/usr/bin/env python3
"""Relift the Core BO3 shards affected by Workshop/Custom-Map compatibility and optional Windows v100 cross-play.

Creates a verified exclusive temporary copy of CoDBlkOps3_Exe in the local cache directory,
applies verified byte edits (never mutating the stock game binary on disk), relifts+compiles
the affected shards into a staging directory tuned for the host Apple Silicon CPU, and
atomically replaces all affected .o files ONLY if every shard succeeds.
"""
from __future__ import annotations
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

# Core BO3 functions wrapped by runtime/workshop_mac.c (emitted as orig_g_<va>).
WORKSHOP_WRAPS = [
    "0x100e09aa9",  # HKAI_InitMapData (shard 057)
    "0x101345b12",  # DB_FindXAssetHeader (shard 062)
    "0x100f16d9a",  # Com_GetBuildIntField (shard 041)
]
WRAP_ARGS = [arg for va in WORKSHOP_WRAPS for arg in ("--wrap-va", va)]

# Always-on Workshop mods & custom maps fixes (applied in both cross-play and stock v98 modes).
# Engine patch offsets follow upstream BO3MacFix (InvoxiPlayGames).
WORKSHOP_PATCHES = [
    # Scr_ErrorInternal: Aspyr forces all GSC script errors to be fatal (1 -> 0); Windows treats non-fatal errors as non-fatal.
    (0x11a2392, "01",         "00",         "Scr_ErrorInternal non-fatal (g_1011a2292, shard 042)"),
    # Lua_CmdParseArgs: early ret prevents crashes in Workshop mods parsing Lua commands.
    (0x1408cf9, "55",         "c3",         "Lua_CmdParseArgs crash fix (g_101408cf9, shard 062)"),
    # load_workshop_texture: Aspyr's PNG->texture loader crashes on Workshop previews; return NULL cleanly.
    (0x0e4a26c, "554889e5",   "31c0c390",   "load_workshop_texture -> NULL (g_100e4a26c, shard 073)"),
    # HKAI_InitMapData: force strcmp(mapname, "cp_mi_cairo_infection2") -> 0 (matching upstream BO3MacFix)
    # so every map uses Aspyr's two-file disk .hkt load path compatible with converted custom nav files.
    (0x0e09f68, "e82bdd8100", "b800000000", "HKAI_InitMapData DemonWithinCheck -> 0 (g_100e09aa9, shard 057)"),
]

# Optional Windows v100 online cross-play & 30s join timeout patches.
CROSSPLAY_PATCHES = [
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

WORKSHOP_SHARDS = [41, 42, 57, 62, 73]
CROSSPLAY_SHARDS = [17, 25, 28, 32, 36, 41, 47, 49, 53, 55, 59, 63, 64, 71, 72, 74, 76]
ALL_SHARDS = sorted(set(WORKSHOP_SHARDS) | set(CROSSPLAY_SHARDS))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "apply"
    if mode not in ("apply", "revert", "workshop"):
        sys.exit("Usage: apply_crossplay_shards.py [apply|revert|workshop]")

    if not STOCK_EXE:
        sys.exit("Could not locate Steam BO3 CoDBlkOps3_Exe (set BO3_GAME_DIR)")
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(STOCK_EXE, "rb") as f:
        data = bytearray(f.read())
    digest = hashlib.sha256(data).hexdigest()
    if digest != STOCK_SHA256:
        sys.exit(f"Stock executable SHA-256 mismatch: got {digest}, expected {STOCK_SHA256}")

    if mode == "apply":
        patches = WORKSHOP_PATCHES + CROSSPLAY_PATCHES
        target_shards = ALL_SHARDS
        label = "Workshop + Windows v100 cross-play"
    elif mode == "workshop":
        patches = WORKSHOP_PATCHES
        target_shards = WORKSHOP_SHARDS
        label = "Workshop + custom maps (stock v98)"
    else:
        patches = WORKSHOP_PATCHES
        target_shards = ALL_SHARDS
        label = "revert cross-play to stock v98 (keep Workshop)"

    stage_dir = tempfile.mkdtemp(prefix=".crossplay_stage_", dir=OUT_DIR)
    tmp_exe = None
    try:
        for off, old_hex, new_hex, desc in patches:
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
        print(
            f"[shards] {label}: verified & patched {len(patches)} sites -> staging {len(target_shards)} shards (mcpu={MCPU})...",
            flush=True,
        )

        def build_one(idx):
            t0 = time.time()
            ll_path = os.path.join(stage_dir, f"shard_{idx:03d}.ll")
            o_path  = os.path.join(stage_dir, f"shard_{idx:03d}.o")
            r1 = subprocess.run(
                [LIFTER, "--shard", lift_exe, MIN_VA, MAX_VA, str(idx), str(NUM_SHARDS),
                 "--tso", TSO, "--mcpu", MCPU, *WRAP_ARGS, "-o", ll_path],
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
            futs = [ex.submit(build_one, i) for i in target_shards]
            for fut in concurrent.futures.as_completed(futs):
                idx, is_ok, msg = fut.result()
                if is_ok:
                    ok += 1
                    print(f"[{ok}/{len(target_shards)}] shard {idx:03d} OK ({msg})", flush=True)
                else:
                    fail += 1
                    print(f"FAIL shard {idx:03d}: {msg}", file=sys.stderr, flush=True)

        if fail != 0:
            sys.exit(f"[shards] Aborted: {fail} shard(s) failed; live cache untouched.")

        # Invalidate the build stamp before replacing any live shard so an interrupted
        # publish can never leave a stale stamp describing a mixed v98/v100 cache.
        stamp_path = os.path.join(CACHE_DIR, ".build_stamp")
        try:
            os.unlink(stamp_path)
        except FileNotFoundError:
            pass

        # Atomically publish all staged objects only after every shard succeeded.
        for idx in target_shards:
            os.replace(
                os.path.join(stage_dir, f"shard_{idx:03d}.o"),
                os.path.join(OUT_DIR, f"shard_{idx:03d}.o"),
            )
        print(f"[shards] Published {ok}/{len(target_shards)} shards atomically in {time.time()-t_start:.1f}s")
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
