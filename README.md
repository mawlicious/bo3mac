# bo3mac — Native Apple Silicon Port of Call of Duty: Black Ops III

Play **Call of Duty: Black Ops III** natively on **any Apple Silicon Mac** (**M1, M2, M3, M4, M5, M6+ — Base, Pro, Max, and Ultra**) with **zero Rosetta 2**, a **Direct Metal + MetalFX Spatial** renderer, native **CoreAudio**, native **VideoToolbox** cutscenes, native **GameController** support, and **Steam Online Multiplayer / Zombies**.

> **Ownership & Legal Notice**
> You **must own Call of Duty: Black Ops III on Steam** and have the macOS Steam version installed. This repository contains **zero copyrighted game files, binaries, shaders, or assets** — the installer compiles a native ARM64 runtime locally from your own Steam installation without modifying a single file inside Steam.

---

## Highlights

- **100% Native Apple Silicon (ARM64) — Zero Rosetta 2:** Statically recompiles the macOS x86_64 game engine (`CoDBlkOps3_Exe`) into native ARM64 machine code tuned specifically for your Mac's chip (`-mcpu=apple-m1` / `m2` / `m3` / `m4` / newer).
- **Direct Metal Renderer Built for Apple TBDR GPUs:** Replaces Aspyr's old OpenGL/ASL/SDL2 wrapper with a native Direct3D 11 → Metal backend featuring deferred clears, `MTLStoreActionDontCare` bandwidth elimination, persistent `MTLBinaryArchive` PSO caching, **MetalFX Spatial Upscaling**, and **Apple8+ (M2/M3/M4+) Lossy Render-Target Compression**.
- **Automatic Hardware Tuning:** Automatically detects your Apple Silicon chip tier (Base / Pro / Max / Ultra) and display resolution on first launch and picks optimal graphics settings for smooth 60–120+ FPS gameplay.
- **Edit Settings Live In-Game (No Restart Needed):**
  - Press **`F10`** (`fn + F10` on Mac keyboards using default media keys) or **`⌘,`** (or click **`BO3 Mac → Settings…`** in the macOS menu bar) at any time during gameplay to adjust MetalFX, Lossy RT compression, Max Frame Latency, Performance HUD, and Friends-Only safety guard live.
  - Switch MetalFX Spatial resolutions **directly inside BO3's own Graphics → Display Resolution menu** (native-aspect `75%` and `80%` modes are added automatically alongside native resolution).
- **Simple Double-Click Launcher (`BO3 Mac.app`):** No terminal commands needed after installation — just double-click **`BO3 Mac`** in `/Applications`.
- **Release-Grade Zero-Overhead Runtime:** Compiled with `-O3 -DNDEBUG` with zero developer validation layers, zero background profiling, and zero console log spam during normal play.
- **Online Zombies & Multiplayer Ready:** Connects directly to the native arm64 Steam desktop client with **Friends-Only lobby/P2P protection enabled by default** and Windows v100 cross-play protocol support.

---

## Quick Start (3 Easy Steps)

### Requirements
- Any **Apple Silicon Mac** (`M1`, `M2`, `M3`, `M4`, `M5`, `M6+` — Base, Pro, Max, or Ultra)
- **macOS 13 Ventura or newer** (macOS 14/15+ recommended)
- **Call of Duty: Black Ops III** installed via **Steam** (on your internal SSD or an external drive)
- ~2 GB of temporary free disk space for the one-time ARM64 build cache (`~/Library/Caches/bo3mac`)

### Step 1 — Install Black Ops III in Steam
Open **Steam** on your Mac and install **Call of Duty: Black Ops III** normally. You do not need to launch it through Steam first.

### Step 2 — Run the One-Command Installer
Open the **Terminal** app (`⌘ Space` → type `Terminal` → press Enter) and paste:

```bash
git clone https://github.com/mawlicious/bo3mac.git
cd bo3mac
./install.sh
```

**What `./install.sh` automatically does for you:**
1. Checks your Apple Silicon chip and prompts to install Apple's free Xcode Command Line Tools if you don't have them yet.
2. Automatically finds your Steam installation of Black Ops III (including external SSD Steam libraries).
3. Downloads and compiles the MIT-licensed Zydis disassembler (no Homebrew required).
4. Recompiles your Steam copy of `CoDBlkOps3_Exe` into native ARM64 machine code tuned for your exact Apple Silicon chip (~2–4 minutes on M1–M4; even faster on Pro/Max/Ultra).
5. Builds the optimized release `libbo3_recomp.dylib` and installs **`BO3 Mac.app`** into `/Applications`.

