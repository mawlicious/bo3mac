#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# bo3mac — One-Command Native Apple Silicon Installer for Black Ops III
# Works on ANY Apple Silicon Mac (M1 / M2 / M3 / M4 / M5 / M6+ Base/Pro/Max/Ultra).
# Uses your own Steam installation of Call of Duty: Black Ops III (zero game
# assets are downloaded or modified inside Steam).
# =============================================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"
ZYDIS_VERSION="v4.1.0"
ZYDIS_URL="https://github.com/zyantific/zydis/releases/download/${ZYDIS_VERSION}/zydis-amalgamated.tar.gz"
ZYDIS_SHA256="aa9b82be3a37a2998bd8e16cf583bbf2b6c3d80e97dc20504169dc32ca1ced59"
STOCK_SHA256="932f0918fb9871bc625b69a587135a5c2976e9f9e6b7289cfadda8ab996e1cd0"

REBUILD=0
CROSSPLAY=1
INSTALL_APP=1
ALLOW_UNVERIFIED=0
APP_DEST="/Applications/BO3 Mac.app"

TMP_CLEANUP=()
cleanup() {
    for p in "${TMP_CLEANUP[@]:-}"; do
        [ -n "$p" ] && rm -rf "$p"
    done
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

  --game-dir PATH      Path to Steam "Call of Duty Black Ops III" folder (auto-detected if omitted)
  --cache-dir PATH     Directory for compiled ARM64 build cache (default: ~/Library/Caches/bo3mac)
  --no-crossplay       Skip the optional Windows v100 online cross-play shard patch
  --rebuild            Force full recompilation of all ARM64 shards from scratch
  --skip-app-install   Build ./build/BO3 Mac.app without copying to /Applications
  --allow-unverified   Proceed even if CoDBlkOps3_Exe SHA-256 differs from stock Steam macOS v98
  --help               Show this help
EOF
}

step() { printf '\n\033[1;33m[%s]\033[0m %s\n' "$1" "$2"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$1"; }
warn() { printf '\033[0;33m  ! %s\033[0m\n' "$1"; }
die()  { printf '\033[0;31mError: %s\033[0m\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --game-dir)
            [ "$#" -ge 2 ] || die "--game-dir requires a folder path"
            shift
            export BO3_GAME_DIR="$1"
            ;;
        --cache-dir)
            [ "$#" -ge 2 ] || die "--cache-dir requires a folder path"
            shift
            export BO3MAC_CACHE_DIR="$1"
            ;;
        --no-crossplay)     CROSSPLAY=0 ;;
        --rebuild)          REBUILD=1 ;;
        --skip-app-install) INSTALL_APP=0 ;;
        --allow-unverified) ALLOW_UNVERIFIED=1 ;;
        --help)             usage; exit 0 ;;
        *)                  die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

echo "======================================================================"
echo "  bo3mac — Native Apple Silicon Installer for Black Ops III"
echo "  Zero Rosetta 2 • Direct Metal • MetalFX • Live F10 / ⌘, Settings"
echo "======================================================================"

# 1. Verify Apple Silicon + Xcode Command Line Tools
step "1/7" "Checking Apple Silicon hardware and macOS developer tools..."
ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || die "bo3mac requires an Apple Silicon (arm64) Mac (detected: $ARCH)."

if ! command -v clang >/dev/null 2>&1 || ! command -v clang++ >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
    warn "Apple Xcode Command Line Tools are not installed yet."
    echo "    Opening Apple's installer prompt now..."
    xcode-select --install 2>/dev/null || true
    die "Finish installing Command Line Tools, then re-run ./install.sh"
fi
command -v python3 >/dev/null 2>&1 || die "python3 not found (install Xcode Command Line Tools)."
command -v curl >/dev/null 2>&1 || die "curl not found."

CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
MCPU="$(python3 "$ROOT/tools/bo3_paths.py" --mcpu)"
WORKERS="$(python3 "$ROOT/tools/bo3_paths.py" --workers)"
CACHE_DIR="$(python3 "$ROOT/tools/bo3_paths.py" --cache-dir)"
mkdir -p "$CACHE_DIR"
ok "Detected: $CHIP (clang target: -mcpu=$MCPU, $WORKERS parallel workers)"
ok "Build cache: $CACHE_DIR"

# 2. Locate user's Steam installation of Call of Duty: Black Ops III
step "2/7" "Locating your Steam installation of Call of Duty: Black Ops III..."
GAME_DIR="$(python3 "$ROOT/tools/bo3_paths.py" --game-dir 2>/dev/null || true)"
if [ -z "$GAME_DIR" ]; then
    warn "Could not auto-detect Black Ops III in standard Steam libraries."
    if [ -t 0 ]; then
        printf "    Drag & drop your \"Call of Duty Black Ops III\" folder here and press Enter: "
        read -r USER_DIR
        USER_DIR="$(python3 -c 'import shlex, sys
