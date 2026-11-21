# Implementation Plan: `5s-browser` (Five-Second HP Atom N550 2GB Appliance Browser)

> **Single Locked Component Matrix (No Alternatives / No Branching):**
> To make end-to-end implementation 100% deterministic for the executing AI model (**Hydrogen**), every hardware and software component is locked to **one single configuration**:
>
> | Component | Locked Single Configuration |
> | :--- | :--- |
> | **Netbook Model** | HP Mini 210-2000 Series (`x86_64`) |
> | **CPU & Threads** | Intel Atom N550 (1.50 GHz, **2 physical cores / 4 threads** `cpu0..cpu3`, 2×512 KB L2 cache) |
> | **Compiler Flags** | `gcc -O2 -march=bonnell -mtune=bonnell -mno-sse4.1 -mno-sse4.2 -mno-avx -Wall -Wextra -Werror -pthread` |
> | **Core Isolation** | **Physical Core 0 (`cpus 0,2`)** = Track A (`cage` + `chromium`); **Physical Core 1 (`cpus 1,3`)** = Track B (`cache_proxy.py` + `5s-net-fast.sh`) |
> | **System RAM & Swap** | **2 GB DDR3** (`2048 MB`) + **512 MB 4-stream LZ4 `zram0`** (`--js-flags=--max-old-space-size=384` per renderer) |
> | **GPU & Display** | Intel GMA 3150 (`8086:a011`, `i915` KMS driver, `LVDS-1` **1024×600** 16-bit RGB565 `/dev/fb0` = `1,228,800` bytes; Chromium `--disable-gpu --disable-gpu-compositing`) |
> | **Storage** | 2.5" SATA II drive on Intel NM10 `ahci` (`/dev/sda1`, `ext4`, `noatime`) |
> | **Wi-Fi NIC & Stack** | Broadcom BCM4313 (`14e4:4727`, `brcmsmac` driver + `firmware-brcm80211`, interface `wlan0`) managed by **`iwd` (`iwctl`) + `dhcpcd -4 -q --noarp wlan0`** |
> | **Base OS & Bootloader** | **Debian 12 (Bookworm) `amd64` Minimal** booted via **GRUB2** (`GRUB_TIMEOUT=0`, `init=/opt/5s-browser/bin/5s-init`) |
> | **Kiosk & Browser** | **`/usr/bin/cage`** Wayland kiosk compositor + **`/usr/bin/chromium`** (standard Debian packages) |
> | **Warm-Start Engine** | **V8 Full Bytecode Cache (`--v8-cache-options=code`) + Persistent Chromium Profile + Local SQLite WAL Proxy (`cache_proxy.py` on `127.0.0.1:8555`)** |
> | **Release Asset Format** | **`dist/5s-browser_0.1.0_amd64.deb`** + **`dist/HOWTO.md`** + **`dist/SHA256SUMS`** |
>
> **Execution Rules for Hydrogen:**
> 1. Execute **Phase 1 through Phase 6** sequentially. Do not implement alternatives or optional branches.
> 2. At the end of each phase, run the **Phase Verification Gate** command and ensure it exits with code `0` before proceeding.
> 3. Every shell script must start with `#!/usr/bin/env bash` and `set -euo pipefail`.
> 4. Support `FB_DEVICE`, `STATE_DIR`, and `MOCK_MODE=1` environment variables so all hardware steps run deterministically inside GitHub Actions CI runners.

---

## Target Repository Structure

When implementation is complete, the repository must match this exact layout:

