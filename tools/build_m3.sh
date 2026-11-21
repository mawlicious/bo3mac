#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$(python3 "$ROOT/tools/bo3_paths.py" --cache-dir)"
MCPU="$(python3 "$ROOT/tools/bo3_paths.py" --mcpu)"
RT="$CACHE/rt_objs"
GEN="$CACHE/m2_gen"
mkdir -p "$RT"

# Generate M2 symbol registry & weak Aspyr stubs if missing (first-time setup on a fresh Mac)
if [ ! -f "$GEN/gen_registry.c" ] || [ ! -f "$GEN/gen_extra_reg.c" ] || [ ! -f "$GEN/gen_binds.c" ] || [ ! -f "$GEN/gen_aspyr_weak.c" ]; then
    echo "[build_m3] Generating symbol registry and bind tables..."
    python3 "$ROOT/tools/gen_m2_glue.py"
fi

# Release optimization flags (-O3 -DNDEBUG -mcpu=$MCPU, macOS 13.0+ ABI) for minimum runtime overhead
MINOS="-mmacosx-version-min=13.0"
CFLAGS=(-arch arm64 -mcpu="$MCPU" "$MINOS" -O3 -DNDEBUG -Wall -Wextra -I"$ROOT/runtime" -I"$ROOT/metal")
CXXFLAGS=(-arch arm64 -mcpu="$MCPU" "$MINOS" -std=c++20 -O3 -DNDEBUG -Wall -Wextra -Wno-unused-parameter -I"$ROOT/runtime" -I"$ROOT/metal")
MMFLAGS=(-arch arm64 -mcpu="$MCPU" "$MINOS" -std=c++20 -O3 -DNDEBUG -Wall -Wextra -Wno-unused-parameter -fobjc-arc -I"$ROOT/runtime" -I"$ROOT/metal")

echo "[build_m3] Compiling runtime C/C++/ASM shims (target: $MCPU)..."
clang -arch arm64 "$MINOS" -c "$ROOT/runtime/setjmp_arm64.S" -o "$RT/setjmp_arm64.o"
clang++ "${CXXFLAGS[@]}" -c "$ROOT/runtime/shim_libcxx.cpp" -o "$RT/shim_libcxx.o"
clang "${CFLAGS[@]}" -c "$ROOT/runtime/runtime_core.c" -o "$RT/runtime_core.o"
clang "${CFLAGS[@]}" -c "$ROOT/runtime/shim_libsystem.c" -o "$RT/shim_libsystem.o"
clang "${CFLAGS[@]}" -c "$ROOT/runtime/shim_aspyr_os.c" -o "$RT/shim_aspyr_os.o"
clang "${CFLAGS[@]}" -c "$ROOT/runtime/shim_aspyr_win32.c" -o "$RT/shim_aspyr_win32.o"
clang "${CFLAGS[@]}" -c "$ROOT/runtime/shim_curl_zlib_steam.c" -o "$RT/shim_curl_zlib_steam.o"
clang "${CFLAGS[@]}" -c "$ROOT/runtime/steam_bridge.c" -o "$RT/steam_bridge.o"

# Compile generated M2 glue objects if missing or newer than .o
for gf in gen_aspyr_weak gen_binds gen_registry gen_extra_reg; do
    if [ ! -f "$RT/${gf}.o" ] || [ "$GEN/${gf}.c" -nt "$RT/${gf}.o" ]; then
        echo "[build_m3] Compiling ${gf}.c..."
        clang -arch arm64 "$MINOS" -O2 -DNDEBUG -I"$ROOT/runtime" -c "$GEN/${gf}.c" -o "$RT/${gf}.o"
    fi
done

echo "[build_m3] Compiling Direct Metal backend (metal/*.mm) + DXBC->MSL + settings UI + media/audio/gamepad..."
for f in com_thunks formats settings_mac window_mac dxgi_metal shader_cache d3d11_device d3d11_context; do
    clang++ "${MMFLAGS[@]}" -c "$ROOT/metal/${f}.mm" -o "$RT/metal_${f}.o"
done
for f in dxbc_program dxbc_to_msl; do
    clang++ -arch arm64 -mcpu="$MCPU" "$MINOS" -std=c++20 -O3 -DNDEBUG -Wall -Wextra -I"$ROOT/metal" -c "$ROOT/metal/dxbc/${f}.cpp" -o "$RT/dxbc_${f}.o"
done
clang++ "${MMFLAGS[@]}" -c "$ROOT/runtime/media_avf.mm" -o "$RT/runtime_media_avf.o"
clang++ "${MMFLAGS[@]}" -c "$ROOT/runtime/audio_coreaudio.mm" -o "$RT/runtime_audio_coreaudio.o"
clang++ "${MMFLAGS[@]}" -c "$ROOT/runtime/gamepad_mac.mm" -o "$RT/runtime_gamepad_mac.o"

RT_OBJS=(
    "$RT/setjmp_arm64.o"
    "$RT/shim_libcxx.o"
    "$RT/runtime_core.o"
    "$RT/shim_libsystem.o"
    "$RT/shim_aspyr_os.o"
    "$RT/shim_aspyr_win32.o"
    "$RT/shim_curl_zlib_steam.o"
    "$RT/steam_bridge.o"
    "$RT/gen_aspyr_weak.o"
    "$RT/gen_binds.o"
    "$RT/gen_registry.o"
    "$RT/gen_extra_reg.o"
    "$RT/metal_com_thunks.o"
    "$RT/metal_formats.o"
    "$RT/metal_settings_mac.o"
    "$RT/metal_window_mac.o"
    "$RT/metal_dxgi_metal.o"
    "$RT/metal_shader_cache.o"
    "$RT/metal_d3d11_device.o"
    "$RT/metal_d3d11_context.o"
    "$RT/dxbc_dxbc_program.o"
    "$RT/dxbc_dxbc_to_msl.o"
    "$RT/runtime_media_avf.o"
    "$RT/runtime_audio_coreaudio.o"
    "$RT/runtime_gamepad_mac.o"
)

echo "[build_m3] Linking libbo3_recomp.dylib (atomic swap)..."
TMP_DYLIB="$CACHE/libbo3_recomp.dylib.tmp.$$"
trap 'rm -f "$TMP_DYLIB"' EXIT
clang++ -arch arm64 "$MINOS" -dynamiclib \
    "$CACHE"/core_shards/shard_*.o \
    "${RT_OBJS[@]}" \
    -lz -lcurl \
    -framework Metal -framework MetalFX -framework QuartzCore -framework Cocoa -framework CoreGraphics -framework ImageIO \
    -framework AVFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation \
    -framework AudioToolbox -framework CoreAudio -framework GameController -framework CoreHaptics \
    -o "$TMP_DYLIB"
mv -f "$TMP_DYLIB" "$CACHE/libbo3_recomp.dylib"

ls -lh "$CACHE/libbo3_recomp.dylib"