s = sys.argv[1].strip()
try:
    parts = shlex.split(s)
    print(parts[0].rstrip("/") if parts else s.rstrip("/"))
except ValueError:
    print(s.strip("\"\x27").rstrip("/"))' "$USER_DIR")"
        export BO3_GAME_DIR="$USER_DIR"
        GAME_DIR="$(python3 "$ROOT/tools/bo3_paths.py" --game-dir 2>/dev/null || true)"
    fi
fi
[ -n "$GAME_DIR" ] || die "Could not find CoDBlkOps3.app. Install Black Ops III via Steam first, or pass --game-dir <path>."
export BO3_GAME_DIR="$GAME_DIR"
BO3_EXE="$GAME_DIR/CoDBlkOps3.app/Contents/MacOS/CoDBlkOps3_Exe"
ok "Found Steam BO3: $GAME_DIR"

EXE_SHA="$(shasum -a 256 "$BO3_EXE" | awk '{print $1}')"
if [ "$EXE_SHA" != "$STOCK_SHA256" ]; then
    if [ "$ALLOW_UNVERIFIED" -ne 1 ]; then
        die "CoDBlkOps3_Exe SHA-256 mismatch (got $EXE_SHA, expected stock Steam macOS v98 $STOCK_SHA256). Run Steam -> Properties -> Installed Files -> Verify integrity of game files, then retry."
    fi
    warn "Proceeding with unverified CoDBlkOps3_Exe (--allow-unverified); disabling cross-play patch."
    CROSSPLAY=0
else
    ok "Verified stock Steam macOS CoDBlkOps3_Exe (SHA-256 match)"
fi

# 3. Fetch, verify SHA-256 & atomically compile MIT-licensed Zydis disassembler (no Homebrew required)
step "3/7" "Preparing Zydis ${ZYDIS_VERSION} x86_64 decoder (MIT license)..."
ZYDIS_DIR="$(python3 "$ROOT/tools/bo3_paths.py" --zydis-dir)"
mkdir -p "$ZYDIS_DIR"
ZYDIS_STAMP="$ZYDIS_DIR/.zydis_stamp"
NEED_ZYDIS=0
if [ ! -f "$ZYDIS_DIR/amalgamated-dist/Zydis.h" ] || [ ! -f "$ZYDIS_DIR/amalgamated-dist/Zydis.c" ] || [ ! -f "$ZYDIS_DIR/Zydis.o" ] ||
   [ ! -f "$ZYDIS_STAMP" ] || [ "$(cat "$ZYDIS_STAMP" 2>/dev/null || true)" != "${ZYDIS_VERSION}:${ZYDIS_SHA256}" ]; then
    NEED_ZYDIS=1
fi
if [ "$NEED_ZYDIS" -eq 1 ] || [ "$REBUILD" -eq 1 ]; then
    if [ ! -f "$ZYDIS_DIR/amalgamated-dist/Zydis.h" ] || [ ! -f "$ZYDIS_DIR/amalgamated-dist/Zydis.c" ] ||
       [ ! -f "$ZYDIS_STAMP" ] || [ "$(cat "$ZYDIS_STAMP" 2>/dev/null || true)" != "${ZYDIS_VERSION}:${ZYDIS_SHA256}" ]; then
        echo "    Downloading and verifying Zydis ${ZYDIS_VERSION} amalgamated source..."
        STAGE_Z="$(mktemp -d "$ZYDIS_DIR/.zydis_stage.XXXXXX")"
        TMP_CLEANUP+=("$STAGE_Z")
        curl -fSL "$ZYDIS_URL" -o "$STAGE_Z/zydis.tar.gz"
        GOT_ZSHA="$(shasum -a 256 "$STAGE_Z/zydis.tar.gz" | awk '{print $1}')"
        [ "$GOT_ZSHA" = "$ZYDIS_SHA256" ] || die "Zydis archive SHA-256 mismatch (got $GOT_ZSHA, expected $ZYDIS_SHA256)"
        tar -xzf "$STAGE_Z/zydis.tar.gz" -C "$STAGE_Z"
        if [ -f "$STAGE_Z/amalgamated-dist/Zydis.h" ]; then
            SRC_Z="$STAGE_Z/amalgamated-dist"
        elif [ -f "$STAGE_Z/Zydis.h" ]; then
            SRC_Z="$STAGE_Z"
        else
            die "Unexpected Zydis archive layout"
        fi
        rm -rf "$ZYDIS_DIR/amalgamated-dist"
        mv "$SRC_Z" "$ZYDIS_DIR/amalgamated-dist"
        rm -f "$ZYDIS_DIR/Zydis.o" "$ROOT/build/bo3_lift"
    fi
    echo "    Compiling Zydis.o..."
    TMP_ZOBJ="$ZYDIS_DIR/Zydis.o.tmp.$$"
    TMP_CLEANUP+=("$TMP_ZOBJ")
    clang -arch arm64 -mmacosx-version-min=13.0 -O3 -DNDEBUG -I"$ZYDIS_DIR/amalgamated-dist" \
        -c "$ZYDIS_DIR/amalgamated-dist/Zydis.c" -o "$TMP_ZOBJ"
    mv -f "$TMP_ZOBJ" "$ZYDIS_DIR/Zydis.o"
    rm -f "$ROOT/build/bo3_lift"
    printf '%s\n' "${ZYDIS_VERSION}:${ZYDIS_SHA256}" > "$ZYDIS_STAMP"