```text
five-second-browser/
├── .github/
│   └── workflows/
│       ├── ci.yml                     # Push/PR: lint, Bonnell ISA check, unit + <5s E2E tests, .deb verification
│       └── release.yml                # Tag v* / dispatch: builds & attaches 5s-browser_0.1.0_amd64.deb + HOWTO.md
├── Makefile                           # Targets: build, test, package, clean
├── README.md                          # Concept specification (already present)
├── PLAN.md                            # This implementation plan
├── HOWTO.md                           # End-user installation & setup guide for HP Mini Atom N550 (2GB RAM)
├── src/
│   ├── init/
│   │   ├── 5s_fb_splash.c             # Fast mmap 1024x600 RGB565 (1,228,800B) capture (<30ms) & restore (<50ms)
│   │   └── 5s_init.c                  # PID 1 supervisor pinning Core 0 (cpus 0,2) & Core 1 (cpus 1,3)
│   ├── proxy/
│   │   ├── cache_proxy.py             # SQLite WAL offline-first HTTP proxy + SSE delta sync on 127.0.0.1:8555
│   │   └── injected_ui.js             # 24px dual-tab bar (Gmail/YouTube), F1/F2 hotkeys, h264ify <=480p30
│   ├── net/
│   │   └── 5s-net-fast.sh             # Core 1 wlan0 (BCM4313/iwd) fast-connect, cached IP/DNS preload & notify
│   ├── checkpoint/
│   │   ├── 5s-checkpoint.sh           # Shutdown freeze: proxy snapshot + V8 cache sync + FB dump + net state
│   │   └── 5s-browser-launch.sh       # Core 0 launcher: cage + /usr/bin/chromium with GMA 3150 & 2GB RAM flags
│   └── config/
│       ├── grub-5s.cfg                # GRUB2 zero-timeout config for i915 LVDS-1 1024x600 & init=5s-init
│       └── zram-setup.sh              # 512MB 4-stream LZ4 zram0 swap setup for 2GB DDR3 Atom N550
├── scripts/
│   └── build_release.sh               # Builds dist/5s-browser_0.1.0_amd64.deb, dist/HOWTO.md, dist/SHA256SUMS
└── tests/
    ├── run_all.sh                     # Master test runner invoked by Makefile and CI
    ├── test_fb_splash.sh              # 1,228,800-byte framebuffer capture/restore pixel accuracy & <50ms test
    ├── test_init_lifecycle.sh         # Boot ordering, CPU 0,2 vs 1,3 affinity & SIGTERM shutdown test
    ├── test_cache_proxy.py            # Offline SQLite hit (<10ms), h264ify injection & live SSE delta sync test
    ├── test_net_fast.sh               # wlan0 lease reuse, hosts.cache generation & proxy net-online webhook test
    ├── test_checkpoint.sh             # Full shutdown snapshot -> cold boot <5.0s budget verification
    └── test_release_bundle.sh         # Verifies 5s-browser_0.1.0_amd64.deb contents, HOWTO.md & SHA256SUMS
```

---

## Phase 1: GitHub CI/CD Pipeline, Test Harness & Build Skeleton (Execute First)

### Objective
Set up the `Makefile`, master test runner (`tests/run_all.sh`), `.github/workflows/ci.yml`, and `.github/workflows/release.yml` first so every subsequent step is automatically validated and packaged.

### Step 1.1: Create `Makefile`
Create `/Makefile` with:
- `CFLAGS := -O2 -march=bonnell -mtune=bonnell -mno-sse4.1 -mno-sse4.2 -mno-avx -Wall -Wextra -Werror -pthread`
- `build`:
  - Compiles `src/init/5s_fb_splash.c` → `build/bin/5s-fb-splash`
  - Compiles `src/init/5s_init.c` → `build/bin/5s-init`
  - Copies scripts from `src/proxy/`, `src/net/`, `src/checkpoint/`, and `src/config/` into `build/lib/` and `build/bin/` with `chmod +x`.
- `test`: Runs `bash tests/run_all.sh`.
- `package`: Runs `bash scripts/build_release.sh`.
- `clean`: Removes `build/` and `dist/`.

