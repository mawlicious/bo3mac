# bo3arm — Native Apple Silicon (ARM64) Static Recompilation & Direct Metal Port of BO3

## Architecture Decision Record (Synthesized from 3-Advisor Review: Codex gpt-6.2-sol, Claude Opus 5.5, Gemini 4 Neon)

### 1. Target Input Binary: Mac `CoDBlkOps3_Exe` (Mach-O x86_64, non-PIE)
- SHA-256: `932f0918fb9871bc625b69a587135a5c2976e9f9e6b7289cfadda8ab996e1cd0`
- Size: 36 MB (`__TEXT` 26.6 MB, `__text` 23.2 MB, `__DATA` 412 MB vmsize / 8 MB file-backed, `__LINKEDIT` 2.8 MB).
- Fixed non-PIE base `0x100000000` (`rebase_size = 0`).
- Zero DRM, zero Arxan, zero self-modifying code.
- Complete `LC_FUNCTION_STARTS` (59,804 functions; 5,141,049 instructions) and `LC_DATA_IN_CODE` (1,015 `DICE_KIND_JUMP_TABLE32` entries).
- Clean ISA: 0 AVX-512, 0 FMA, 0 `CMPXCHG16B`, 0 `SYSCALL`, 0 real `FS:`/`GS:`, 39 x87; all 16,797 AVX/AVX2 ops are localized inside static FFmpeg `libavcodec` (`+3MB..+4MB`) behind `CPUID` dispatch.
- Clean module split: Aspyr ASL (D3D11→Metal/GL, DXBC→MSL, Win32 shims, Audio) + SDL2 live in `[0x100002100, 0x100250000)` and are replaced cleanly at the engine boundary.

### 2. Memory & Pointer Model: Model 0 / Model C (Zero-Slide 1:1 Identity Arena)
- `loader/bo3_loader` (~34 KB native arm64 Mach-O) reserves `[0x100008000, 0x11a608000)` via zerofill `__DATA,__bss` (0 bytes on disk).
- On startup, if `_dyld_get_image_vmaddr_slide(0) != 0`, self-re-execs with `POSIX_SPAWN_SETEXEC | _POSIX_SPAWN_DISABLE_ASLR` (preserving PID for Steam).
- Copies original `__TEXT` (from `0x100008000`), `__DATA`, and `__LINKEDIT` 1:1 into their exact original virtual addresses; `mprotect`s guest `__TEXT` to `PROT_READ` (non-executable hardware tripwire against unwrapped native→guest callbacks).
- Loads compiled engine `libbo3_recomp.dylib` cleanly above `0x11a608000`.
- Verified: 20/20 cold launches `slide=0`, `proc_translated=0`, SHA-256 bit-exact match, 10,000 `mmap(NULL)` + `malloc` calls have 0 overlaps with `[0x100000000, 0x11a600000)`, 0 engine RIP-relative refs in `(0x100000000, 0x100008000)`.
- Lifter abstracts guest memory accesses behind an inlineable IR helper so Model A′ (`-pagezero_size 0x11a600000` + branchless `xlat`) remains a single-flag fallback.

### 3. Static Recompiler (Custom x86_64 → LLVM IR → Apple Clang 21 M4 ARM64)
- **Decoder:** Zydis C amalgamation (exact per-operand explicit+implicit register and flag read/write metadata).
- **Backend:** Apple Xcode Clang 21 (`clang -arch arm64 -mcpu=apple-m4 -O2 -x ir`) — emits native M4 `LDAPR`/`STLR`, LSE atomics, and NEON directly with zero Homebrew LLVM dependency.
- **Calling Convention (Superset-SysV):**
  ```llvm
  %ret_t = type { i64, i64, <2 x i64>, <2 x i64> }
  define %ret_t @g_XXXX(ptr %ctx, i64 %rsp, i64 %rdi, i64 %rsi, i64 %rdx, i64 %rcx, i64 %r8, i64 %r9,
                        <2 x i64> %xmm0, ..., <2 x i64> %xmm7)
  ```
  Maps 1:1 onto ARM64 `x0..x7` + `v0..v7` with return in `x0, x1, q0, q1` — zero `State` spills on direct calls and universal `musttail` support.
- **Guest Stack:** Dedicated 8 MiB guarded per-thread guest stack (`%rsp`); native ARM64 `sp` belongs solely to LLVM.
- **Flags & Semantics:** Per-function backward flag liveness + lazy flag materialization; explicit masking for x86 shift counts, `bsf`/`bsr` zero-preservation, `cvtt*2si` integer-indefinite `0x80000000`, `min`/`max` NaN operand order, `pause`→`isb`, `xchg` implicit lock.
- **Memory Ordering (x86 TSO on ARM64):** Non-stack, non-RO scalar accesses default to `load atomic acquire` (`LDAPR`) / `store atomic release` (`STLR`) with alignment safety; `LOCK` ops + `xchg mem` → `seq_cst` LSE atomics; relaxed only via verified allowlists in M5.
- **Control Flow:** 1,015 DICE jump tables → native LLVM `switch`; 20,608 indirect calls → monomorphic inline cache + 2-level page table / perfect hash over all 59,804 starts (not `pc>>4`, since 44,376 starts are unaligned).
- **Oracle:** Automated Rosetta 2 x86_64 vs lifted ARM64 differential fuzzer verifying every mnemonic and real BO3 leaf functions bit-for-bit.