fi
export BO3MAC_ZYDIS_DIR="$ZYDIS_DIR"
ok "Zydis ready ($ZYDIS_DIR/Zydis.o)"

# 4. Build native bo3_lift & bo3_loader
step "4/7" "Building native ARM64 lifter (bo3_lift) and loader (bo3_loader)..."
make -C "$ROOT" -j"$WORKERS" CACHE_DIR="$CACHE_DIR" ZYDIS_DIR="$ZYDIS_DIR" MCPU="$MCPU" all
ok "Built build/bo3_lift and build/bo3_loader"

# 5. Recompile Black Ops III x86_64 engine into native Apple Silicon ARM64 shards
step "5/7" "Recompiling Black Ops III into native $MCPU ARM64 machine code (this takes ~2–4 minutes)..."
SHARDS_DIR="$CACHE_DIR/core_shards"
BUILD_STAMP="$CACHE_DIR/.build_stamp"
LIFTER_SHA="$(shasum -a 256 "$ROOT/build/bo3_lift" | awk '{print $1}' | cut -c1-16)"
CLANG_ID="$(clang --version | head -n 1 | shasum -a 256 | awk '{print $1}' | cut -c1-12)"
WANT_STAMP="exe=${EXE_SHA} mcpu=${MCPU} lifter=${LIFTER_SHA} clang=${CLANG_ID} crossplay=${CROSSPLAY} workshop=1"
CUR_STAMP=""
[ -f "$BUILD_STAMP" ] && CUR_STAMP="$(cat "$BUILD_STAMP" 2>/dev/null || true)"

EXISTING_SHARDS=0
if [ -d "$SHARDS_DIR" ]; then
    EXISTING_SHARDS="$(find "$SHARDS_DIR" -maxdepth 1 -name 'shard_*.o' | wc -l | tr -d ' ')"
fi

NEED_FULL_SHARDS=0
if [ "$REBUILD" -eq 1 ] || [ "$EXISTING_SHARDS" -lt 81 ] || [ -z "$CUR_STAMP" ] ||
   ! printf '%s' "$CUR_STAMP" | grep -q "exe=${EXE_SHA} mcpu=${MCPU} lifter=${LIFTER_SHA} clang=${CLANG_ID} " ||
   { [ "$EXE_SHA" != "$STOCK_SHA256" ] && ! printf '%s' "$CUR_STAMP" | grep -q "workshop=1"; }; then
    NEED_FULL_SHARDS=1
fi

if [ "$NEED_FULL_SHARDS" -eq 1 ]; then
    rm -rf "$SHARDS_DIR" "$CACHE_DIR/m2_gen" "$CACHE_DIR/rt_objs" "$BUILD_STAMP"
    BO3MAC_CACHE_DIR="$CACHE_DIR" BO3MAC_MCPU="$MCPU" \
        python3 "$ROOT/tools/build_shards.py" 80 "$WORKERS" strict -O2
    ok "All 81 ARM64 engine shards built for $MCPU"
else
    ok "Reusing existing $EXISTING_SHARDS ARM64 shards in $SHARDS_DIR (pass --rebuild to recompile)"
fi

if [ "$CROSSPLAY" -eq 1 ]; then
    if [ "$CUR_STAMP" != "$WANT_STAMP" ] || [ "$NEED_FULL_SHARDS" -eq 1 ]; then
        echo "    Applying Workshop/Custom-Map & Windows v100 cross-play shards (never touches Steam files)..."
        rm -f "$BUILD_STAMP"
        BO3MAC_CACHE_DIR="$CACHE_DIR" BO3MAC_MCPU="$MCPU" \
            python3 "$ROOT/tools/apply_crossplay_shards.py" apply
    fi
    ok "Workshop/Custom-Map & Windows v100 cross-play shards ready"