### Step 1.2: Create `.github/workflows/ci.yml`
Runs on every `push` and `pull_request` on `ubuntu-latest`:
1. Install dependencies: `sudo apt-get update && sudo apt-get install -y gcc make python3 lz4 dpkg-dev shellcheck binutils curl`.
2. **Lint:** `shellcheck scripts/*.sh src/*/*.sh tests/*.sh` and `python3 -m py_compile src/proxy/cache_proxy.py tests/test_cache_proxy.py`.
3. **Build & Atom N550 ISA Check:**
   - Run `make build`.
   - Disassemble `build/bin/5s-init` and `build/bin/5s-fb-splash` with `objdump -d` and assert zero occurrences of `SSE4.1`/`SSE4.2`/`AVX` instructions (`pinsrd`, `pmuldq`, `pcmpgtq`, `crc32`, `vmov`).
4. **Test:** Run `make test`.
5. **Package & Verify Release Asset:** Run `make package && bash tests/test_release_bundle.sh`.
6. **Upload Artifacts:** Upload `dist/5s-browser_0.1.0_amd64.deb`, `dist/HOWTO.md`, and `dist/SHA256SUMS` via `actions/upload-artifact@v4`.

### Step 1.3: Create `.github/workflows/release.yml`
Runs on tags matching `v*.*.*` and `workflow_dispatch`:
1. Executes `make build && make test && make package && bash tests/test_release_bundle.sh`.
2. Uses `softprops/action-gh-release@v2` with `body_path: dist/HOWTO.md` to publish:
   - `dist/5s-browser_0.1.0_amd64.deb`
   - `dist/HOWTO.md`
   - `dist/SHA256SUMS`

### Step 1.4: Create `tests/run_all.sh`
- Sequentially runs:
  1. `bash tests/test_fb_splash.sh`
  2. `bash tests/test_init_lifecycle.sh`
  3. `python3 tests/test_cache_proxy.py`
  4. `bash tests/test_net_fast.sh`
  5. `bash tests/test_checkpoint.sh`
  6. `bash tests/test_release_bundle.sh`
- Prints millisecond duration and `[PASS]` / `[FAIL]` for each test.

### Phase 1 Verification Gate
```bash
make build
```

---

## Phase 2: Instant Framebuffer Splash & Dual-Core Init (`5s-fb-splash` & `5s-init`)

### Objective
Restore the exact `1,228,800`-byte (`1024×600` 16-bit RGB565) screen capture to `/dev/fb0` in `< 50 ms` at boot, and split execution across the Atom N550's two physical cores (`cpus 0,2` vs `cpus 1,3`).

### Step 2.1: Implement `src/init/5s_fb_splash.c`
- Fixed default frame size: `#define FRAME_BYTES (1024 * 600 * 2)` (`1,228,800` bytes).
- CLI contract:
  - `5s-fb-splash --capture <file> [--fb <dev>]`: Reads `1,228,800` bytes from `<dev>` (default `getenv("FB_DEVICE")` or `/dev/fb0`) via `mmap` (with `pread` fallback for regular files), writes to `<file>.tmp`, `fsync`s, and atomically `rename`s to `<file>`.
  - `5s-fb-splash --restore <file> [--fb <dev>]`: Opens `<file>` and `<dev>`, copies `1,228,800` bytes directly into the framebuffer via `mmap` (with `pwrite` fallback), and exits `0`.

### Step 2.2: Implement `src/init/5s_init.c`
- CLI contract: `5s-init [--state-dir <dir>] [--test-mode]` (default `<dir>` is `/var/cache/5s`).
- Execution steps:
  1. **System Mounts (when PID == 1 and not `--test-mode`):** Mounts `/proc`, `/sys`, `/dev`, `/run`, remounts `/` and `/var/cache/5s` with `noatime`, and runs `/opt/5s-browser/bin/zram-setup.sh`.
  2. **Instant Visual Restore (t = 0 ms):** Runs `5s-fb-splash --restore <state_dir>/last_frame.fb` synchronously if `<state_dir>/last_frame.fb` exists.
  3. **Track B Spawn (Physical Core 1 — Logical CPUs `1, 3`):**
     - Forks child process, sets `CPU_SET(1, &mask); CPU_SET(3, &mask); sched_setaffinity(...)` (ignoring `EINVAL` on single-core CI VMs).
     - Starts `cache_proxy.py --state-dir <state_dir> --port 8555` and `5s-net-fast.sh --boot --state-dir <state_dir>`.
  4. **Track A Spawn (Physical Core 0 — Logical CPUs `0, 2`):**
     - Forks child process, sets `CPU_SET(0, &mask); CPU_SET(2, &mask); sched_setaffinity(...)`, sets `nice(-10)`.
     - Starts `5s-browser-launch.sh --state-dir <state_dir>`.
  5. **Signal & Shutdown Handling (`SIGTERM` / `SIGINT`):**
     - Invokes `5s-checkpoint.sh --shutdown --state-dir <state_dir>`, waits up to `1,800 ms` for completion, terminates child processes, calls `sync()`, and exits `0`.