> **Using an external SSD for the build cache?** Pass `--cache-dir /Volumes/YourSSD/bo3mac-cache` to `./install.sh`.

### Step 3 — Play!
1. Make sure the **Steam** desktop app is open and signed in (or check **Offline Mode** in the launcher if playing solo without Steam).
2. Double-click **`BO3 Mac`** in your **Applications** folder (or Spotlight `⌘ Space` → `BO3 Mac`).
3. Click **Play Black Ops III**!

---

## Live In-Game Settings (`F10` or `⌘,`)

You never need to touch Terminal or restart the game to tweak performance settings:

| Setting | Shortcut / Location | Takes Effect | What It Does |
|---|---|---|---|
| **MetalFX Spatial Upscaling** | `F10` / `⌘,` overlay or `BO3 Mac.app` | **Live (next frame)** | Uses Apple's hardware-accelerated MetalFX Spatial upscaler whenever the game renders below your display's native resolution. |
| **Display Resolution (`75%` / `80%` / Native)** | **BO3 Graphics → Display Resolution** | **Live (no restart)** | Automatically exposes crisp `75%` and `80%` native-aspect modes (e.g. `1440×810` & `1536×864` on 1080p) that upscale via MetalFX on the fly. |
| **BO3 Render Resolution Slider** | **BO3 Graphics → Render Resolution** | **Live (sharpest menus!)** | Keep Display Resolution at native `100%` and lower BO3's own Render Resolution slider to `75–85%` if you want **razor-sharp 2D menus & text** with lower 3D GPU load. |
| **Startup Display Scale (`50–100%`)** | `F10` / `⌘,` overlay or `BO3 Mac.app` | Next launch | Scales the virtual display reported at startup (useful for locked-60 FPS on fanless MacBook Airs / M1 Base). |
| **Lossy Render-Target Compression** | `F10` / `⌘,` overlay or `BO3 Mac.app` | New render targets / map load | Uses Apple8+ (M2/M3/M4+) hardware lossy compression on large intermediate render targets to cut memory bandwidth and heat. |
| **Max Frame Latency (`Auto / 1 / 2 / 3`)** | `F10` / `⌘,` overlay or `BO3 Mac.app` | **Live (next frame)** | Caps frames-in-flight (`2` gives snappier mouse aim with zero stutter; `1` is lowest input lag; `3` is max throughput). |
| **Performance HUD (`Off / FPS / Detailed`)** | `F10` / `⌘,` overlay or `BO3 Mac.app` | **Live (instant)** | Clean click-through corner overlay showing FPS, active resolution, MetalFX status, and (in Detailed mode) live GPU ms, CPU encode ms, and TBDR bandwidth. Zero overhead when `Off`. |
| **Friends-Only Lobby Guard** | `F10` / `⌘,` overlay or `BO3 Mac.app` | **Live (instant)** | Forces all new lobbies to Friends-Only and blocks unsolicited non-friend P2P session requests, P2P packets, and IM messages (recommended ON for BO3 online safety). |

All settings are shared and saved automatically to `~/Library/Application Support/bo3mac/settings.ini`. Click **Reset Recommended** anytime to restore the optimal defaults for your Mac.

---

## Automatic Apple Silicon Hardware Profiles

On first launch, `bo3mac` inspects your Metal GPU and monitor resolution and applies a tuned baseline automatically:

| Apple Silicon Tier | 1080p Display | 1440p Display | 4K / Retina Display | Lossy RT | Frame Latency |
|---|---|---|---|---|---|
| **M1 Base** (7–8c GPU) | MetalFX 75% | MetalFX 67% | MetalFX 67% | Off (Apple7) | 2 |
| **M2 / M3 / M4 Base** (8–10c GPU) | MetalFX 80% | MetalFX 75% | MetalFX 70% | **On** | 2 |
| **M1 / M2 / M3 / M4 Pro** (14–20c GPU) | Native 100% | Native 100% | MetalFX 85% | **On** (M2+) | 2 |
| **Max / Ultra** (24–80+c GPU) | Native 100% | Native 100% | Native 100% | Off (Lossless) | 2 |
| **M5 / M6+ Base & Pro** | Native 100% | Native 100% | MetalFX 85% | **On** | 2 |