elif [ "$EXE_SHA" = "$STOCK_SHA256" ] && { [ "$CUR_STAMP" != "$WANT_STAMP" ] || [ "$NEED_FULL_SHARDS" -eq 1 ]; }; then
    rm -f "$BUILD_STAMP"
    if [ "$NEED_FULL_SHARDS" -eq 1 ]; then
        echo "    Applying Workshop/Custom-Map shards for stock v98 (--no-crossplay)..."
        BO3MAC_CACHE_DIR="$CACHE_DIR" BO3MAC_MCPU="$MCPU" \
            python3 "$ROOT/tools/apply_crossplay_shards.py" workshop
    else
        echo "    Reverting cross-play shards to stock v98 while keeping Workshop/Custom-Map support..."
        BO3MAC_CACHE_DIR="$CACHE_DIR" BO3MAC_MCPU="$MCPU" \
            python3 "$ROOT/tools/apply_crossplay_shards.py" revert
    fi
    ok "Stock v98 + Workshop/Custom-Map shards ready"
fi
printf '%s\n' "$WANT_STAMP" > "$BUILD_STAMP"

# 6. Link optimized release libbo3_recomp.dylib
step "6/7" "Compiling Direct Metal renderer, audio, input, Steam bridge & linking libbo3_recomp.dylib..."
BO3MAC_CACHE_DIR="$CACHE_DIR" BO3MAC_MCPU="$MCPU" bash "$ROOT/tools/build_m3.sh"
ok "Linked $CACHE_DIR/libbo3_recomp.dylib"

# Save detected game_dir and cache_dir into settings.ini (locked, PID-unique atomic temp file;
# runtime auto-tuner still applies optimal graphics settings if graphics keys aren't present yet!)
SETTINGS_DIR="$HOME/Library/Application Support/bo3mac"
SETTINGS_FILE="$SETTINGS_DIR/settings.ini"
mkdir -p "$SETTINGS_DIR"
python3 - "$SETTINGS_DIR" "$SETTINGS_FILE" "$GAME_DIR" "$CACHE_DIR" <<'PYEOF'
import fcntl, os, sys
sdir, path, gdir, cdir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lock_fd = os.open(os.path.join(sdir, ".settings.lock"), os.O_RDWR | os.O_CREAT, 0o644)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    lines = []
    has_g = has_c = False
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("game_dir="):
                    lines.append(f"game_dir={gdir}\n")
                    has_g = True
                elif line.startswith("cache_dir="):
                    lines.append(f"cache_dir={cdir}\n")
                    has_c = True
                else:
                    lines.append(line)
    if not has_g:
        lines.append(f"game_dir={gdir}\n")
    if not has_c:
        lines.append(f"cache_dir={cdir}\n")
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.writelines(lines)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
PYEOF

# 7. Build & install BO3 Mac.app
step "7/7" "Building double-clickable BO3 Mac.app launcher..."
BO3MAC_CACHE_DIR="$CACHE_DIR" BO3MAC_MCPU="$MCPU" bash "$ROOT/tools/build_app.sh" "$ROOT/build/BO3 Mac.app"

INSTALLED_APP="$ROOT/build/BO3 Mac.app"
if [ "$INSTALL_APP" -eq 1 ]; then
    if [ -w "/Applications" ]; then
        rm -rf "$APP_DEST"
        cp -R "$ROOT/build/BO3 Mac.app" "$APP_DEST"
        INSTALLED_APP="$APP_DEST"
        ok "Installed to $APP_DEST"
    else
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/BO3 Mac.app"
        cp -R "$ROOT/build/BO3 Mac.app" "$HOME/Applications/BO3 Mac.app"
        INSTALLED_APP="$HOME/Applications/BO3 Mac.app"
        ok "Installed to $INSTALLED_APP"
    fi
fi

echo ""
echo "======================================================================"
echo "  Installation Complete!"
echo "======================================================================"
echo "  • Open Steam (for online co-op/Zombies), then double-click:"
echo "      $INSTALLED_APP"
echo "  • Optimal graphics settings were automatically tuned for your $CHIP."
echo "  • Press F10 (fn+F10 on Mac keyboards) or Cmd+, anytime in-game to"
echo "    tweak MetalFX, Lossy RT, Frame Latency, HUD, or Friends-Only live!"
echo "======================================================================"