### Step 2.3: Implement `tests/test_fb_splash.sh` & `tests/test_init_lifecycle.sh`
- `tests/test_fb_splash.sh`: Creates a `1,228,800`-byte test framebuffer file, runs `--capture` and `--restore`, verifies byte-for-byte identity (`cmp -s`), and asserts both operations finish in `< 50 ms`.
- `tests/test_init_lifecycle.sh`: Runs `5s-init --test-mode --state-dir <tmp>` with `MOCK_MODE=1`, verifies `last_frame.fb` is restored before child hooks complete, sends `SIGTERM`, and asserts `checkpoint.manifest` is written on shutdown.

### Phase 2 Verification Gate
```bash
make build && bash tests/test_fb_splash.sh && bash tests/test_init_lifecycle.sh
```

---

## Phase 3: SQLite WAL Cache Proxy & Atom UI/Media Injector (`cache_proxy.py` & `injected_ui.js`)

### Objective
Serve cached Gmail and YouTube views in `< 10 ms` while offline, provide the 24px dual-tab bar (`F1` Gmail / `F2` YouTube), force H.264 ≤ 480p30 on the Atom N550, and stream background deltas over SSE once `wlan0` connects.

### Step 3.1: Implement `src/proxy/injected_ui.js`
Single self-contained JavaScript payload injected into `/app`:
1. **Atom N550 H.264 ≤ 480p30 Enforcement (`h264ify`):**
   - Overrides `MediaSource.isTypeSupported` and `HTMLMediaElement.prototype.canPlayType` to reject `vp9`, `vp8`, `av01`, and height `> 480`, forcing YouTube to select `avc1` (H.264) 360p/480p30.
2. **Offline Spoofing:**
   - Defines `Object.defineProperty(navigator, 'onLine', { get: () => true })` so Gmail and YouTube render cached content immediately during the 0–5s offline window.
3. **24px Dual-Tab Bar & Hotkeys:**
   - Fixed 24px header at the top of the `1024×600` viewport:
     - Left: `[ ✉ Gmail (F1) ]` and `[ ▶ YouTube (F2) ]` tab buttons. Both panes remain mounted in the DOM so tab switching is instant (`< 5 ms`).
     - Right: Status pill (`● Cached (Connecting...)` → `● Syncing...` → `● Live`).
   - Keyboard listener for `F1` / `Alt+1` (switches to Gmail) and `F2` / `Alt+2` (switches to YouTube).
4. **Live SSE Delta Listener:**
   - Connects to `new EventSource('/__5s__/events')`. When a `delta` event arrives with fresh Gmail inbox items or YouTube feed JSON, patches the DOM in place and sets the status pill to `● Live`.

### Step 3.2: Implement `src/proxy/cache_proxy.py`
Standard-library Python 3 daemon (`http.server.ThreadingHTTPServer` + `sqlite3`) bound to `127.0.0.1:8555`:
1. **SQLite WAL Database (`<state_dir>/http_cache.sqlite`):**
   - Table `cache (url TEXT PRIMARY KEY, status INT, content_type TEXT, body BLOB, updated_at REAL)`.
   - Initialized with `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;` and pre-seeded with the default Gmail & YouTube offline appliance shell if empty.
