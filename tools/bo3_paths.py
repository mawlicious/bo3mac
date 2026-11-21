#!/usr/bin/env python3
"""Universal Apple Silicon & Steam BO3 path/hardware auto-discovery for bo3mac.

Importable from Python scripts and runnable as a tiny CLI helper from shell scripts:
  python3 tools/bo3_paths.py --game-dir|--exe|--assets|--metallib|--cache-dir|--mcpu|--workers|--zydis-dir
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys


def _home_dir() -> str:
    return os.path.expanduser("~")


def _read_saved_ini() -> dict[str, str]:
    out: dict[str, str] = {}
    path = os.path.join(_home_dir(), "Library", "Application Support", "bo3mac", "settings.ini")
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                s = line.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, v = s.split("=", 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def find_cache_dir() -> str:
    for var in ("BO3MAC_CACHE_DIR", "BO3ARM_CACHE_DIR"):
        v = os.environ.get(var, "").strip()
        if v:
            return os.path.abspath(os.path.expanduser(v))
    saved = _read_saved_ini().get("cache_dir", "")
    if saved:
        return os.path.abspath(os.path.expanduser(saved))
    return os.path.join(_home_dir(), "Library", "Caches", "bo3mac")


def find_zydis_dir(repo_root: str | None = None) -> str:
    for var in ("BO3MAC_ZYDIS_DIR", "BO3ARM_ZYDIS_DIR"):
        v = os.environ.get(var, "").strip()
        if v:
            return os.path.abspath(os.path.expanduser(v))
    cands = []
    if repo_root:
        cands.append(os.path.join(repo_root, "third_party", "zydis"))
    cache = find_cache_dir()
    cands.append(os.path.join(cache, "zydis"))
    for c in cands:
        if os.path.isfile(os.path.join(c, "amalgamated-dist", "Zydis.h")):
            return c
    return os.path.join(cache, "zydis")


def _parse_steam_library_folders(vdf_path: str) -> list[str]:
    paths: list[str] = []
    try:
        with open(vdf_path, "r", encoding="utf-8", errors="ignore") as f:
            text = f.read()
    except OSError:
        return paths
    for m in re.finditer(r'"path"\s*"([^"]+)"', text):
        p = m.group(1).replace("\\\\", "\\")
        if p and os.path.isdir(p):
            paths.append(p)
    return paths


def _is_valid_bo3_dir(path: str) -> bool:
    exe = os.path.join(path, "CoDBlkOps3.app", "Contents", "MacOS", "CoDBlkOps3_Exe")
    return os.path.isfile(exe)


def find_bo3_dir() -> str | None:
    env_dir = os.environ.get("BO3_GAME_DIR", "").strip()
    if env_dir:
        env_dir = os.path.abspath(os.path.expanduser(env_dir))
        if _is_valid_bo3_dir(env_dir):
            return env_dir
    env_assets = os.environ.get("BO3_ASSETS_DIR", "").strip()
    if env_assets:
        cand = os.path.abspath(os.path.join(os.path.expanduser(env_assets), "..", "..", ".."))
        if _is_valid_bo3_dir(cand):
            return cand
    saved_game = _read_saved_ini().get("game_dir", "")
    if saved_game:
        cand = os.path.abspath(os.path.expanduser(saved_game))
        if _is_valid_bo3_dir(cand):
            return cand

    home = _home_dir()
    steam_root = os.path.join(home, "Library", "Application Support", "Steam")
    library_roots: list[str] = [steam_root]
    vdf = os.path.join(steam_root, "steamapps", "libraryfolders.vdf")
    library_roots.extend(_parse_steam_library_folders(vdf))

    # Also scan mounted external drives (/Volumes/*/SteamLibrary, /Volumes/*/Steam)
    for pattern in ("/Volumes/*/SteamLibrary", "/Volumes/*/Steam", "/Volumes/*/Games/SteamLibrary"):
        library_roots.extend(sorted(glob.glob(pattern)))

    seen: set[str] = set()
    for root in library_roots:
        real = os.path.realpath(root)
        if real in seen:
            continue
        seen.add(real)
        cand = os.path.join(root, "steamapps", "common", "Call of Duty Black Ops III")
        if _is_valid_bo3_dir(cand):
            return cand
    return None


def find_bo3_exe() -> str | None:
    d = find_bo3_dir()
    if not d:
        return None
    return os.path.join(d, "CoDBlkOps3.app", "Contents", "MacOS", "CoDBlkOps3_Exe")


def find_bo3_assets() -> str | None:
    env_assets = os.environ.get("BO3_ASSETS_DIR", "").strip()
    if env_assets and os.path.isdir(os.path.expanduser(env_assets)):
        return os.path.abspath(os.path.expanduser(env_assets))
    d = find_bo3_dir()
    if not d:
        return None
    return os.path.join(d, "CoDBlkOps3.app", "Contents", "Assets")


def find_bo3_metallib() -> str | None:
    d = find_bo3_dir()
    if not d:
        return None
    p = os.path.join(d, "CoDBlkOps3.app", "Contents", "Resources", "Generic.metallib")
    return p if os.path.isfile(p) else None


def _clang_supports_mcpu(mcpu: str) -> bool:
    try:
        r = subprocess.run(
            ["clang", "-arch", "arm64", f"-mcpu={mcpu}", "-x", "c", "-c", "/dev/null", "-o", "/dev/null"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
        return r.returncode == 0
    except OSError:
        return False


def detect_apple_mcpu() -> str:
    """Detect the optimal Apple Silicon clang -mcpu target for this Mac (M1..M6+, Base/Pro/Max/Ultra)."""
    for var in ("BO3MAC_MCPU", "BO3ARM_MCPU"):
        v = os.environ.get(var, "").strip()
        if v:
            return v

    gen = 1
    try:
        brand = subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        m = re.search(r"Apple\s+M(\d+)", brand)
        if m:
            gen = max(1, min(int(m.group(1)), 20))
    except Exception:
        gen = 1

    # Walk down from detected generation (e.g. M6 -> M5 -> M4 -> M3 -> M2 -> M1) until clang accepts it.
    for g in range(gen, 0, -1):
        cand = f"apple-m{g}"
        if _clang_supports_mcpu(cand):
            return cand
    return "apple-m1"


def detect_workers() -> int:
    ncpu = os.cpu_count() or 4
    cap = 16
    try:
        mem_bytes = int(
            subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True, stderr=subprocess.DEVNULL).strip()
        )
        mem_gb = mem_bytes // (1024 ** 3)
        if mem_gb <= 8:
            cap = 4
        elif mem_gb <= 16:
            cap = 8
    except Exception:
        cap = 8
    return max(2, min(ncpu, cap))


def main() -> int:
    ap = argparse.ArgumentParser(description="bo3mac path & Apple Silicon hardware helper")
    ap.add_argument("--game-dir", action="store_true")
    ap.add_argument("--exe", action="store_true")
    ap.add_argument("--assets", action="store_true")
    ap.add_argument("--metallib", action="store_true")
    ap.add_argument("--cache-dir", action="store_true")
    ap.add_argument("--zydis-dir", action="store_true")
    ap.add_argument("--mcpu", action="store_true")
    ap.add_argument("--workers", action="store_true")
    args = ap.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if args.game_dir:
        v = find_bo3_dir()
        if not v:
            return 1
        print(v)
    elif args.exe:
        v = find_bo3_exe()
        if not v:
            return 1
        print(v)
    elif args.assets:
        v = find_bo3_assets()
        if not v:
            return 1
        print(v)
    elif args.metallib:
        v = find_bo3_metallib()
        if not v:
            return 1
        print(v)
    elif args.cache_dir:
        print(find_cache_dir())
    elif args.zydis_dir:
        print(find_zydis_dir(repo_root))
    elif args.mcpu:
        print(detect_apple_mcpu())
    elif args.workers:
        print(detect_workers())
    else:
        print(f"game_dir={find_bo3_dir() or ''}")
        print(f"cache_dir={find_cache_dir()}")
        print(f"zydis_dir={find_zydis_dir(repo_root)}")
        print(f"mcpu={detect_apple_mcpu()}")
        print(f"workers={detect_workers()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