### 4. Native Runtime & ABI Interop
- **`libc++` ABI catch (verified empirically):** macOS arm64 uses `_LIBCPP_ABI_ALTERNATE_STRING_LAYOUT` (length in byte 23, `data()` at offset 0), whereas macOS x86_64 uses standard layout (length in byte 0, `data()` at offset 1). Guest `std::string`/`std::wstring` (only 15 methods imported by engine) MUST use x86_64-layout native shims — never forward raw to arm64 `libc++.1.dylib`!
- **`pthread_mutex_t`/`pthread_cond_t`/`std::vector`:** Verified bit-for-bit identical in size, alignment, and static initializer bytes on macOS 27.3 x86_64 vs arm64.
- **`setjmp`/`longjmp` (19/7 engine sites):** Guest `jmp_buf` is 148 B vs arm64 192 B → side-table keyed by `(thread, guest_jmp_buf*)` storing native `sigjmp_buf` + guest registers.
- **Variadics (`printf`/`snprintf`/`sscanf`/`curl_easy_setopt`/`fcntl`/`ioctl`):** Dedicated SysV x86_64 `va_list` decoder / typed adapters.
- **`__thread_vars` (28 TLS vars):** Pattern-matched TLV thunks backed by a single native `pthread_key_t` initialized from `[__thread_data | __thread_bss]`.
- **Steam:** Native arm64 `steamclient.dylib` is present on macOS; offline stub in M2–M3, real native `ISteam*` proxy vtables + `CCallbackBase` trampolines in M4.

### 5. Direct Metal Renderer (Replacing Aspyr ASL & SDL2)
- Cut immediately at the engine↔ASL seam (10 direct graphics entry points + COM `ID3D11Device`/`ID3D11DeviceContext`/`IDXGISwapChain` vtables + ~225 Win32/OS/Audio shims; zero SDL2, zero OpenGL, zero Aspyr Objective-C).
- Deferred per-frame command-list recording with automatic `MTLLoadActionClear`/`DontCare` and `MTLStoreActionDontCare`/`MultisampleResolve`, `MTLStorageModeMemoryless` for transient depth/MSAA, Apple lossless compression preserved (minimal `MTLTextureUsage`), triple-buffered ring buffers for `WRITE_DISCARD`, native BC6H/BC7 3D textures, and persistent `MTLBinaryArchive` PSO cache.
- Cutscene player (`+0x0fb9xxx..+0x0fbaxxx`) replaced natively with `AVAssetReader` + `CVMetalTextureCache`.
- Friends-only Steam lobby/P2P security, Workshop, Windows v100 cross-play, and Havok nav/script fixes integrated natively in C/C++.

## Milestones & Hard Binary Gates
- **M0 (Static Audit & Model 0 Loader):** Verified `bo3_loader` (20/20 zero-slide, SHA-256, 10k mmap disjointness), `libc++` ABI probe, full JSON manifests (`functions`, `dice_jumptables`, `imports`, `seam_edges`, `mod_init_func`, `thread_vars`), and decompiled Aspyr seam & shader format.
- **M1 (Custom Lifter & Rosetta 2 Differential Fuzzer):** Zydis→LLVM IR lifter passing 100% of engine non-AVX mnemonics (100k+ randomized states vs Rosetta 2, 0 bit mismatches) + 100+ real BO3 leaf functions matching Rosetta 2 bit-for-bit + synthetic `setjmp`/EH/callback/TLS fixtures + full sharded engine compile.
- **M2 (Headless Engine Bootstrap):** Native ARM64 `bo3_loader` + `libbo3_recomp.dylib` runs all 709 engine static constructors, mounts `zone/*.ff` fastfiles, runs JQ worker threads, reaches `D3D11CreateDeviceAndSwapChain` with 0 unresolved PCs and 0 NX faults.
- **M3 (Standalone Direct Metal Backend & Interactive Menu):** D3D11 capture/replay + shader translation + deferred frame-graph Metal backend rendering the BO3 interactive menu natively on ARM64 at ≥60 FPS with 0 Metal validation errors and live CoreAudio + input.
- **M4 (Full Native Playable Zombies & Campaign):** Complete D3D11 coverage (compute/UAVs, shadow cascades, BC6H 3D probes), native Steam bridge, native cutscenes, cross-play & security overrides, 30-minute crash-free Zombies soak.
- **M5–M7 (Apple Silicon TBDR, MetalFX, Live Settings & Release Packaging):** Render-target attachment traffic cut ≥50–60% vs Aspyr's baseline, Apple Silicon chip auto-tuning (M1–M6+, Base/Pro/Max/Ultra), MetalFX Spatial upscaling, Apple8+ lossy RT compression, live `F10`/`Cmd+,` in-game settings overlay + HUD, `BO3 Mac.app` launcher, and one-command installer.
