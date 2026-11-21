#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Usage: tools/run_bo3.sh [options]

  (In-game live settings overlay: press F10 or Cmd+, at any time)

  --metalfx               Enable MetalFX Spatial upscaling
  --no-metalfx            Disable MetalFX Spatial upscaling
  --scale PCT             Set startup virtual display scale (50..100, implies --metalfx when <100)
  --lossy-rt              Enable M2+/M4+ lossy compression on large render targets
  --no-lossy-rt           Disable lossy render-target compression
  --latency N             Override swapchain max frame latency (0=auto, 1..3)
  --hud MODE              Performance corner HUD: 0=off, 1=fps, 2=detailed
  --offline               Launch in offline mode (no Steam client required)
  --public                Allow public lobbies (disables Friends-Only safety guard)
  --perf                  Print [m5-perf] frame/GPU/TBDR stats to stderr
  --debug                 Enable Metal validation layer (developer use; slower)
  --console               Trace the guest console
  --files                 Trace guest file access
  --capture FRAME [PATH]  Capture a frame as a PNG
  --help                  Show this help

Environment overrides: BO3_GAME_DIR, BO3_ASSETS_DIR, BO3MAC_CACHE_DIR, BO3ARM_DYLIB.
EOF
}

fail() {
    printf 'run_bo3: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug)       export MTL_DEBUG_LAYER=1 ;;
        --perf)        export BO3ARM_PERF_STATS=1 ;;
        --metalfx)     export BO3ARM_METALFX=1 ;;
        --no-metalfx)  export BO3ARM_METALFX=0 ;;
        --lossy-rt)    export BO3ARM_LOSSY_RT=1 ;;
        --no-lossy-rt) export BO3ARM_LOSSY_RT=0 ;;
        --offline)     export BO3ARM_OFFLINE=1 ;;
        --public)      export BO3ARM_FRIENDS_ONLY=0 ;;
        --hud)
            shift
            case "${1-}" in
                0|1|2) export BO3ARM_HUD="$1" ;;
                *) fail '--hud must be 0 (off), 1 (fps), or 2 (detailed)' ;;
            esac
            ;;
        --scale)
            shift
            case "${1-}" in
                ''|*[!0123456789]*) fail '--scale requires an integer percentage (50..100)' ;;
            esac
            scale=${1#"${1%%[!0]*}"}
            [ -n "$scale" ] || scale=0
            if [ "${#scale}" -gt 3 ] || [ "$scale" -lt 50 ] || [ "$scale" -gt 100 ]; then
                fail '--scale must be between 50 and 100'
            fi
            export BO3ARM_RENDER_SCALE="$scale"
            if [ "$scale" -lt 100 ]; then
                export BO3ARM_METALFX=1
            fi
            ;;
        --latency)
            shift
            case "${1-}" in
                0|1|2|3) export BO3ARM_MAX_FRAME_LATENCY="$1" ;;
                *) fail '--latency must be 0, 1, 2, or 3' ;;
            esac
            ;;
        --console) export BO3ARM_TRACE_CONSOLE=1 ;;
        --files)   export BO3ARM_TRACE_FILES=1 ;;
        --capture)
            shift
            case "${1-}" in
                ''|*[!0123456789]*) fail '--capture requires a positive frame number' ;;
            esac
            frame=${1#"${1%%[!0]*}"}
            [ -n "$frame" ] || fail '--capture requires a positive frame number'
            if [ "${#frame}" -gt 20 ] ||
                { [ "${#frame}" -eq 20 ] && LC_ALL=C expr "x$frame" \> x18446744073709551615 >/dev/null; }; then
                fail '--capture frame exceeds 18446744073709551615'
            fi
            export BO3ARM_CAPTURE_FRAME="$frame"
            case "${2-}" in
                ''|-*) ;;
                *) export BO3ARM_CAPTURE_PATH="$2"; shift ;;
            esac
            ;;
        --help) usage; exit 0 ;;
        *) fail "unknown option '$1' (see --help)" ;;
    esac
    shift
done

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
loader="$root/build/bo3_loader"
cache_dir=$(python3 "$root/tools/bo3_paths.py" --cache-dir)
dylib=${BO3ARM_DYLIB:-$cache_dir/libbo3_recomp.dylib}
if [ -n "${BO3_ASSETS_DIR-}" ]; then
    assets=$BO3_ASSETS_DIR
else
    assets=$(python3 "$root/tools/bo3_paths.py" --assets) ||
        fail "could not find Steam Black Ops III installation (set BO3_GAME_DIR or install BO3 via Steam)"
fi

case "$dylib" in
    /*) ;;
    *) dylib="$PWD/$dylib" ;;
esac
case "${BO3ARM_CAPTURE_PATH-}" in
    ''|/*) ;;
    *) export BO3ARM_CAPTURE_PATH="$PWD/$BO3ARM_CAPTURE_PATH" ;;
esac

[ -x "$loader" ] || fail "loader is missing or not executable at $loader"
[ -f "$dylib" ] && [ -r "$dylib" ] || fail "cannot read library at $dylib"
CDPATH= cd -- "$assets" || fail "cannot enter Assets directory at $assets"
[ -f ../MacOS/CoDBlkOps3_Exe ] && [ -r ../MacOS/CoDBlkOps3_Exe ] ||
    fail "cannot read the guest executable next to $assets"
exec "$loader" "../MacOS/CoDBlkOps3_Exe" "$dylib"