### Verified Benchmark (Apple M4 Base 10-Core GPU, 1080p)
Measured over a 10-minute sustained **Shadows of Evil Round 15** stress test (Shadow Man Easter Egg, 32,880 frames):
- **Average FPS:** `60.5 FPS` (locked to 60 Hz display; `53.9 FPS` worst-case during 4,069-draw-call zombie hordes)
- **GPU Frame Time:** `15.05 ms` average
- **TBDR Memory Traffic:** `308 MB load / 324 MB store` per frame (**-48%** vs pre-TBDR baseline)
- **Thermal Stability:** Zero thermal throttling over sustained 10-minute gameplay

---

## Online Multiplayer, Zombies & Cross-Play

- **Steam Online:** Open the Steam desktop app before launching `BO3 Mac.app`. You can invite and join Steam friends normally in Zombies and Multiplayer.
- **Friends-Only Safety Guard (ON by default):** Protects your session from uninvited non-friend lobby joins and P2P packets. Uncheck it in `BO3 Mac.app` or press `F10` in-game if you intentionally want to join a public lobby.
- **Windows Cross-Play:** `./install.sh` applies the 28 verified protocol/changelist/timeout adjustments during local ARM64 compilation (never modifying Steam's binary) so macOS clients speak Windows v100 wire protocol. If you also have Windows v100 zone patch fastfiles (`core_patch.ff`, `mp_patch.ff`, `zm_patch.ff`), place them in `~/Library/Application Support/bo3mac/zone/` (or set `BO3MAC_ZONE_OVERLAY_DIR`) for read-only overlay mounting without touching Steam's files.
- **Offline Solo Mode:** Toggle **Offline Mode** in `BO3 Mac.app` (or pass `--offline` via CLI) to play solo Zombies or Campaign without running Steam.

---

## FAQ & Troubleshooting

<details>
<summary><b>"Command Line Tools not installed" during ./install.sh</b></summary>

Click **Install** in the macOS popup that appears (it installs Apple's official `clang` compiler, ~700 MB, no full Xcode needed). Once it finishes, run `./install.sh` again.
</details>

<details>
<summary><b>My Steam library is on an external SSD and wasn't detected</b></summary>

Either pass `--game-dir "/Volumes/YourDrive/.../Call of Duty Black Ops III"` to `./install.sh`, or click **Locate Game…** inside `BO3 Mac.app` and pick the `Call of Duty Black Ops III` folder.
</details>

<details>
<summary><b>Controller / Gamepad Support</b></summary>

PlayStation (DualSense / DualShock 4), Xbox, and MFi controllers work natively via Apple's `GameController` framework with rumble/haptics. Connect via Bluetooth or USB before or during gameplay.
</details>

<details>
<summary><b>Where are settings, shader caches, and logs stored?</b></summary>

- **Settings:** `~/Library/Application Support/bo3mac/settings.ini`
- **Build & Shader PSO Cache:** `~/Library/Caches/bo3mac` (or your custom `--cache-dir`)
- **Logs:** `~/Library/Logs/bo3mac.log` (or click **Open Logs** in `BO3 Mac.app`)
- **Offline Save Data:** `~/Library/Application Support/Call of Duty Black Ops III/bo3arm_remote_storage`
</details>

<details>
<summary><b>How do I uninstall completely?</b></summary>

Delete `/Applications/BO3 Mac.app`, `~/Library/Caches/bo3mac`, `~/Library/Application Support/bo3mac`, and the cloned `bo3mac` repo folder. Your Steam installation of Black Ops III is never touched.
</details>

---

## Power-User CLI & Developer Architecture

Advanced users and contributors can also launch directly from the terminal with `tools/run_bo3.sh`:

```bash
bash tools/run_bo3.sh --help
bash tools/run_bo3.sh --hud 1 --latency 2
bash tools/run_bo3.sh --scale 80 --lossy-rt --perf   # developer telemetry log
bash tools/run_bo3.sh --debug                         # Metal validation layer
```

For deep technical documentation on the zero-slide Mach-O loader, Zydis → LLVM IR static lifter, `libc++` x86_64↔arm64 ABI bridge, Direct3D 11 → Metal TBDR frame graph, DXBC → MSL translator, and native Steamworks bridge, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## License

Released under the [MIT License](LICENSE). Uses [Zydis](https://github.com/zyantific/zydis) (MIT License) during local compilation.