2. **Routes:**
   - `GET /app`: Returns the 1024×600 dual-tab HTML shell embedding `injected_ui.js` and the latest cached Gmail inbox & YouTube feed snapshot from SQLite (`X-5S-Cache: HIT`).
   - `GET /proxy?url=<url>`:
     - Immediately returns cached row from SQLite (`X-5S-Cache: HIT`) in `< 10 ms`.
     - If online (or on cache miss when online), fetches upstream asynchronously, updates SQLite, and queues an SSE notification.
   - `GET /__5s__/status`: Returns JSON `{"online": bool, "cached_items": int, "last_sync": float}`.
   - `GET /__5s__/events`: Streams `text/event-stream` (`Server-Sent Events`) to the browser tab bar.
   - `POST /__5s__/net-online`: Flips proxy state to `online = True`, immediately revalidates configured upstream URLs in a background thread, and emits `event: delta` to connected SSE clients.
   - `POST /__5s__/snapshot`: Writes the current DOM/JSON state into SQLite and executes `PRAGMA wal_checkpoint(TRUNCATE);` in `< 100 ms`.

### Step 3.3: Implement `tests/test_cache_proxy.py`
1. Starts a local mock upstream server serving Gmail and YouTube test payloads.
2. Starts `cache_proxy.py`, seeds the cache via `/proxy?url=...`, and calls `POST /__5s__/snapshot`.
3. Stops the upstream server and restarts `cache_proxy.py --offline`.
4. Requests `/app` and `/proxy?url=...`, asserting:
   - HTTP 200 with header `X-5S-Cache: HIT`
   - Latency `< 15 ms`
   - Presence of `h264ify` (`vp9`/`av01` rejection) and `F1`/`F2` bindings in `/app`.
5. Restarts upstream server with updated payload, calls `POST /__5s__/net-online`, and verifies SQLite updates and `/__5s__/status` reports `"online": true`.

### Phase 3 Verification Gate
```bash
python3 tests/test_cache_proxy.py
```

---

## Phase 4: Fast-Path Background Network Manager (`5s-net-fast.sh`)

### Objective
Manage `wlan0` (Broadcom BCM4313 / `brcmsmac`) on Physical Core 1 (`cpus 1,3`) using `iwd` and `dhcpcd`, preload cached IP/DNS in `< 50 ms`, and trigger `POST /__5s__/net-online` as soon as connected.

### Step 4.1: Implement `src/net/5s-net-fast.sh`
Locked to interface `WLAN_IF="${WLAN_IF:-wlan0}"`:
1. **`--shutdown --state-dir <dir>`:**
   - Writes current `wlan0` IPv4 CIDR, gateway IP, and connected SSID to `<dir>/net/last_lease.env`.
   - Caches resolved IPv4 lines for `mail.google.com`, `www.youtube.com`, `i.ytimg.com`, and `googlevideo.com` into `<dir>/net/hosts.cache`.
2. **`--boot --state-dir <dir>`:**
   - **Immediate Preload (t + 20 ms):**
     - Copies `<dir>/net/hosts.cache` into `<dir>/net/active_hosts` (and appends between `# BEGIN 5S-CACHE` / `# END 5S-CACHE` markers in `/etc/hosts` when running as root).
     - Reads `<dir>/net/last_lease.env` and immediately applies `ip link set wlan0 up`, `ip addr replace $CACHED_IP dev wlan0`, and `ip route replace default via $CACHED_GW dev wlan0` (skipped cleanly when `MOCK_MODE=1`).
   - **Fast Association (t + 100 ms):**
     - Runs `iwctl station wlan0 connect "$CACHED_SSID"` and launches `dhcpcd -4 -q --noarp wlan0` in the background (mocked in `MOCK_MODE=1`).
   - **Online Notification (t + 150 ms):**
     - Polls connectivity and fires `curl -fsS -X POST http://127.0.0.1:8555/__5s__/net-online`.

