#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MCPU="$(python3 "$ROOT/tools/bo3_paths.py" --mcpu)"
APP_OUT="${1:-$ROOT/build/BO3 Mac.app}"
LOADER_BIN="$ROOT/build/bo3_loader"

if [ ! -x "$LOADER_BIN" ]; then
    echo "[build_app] Building bo3_loader..."
    make -C "$ROOT" build/bo3_loader
fi

case "$APP_OUT" in
    *.app) ;;
    *) echo "Error: output path must end in .app (got: $APP_OUT)" >&2; exit 1 ;;
esac

echo "[build_app] Creating app bundle at: $APP_OUT"
rm -rf "$APP_OUT"
mkdir -p "$APP_OUT/Contents/MacOS" "$APP_OUT/Contents/Resources"

echo "[build_app] Compiling BO3MacLauncher (arm64, $MCPU, -O3 -DNDEBUG)..."
clang++ -arch arm64 -mcpu="$MCPU" -mmacosx-version-min=13.0 -std=c++20 -O3 -DNDEBUG -Wall -Wextra -fobjc-arc \
    "$ROOT/launcher/BO3MacLauncher.mm" \
    -framework Cocoa -framework Metal -framework MetalFX \
    -o "$APP_OUT/Contents/MacOS/BO3MacLauncher"

cp "$LOADER_BIN" "$APP_OUT/Contents/MacOS/bo3_loader"
chmod +x "$APP_OUT/Contents/MacOS/bo3_loader" "$APP_OUT/Contents/MacOS/BO3MacLauncher"

# Generate an original procedural macOS AppIcon.icns (dark obsidian squircle + amber III bars)
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

python3 - "$ICONSET" <<'PYEOF'
import math, os, struct, sys, zlib

out_dir = sys.argv[1]

def write_png(path, w, h, rgba_bytes):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = bytearray()
    row_len = w * 4
    for y in range(h):
        raw.append(0)
        raw.extend(rgba_bytes[y * row_len : (y + 1) * row_len])
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

def render_icon(size):
    buf = bytearray(size * size * 4)
    half = size * 0.5
    rad = size * 0.44
    # Superellipse (macOS squircle) + glowing amber III bars
    for y in range(size):
        ny = (y + 0.5 - half) / rad
        ay = abs(ny)
        for x in range(size):
            nx = (x + 0.5 - half) / rad
            ax = abs(nx)
            sq = (ax ** 4.6) + (ay ** 4.6)
            if sq > 1.08:
                continue
            alpha = 1.0 if sq <= 0.94 else max(0.0, (1.08 - sq) / 0.14)
            # Obsidian radial gradient background
            dist = math.hypot(nx, ny)
            bg_r = int(20 + 24 * max(0.0, 1.0 - dist * 0.85))
            bg_g = int(19 + 18 * max(0.0, 1.0 - dist * 0.85))
            bg_b = int(22 + 16 * max(0.0, 1.0 - dist * 0.85))
            # Subtle inner rim
            if 0.84 < sq <= 0.96:
                bg_r = min(255, bg_r + 22)
                bg_g = min(255, bg_g + 16)
                bg_b = min(255, bg_b + 10)
            r, g, b = bg_r, bg_g, bg_b
            # Three crisp glowing amber bars ("III")
            if -0.52 <= ny <= 0.52:
                bar_glow = 0.0
                for cx in (-0.34, 0.0, 0.34):
                    dx = abs(nx - cx)
                    if dx <= 0.085:
                        bar_glow = 1.0
                    elif dx <= 0.18:
                        bar_glow = max(bar_glow, (0.18 - dx) / 0.095 * 0.28)
                if bar_glow > 0.0:
                    t = (ny + 0.52) / 1.04
                    fr = 255
                    fg = int(165 - 55 * t)
                    fb = int(30 - 15 * t)
                    r = int(r * (1.0 - bar_glow) + fr * bar_glow)
                    g = int(g * (1.0 - bar_glow) + fg * bar_glow)
                    b = int(b * (1.0 - bar_glow) + fb * bar_glow)
            idx = (y * size + x) * 4
            buf[idx] = r
            buf[idx + 1] = g
            buf[idx + 2] = b
            buf[idx + 3] = int(alpha * 255)
    return buf

for sz in (16, 32, 64, 128, 256, 512):
    px = render_icon(sz)
    write_png(os.path.join(out_dir, f"icon_{sz}x{sz}.png"), sz, sz, px)
    if sz >= 32:
        half = sz // 2
        write_png(os.path.join(out_dir, f"icon_{half}x{half}@2x.png"), sz, sz, px)
PYEOF

if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns "$ICONSET" -o "$APP_OUT/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>BO3 Mac</string>
    <key>CFBundleExecutable</key>
    <string>BO3MacLauncher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.mawlicious.bo3mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BO3 Mac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_OUT" >/dev/null 2>&1 || true
echo "[build_app] Built $APP_OUT successfully!"