### Step 4.2: Implement `tests/test_net_fast.sh`
- Runs `MOCK_MODE=1 src/net/5s-net-fast.sh --shutdown --state-dir <tmp>` and verifies `last_lease.env` and `hosts.cache` are created with all 4 target domains.
- Starts `cache_proxy.py --offline`, runs `MOCK_MODE=1 src/net/5s-net-fast.sh --boot --state-dir <tmp>`, and asserts `/__5s__/status` transitions to `"online": true` in `< 500 ms`.

### Phase 4 Verification Gate
```bash
bash tests/test_net_fast.sh
```

---

## Phase 5: Shutdown Checkpoint, Browser Launcher & 5-Second E2E Budget

### Objective
Wire together the Chromium launcher (`5s-browser-launch.sh`), shutdown checkpoint (`5s-checkpoint.sh`), 512 MB 4-stream LZ4 `zram` script, and GRUB2 config, and verify the `< 5.0 s` end-to-end startup budget.

### Step 5.1: Implement `src/checkpoint/5s-browser-launch.sh`
- Pinned to Physical Core 0 (`cpus 0,2`).
- In `MOCK_MODE=1`, performs a fast local HTTP fetch against `http://127.0.0.1:8555/app` to validate readiness and records timestamp in `${STATE_DIR}/browser_ready.ts`.
- On target hardware (`MOCK_MODE=0`), executes `cage -s -- /usr/bin/chromium` with the exact locked flags for Atom N550 + GMA 3150 + 2 GB DDR3 RAM:
  ```text
  --app=http://127.0.0.1:8555/app
  --kiosk
  --window-size=1024,600
  --no-first-run
  --no-default-browser-check
  --disable-gpu
  --disable-gpu-compositing
  --renderer-process-limit=2
  --process-per-site
  --js-flags=--max-old-space-size=384
  --v8-cache-options=code
  --disk-cache-dir=/var/cache/5s/chromium_cache
  --user-data-dir=/var/cache/5s/chromium_profile
  --disable-extensions
  --disable-component-update
  --disable-background-networking
  --disable-sync
  --disable-translate
  --disable-features=Translate,OptimizationHints,MediaRouter,DialMediaRouteProvider
  --enable-low-end-device-mode
  ```

### Step 5.2: Implement `src/checkpoint/5s-checkpoint.sh`
Executes deterministic shutdown (`--shutdown --state-dir <dir>`):
1. Calls `curl -fsS -X POST http://127.0.0.1:8555/__5s__/snapshot` to flush SQLite WAL (`<= 150 ms`).
2. Calls `5s-fb-splash --capture "<dir>/last_frame.fb"` (`<= 40 ms`).
3. Calls `5s-net-fast.sh --shutdown --state-dir "<dir>"` (`<= 40 ms`).
4. Writes `<dir>/checkpoint.manifest` containing `TIMESTAMP`, `FRAME_BYTES=1228800`, and `FRAME_SHA256`.

### Step 5.3: Implement `src/config/zram-setup.sh` & `src/config/grub-5s.cfg`
- `src/config/zram-setup.sh`: Configures `/dev/zram0` with `comp_algorithm=lz4`, `max_comp_streams=4` (for N550's 4 threads), `disksize=512M`, `mkswap /dev/zram0`, `swapon -p 100 /dev/zram0`, and `sysctl -w vm.swappiness=100 vm.page-cluster=0` (supports `MOCK_MODE=1` dry-run).
- `src/config/grub-5s.cfg`: Locked GRUB2 configuration snippet for `/etc/default/grub.d/5s-browser.cfg`:
  ```text
  GRUB_DEFAULT=0
  GRUB_TIMEOUT=0
  GRUB_RECORDFAIL_TIMEOUT=0
  GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=0 mitigations=off i915.fastboot=1 video=LVDS-1:1024x600@60e vt.global_cursor_default=0 init=/opt/5s-browser/bin/5s-init"
  ```

### Step 5.4: Implement `tests/test_checkpoint.sh`
1. Seeds a temporary state directory with a `1,228,800`-byte mock framebuffer and cached Gmail/YouTube data in `cache_proxy.py`.
2. Runs `5s-checkpoint.sh --shutdown --state-dir <tmp>` and asserts completion in `< 1,000 ms` and presence of `last_frame.fb`, `http_cache.sqlite`, `net/last_lease.env`, and `checkpoint.manifest`.
3. Simulates cold boot via `MOCK_MODE=1 5s-init --test-mode --state-dir <tmp>` and measures elapsed milliseconds:
   - Framebuffer restored (`last_frame.fb` → mock `/dev/fb0`): asserts **< 100 ms**.
   - Browser `/app` interactive HTTP 200 from offline SQLite cache + background network transition to `"online": true`: asserts **< 1,500 ms** total user-space time (leaving > 3.5 s for BIOS + kernel KMS within the 5.0 s hardware budget).

### Phase 5 Verification Gate
```bash
bash tests/test_checkpoint.sh
```

---

## Phase 6: Debian Package Builder (`5s-browser_0.1.0_amd64.deb`) & `HOWTO.md`

### Objective
Produce the single installable release package `dist/5s-browser_0.1.0_amd64.deb`, standalone `dist/HOWTO.md`, and `dist/SHA256SUMS`, verified by `tests/test_release_bundle.sh`.

### Step 6.1: Write `/HOWTO.md`
Write `/HOWTO.md` tailored specifically to the **HP Mini 210-2000 (Intel Atom N550, 2 GB DDR3 RAM, Intel GMA 3150, Broadcom BCM4313 `wlan0`)**:
1. **Target Hardware & Base OS Install:**
   - Install **Debian 12 (Bookworm) `amd64` netinst** on `/dev/sda1` (`ext4`), deselecting all desktop environments during tasksel (install only standard system utilities + SSH).
   - Enable `non-free-firmware` in `/etc/apt/sources.list` and run:
     ```bash
     sudo apt-get update && sudo apt-get install -y firmware-brcm80211 iwd dhcpcd-base cage chromium python3 lz4 curl
     ```
2. **Install the Release Asset (`5s-browser_0.1.0_amd64.deb`):**
   - Download `5s-browser_0.1.0_amd64.deb` and `SHA256SUMS` from the latest GitHub Release.
   - Verify and install:
     ```bash
     sha256sum -c SHA256SUMS --ignore-missing
     sudo dpkg -i 5s-browser_0.1.0_amd64.deb
     ```
3. **One-Time First-Boot Seeding (Wi-Fi + Gmail & YouTube Login):**
   - Connect `wlan0` once via `iwd`:
     ```bash
     sudo systemctl enable --now iwd
     iwctl station wlan0 connect "<YOUR_WIFI_SSID>"
     ```
   - Run the first-time seeding session to sign in to Gmail (enable *Settings → Offline → Enable offline mail*) and YouTube, then capture the initial checkpoint:
     ```bash
     sudo /opt/5s-browser/bin/5s-checkpoint.sh --shutdown
     ```
4. **Enable the 5-Second Direct Boot in GRUB2:**
   - Copy `/opt/5s-browser/config/grub-5s.cfg` to `/etc/default/grub.d/5s-browser.cfg` and run `sudo update-grub`.
   - Reboot and verify timeline:
     - **0.0 – 1.8 s:** GRUB2 + Kernel + `i915` KMS (`1024×600`).
     - **1.8 – 2.0 s:** `5s-fb-splash` paints your last shutdown screen to `/dev/fb0`.
     - **2.0 – 4.8 s:** `cage` + `chromium` becomes interactive on Physical Core 0 (`cpus 0,2`) using local SQLite cache while Physical Core 1 (`cpus 1,3`) associates `wlan0` and streams live updates in the background.
5. **Hotkeys & Recovery:**
   - `F1` or `Alt+1`: Gmail tab.
   - `F2` or `Alt+2`: YouTube tab.
   - Hold `Shift` at power-on (or edit GRUB cmdline to `init=/bin/bash`) for maintenance shell access.

### Step 6.2: Implement `scripts/build_release.sh`
Builds `dist/` with exact Debian package layout:
- Staging root `build/deb_root/`:
  - `DEBIAN/control` (`Package: 5s-browser`, `Version: 0.1.0`, `Architecture: amd64`, `Maintainer: five-second-browser`, `Depends: python3, lz4, curl`, `Recommends: cage, chromium, iwd, dhcpcd-base, firmware-brcm80211`)
  - `DEBIAN/postinst` (`chmod 0755` creates `/var/cache/5s/net`, sets executable permissions on `/opt/5s-browser/bin/*`)
  - `opt/5s-browser/bin/5s-init`
  - `opt/5s-browser/bin/5s-fb-splash`
  - `opt/5s-browser/bin/cache_proxy.py`
  - `opt/5s-browser/bin/injected_ui.js`
  - `opt/5s-browser/bin/5s-net-fast.sh`
  - `opt/5s-browser/bin/5s-checkpoint.sh`
  - `opt/5s-browser/bin/5s-browser-launch.sh`
  - `opt/5s-browser/bin/zram-setup.sh`
  - `opt/5s-browser/config/grub-5s.cfg`
  - `usr/share/doc/5s-browser/HOWTO.md`
- Runs `dpkg-deb --root-owner-group --build build/deb_root dist/5s-browser_0.1.0_amd64.deb`.
- Copies `/HOWTO.md` to `dist/HOWTO.md`.
- Generates `dist/SHA256SUMS` for `5s-browser_0.1.0_amd64.deb` and `HOWTO.md`.

### Step 6.3: Implement `tests/test_release_bundle.sh`
1. Asserts `dist/5s-browser_0.1.0_amd64.deb`, `dist/HOWTO.md`, and `dist/SHA256SUMS` exist and are non-empty.
2. Runs `(cd dist && sha256sum -c SHA256SUMS)`.
3. Extracts `dist/5s-browser_0.1.0_amd64.deb` with `dpkg-deb -x` into a temporary directory and asserts every binary and script in `opt/5s-browser/bin/` is present and executable (`-x`).
4. Verifies `dist/HOWTO.md` contains the required sections: `firmware-brcm80211`, `dpkg -i 5s-browser_0.1.0_amd64.deb`, `iwctl station wlan0 connect`, `5s-checkpoint.sh --shutdown`, `update-grub`, and `F1`/`F2` hotkeys.

### Phase 6 Verification Gate (Final Full-Suite Validation)
```bash
make clean && make build && make test && make package && bash tests/test_release_bundle.sh
```

---

## Final Execution Checklist for Hydrogen

- [ ] **Phase 1:** `Makefile`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`, and `tests/run_all.sh` created.
- [ ] **Phase 2:** `5s_fb_splash.c` and `5s_init.c` compiled with `-march=bonnell -mno-sse4.1 -mno-sse4.2 -mno-avx -Werror` and passing `test_fb_splash.sh` & `test_init_lifecycle.sh`.
- [ ] **Phase 3:** `cache_proxy.py` and `injected_ui.js` passing `test_cache_proxy.py` (`< 15 ms` offline SQLite hit, `h264ify` ≤ 480p30, `F1`/`F2` dual-tab bar, live SSE delta sync).
- [ ] **Phase 4:** `5s-net-fast.sh` passing `test_net_fast.sh` (`wlan0` lease & DNS cache preload + `/__5s__/net-online` notification).
- [ ] **Phase 5:** `5s-browser-launch.sh`, `5s-checkpoint.sh`, `zram-setup.sh`, and `grub-5s.cfg` passing `test_checkpoint.sh` (`< 5.0 s` E2E budget).
- [ ] **Phase 6:** `scripts/build_release.sh` and `HOWTO.md` passing `test_release_bundle.sh` and producing `dist/5s-browser_0.1.0_amd64.deb`, `dist/HOWTO.md`, and `dist/SHA256SUMS`.
