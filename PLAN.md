# Implementation Plan: `5s-browser` (Adapted for HP Pavilion `P5N65EA#UUZ` / Pentium 3825U)

> **Exact Target Hardware Profile (Verified from BIOS Screen `PXL_20261121_192929042.jpg`):**
> Every hardware and software component is locked to the exact laptop shown in the BIOS System Information screen:
>
> | Component | Verified Exact Hardware & Locked Software Configuration |
> | :--- | :--- |
> | **Laptop Model** | **HP Pavilion 17-g111nz (`P5N65EA#UUZ`)** — System Board ID **`8094`**, BIOS **`F.77`** (InsydeH2O UEFI 2.4 + Legacy CSM) |
> | **CPU & Threads** | **Intel Pentium 3825U @ 1.90 GHz** (5th-Gen "Broadwell-U" 14nm, **2 physical cores / 4 threads** `cpu0..cpu3`, **2 MB L3 cache**, out-of-order `x86_64`) |
> | **Supported ISA** | `SSE2`, `SSE3`, `SSSE3`, **`SSE4.1`**, **`SSE4.2`**, **`POPCNT`**, **`MOVBE`**, `PCLMUL`, `RDRAND`. **NO `AVX` / `AVX2` / `FMA` / `BMI`** (fused off on Pentium Broadwell-U) |
> | **Compiler Flags** | `gcc -O2 -march=nehalem -mtune=broadwell -mmovbe -mno-avx -mno-avx2 -mno-bmi -mno-bmi2 -mno-fma -Wall -Wextra -Werror -pthread` |
> | **Core Isolation** | **Physical Core 0 (`cpus 0,2`)** = Track A (`cage` + `chromium`); **Physical Core 1 (`cpus 1,3`)** = Track B (`cache_proxy.py` + `5s-net-fast.sh`) |
> | **System RAM & Swap** | **4 GB DDR3L-1600** (`4096 MB`) + **1024 MB 4-stream LZ4 `zram0`** (`--js-flags=--max-old-space-size=768` per renderer) |
> | **GPU & Display** | **Intel HD Graphics (Broadwell-U GT1, Gen8)** (`i915` KMS, 17.3" `eDP-1` **1600×900** 32-bit `XRGB8888` `/dev/fb0`, dynamic `FBIOGET_FSCREENINFO` size + **VA-API hardware H.264 720p/1080p decode** via `i965-va-driver`) |
> | **Wi-Fi & Bluetooth** | **WLAN FCC ID `PD93165NG` = Intel Dual Band Wireless-AC 3165** (`8086:3165`, 802.11ac 5 GHz + 2.4 GHz, mainline **`iwlwifi`/`iwlmvm`** driver + **`firmware-iwlwifi`**, auto-detected `wlan0`/`wlo1`) |
> | **Storage & Ports** | Internal 2.5" **SATA III (6 Gb/s `ahci`)** OR external **SuperSpeed USB 3.0 (`xhci_hcd`, ~200 MB/s)** / **SD Card (`rtsx_pci_sdmmc`)** |
> | **Base OS & Bootloader** | **Debian 12 (Bookworm) `amd64` Minimal** with **Hybrid UEFI (`grub-efi-amd64`) + Legacy BIOS (`grub-pc`)** (`GRUB_TIMEOUT=0`, `init=/opt/5s-browser/bin/5s-init`) |
> | **Kiosk & Browser** | **`/usr/bin/cage`** Wayland compositor + **`/usr/bin/chromium`** with Gen8 EGL/VA-API hardware acceleration + V8 Bytecode Cache |
> | **Release Assets** | **`dist/5s-browser_<VERSION>_amd64.deb`** + **`dist/5s-browser-<VERSION>-usb-sd-amd64.img.xz`** + **`dist/5s-browser-<VERSION>-amd64.iso`** + **`dist/HOWTO.md`** + **`dist/SHA256SUMS`** |
>
> **Execution Rules for Hydrogen:**
> 1. Execute **Phase 1 through Phase 6** sequentially.
> 2. At the end of each phase, run the **Phase Verification Gate** command and ensure it exits with code `0`.
> 3. Every shell script must start with `#!/usr/bin/env bash` and `set -euo pipefail`.
> 4. Support `FB_DEVICE`, `STATE_DIR`, and `MOCK_MODE=1` environment variables so all hardware steps run deterministically inside GitHub Actions CI runners.

---

## Key Architectural Upgrades Enabled by the HP Pavilion `P5N65EA#UUZ` (vs. Legacy Atom)

1. **Intel Wireless-AC 3165 (`PD93165NG`) 5 GHz 802.11ac Support:**
   - Replace `firmware-brcm80211` with **`firmware-iwlwifi`** (mainline `iwlwifi` + `iwlmvm` kernel modules).
   - Auto-detect the wireless interface in `5s-net-fast.sh` (`iwctl device list` / `/sys/class/net/wl*` → handles both `wlan0` and `wlo1`).
   - 802.11ac 5 GHz association + background Gmail/YouTube delta sync completes ~3× faster than 2.4 GHz 802.11n.
2. **Broadwell-U CPU (`SSE4.2` + `POPCNT`) & 4 GB DDR3L-1600 RAM:**
   - Enable hardware `SSE4.1`, `SSE4.2`, `POPCNT`, and `MOVBE` (`-march=nehalem -mtune=broadwell -mmovbe -mno-avx -mno-avx2 -mno-bmi -mno-bmi2 -mno-fma`), while still forbidding `AVX`/`AVX2`/`BMI`/`FMA` in `make check-isa` (since Pentium 3825U lacks AVX).
   - Expand V8 heap limit from 384 MB to **768 MB per renderer** (`--js-flags=--max-old-space-size=768`) and `zram0` to **1024 MB**, utilizing the 4 GB RAM so large Gmail inboxes and YouTube feeds stay 100% in RAM.
3. **Broadwell Gen8 GPU (`i915` + VA-API Hardware H.264 Decode + Dynamic Framebuffer Size):**
   - Unlike old GMA 3150, Broadwell Gen8 has hardware **VA-API H.264 & VP8 decoding (`i965-va-driver`)** and fast EGL hardware compositing.
   - Update `injected_ui.js` (`h264ify`) to still block software-decoded `vp9`/`av01`, but allow **H.264 (`avc1`) up to 720p30/1080p30** (decoded in hardware by Broadwell QuickSync at < 5% CPU!).
   - Update `5s_fb_splash.c` to dynamically query the framebuffer size via `ioctl(fd, FBIOGET_FSCREENINFO, &finfo)` / `fstat()` so it seamlessly captures and restores the 17.3" `1600×900` 32-bit `eDP-1` framebuffer (`5,760,000` bytes) on real hardware as well as `1,228,800`-byte test buffers in CI.
4. **Hybrid UEFI (`F.77` InsydeH2O) + Legacy BIOS Boot on USB 3.0 & SD Card:**
   - Board `8094` (BIOS `F.77`) boots in **UEFI mode by default** and has **USB 3.0 (`xhci_hcd`)** and a **Realtek PCIe SD card reader (`rtsx_pci_sdmmc`)**.
   - Configure `scripts/build_usb_img.sh` and `scripts/build_iso.sh` with both **UEFI (`EFI/BOOT/BOOTX64.EFI`)** and **Legacy BIOS (`i386-pc`)** bootloaders plus `xhci_pci`, `usb_storage`, `uas`, `rtsx_pci_sdmmc`, and `mmc_block` in initramfs.

---

## Phase 1: Build System & Broadwell Pentium 3825U ISA Verification

### Step 1.1: Update `Makefile`
- Update `CFLAGS`:
  ```makefile
  CFLAGS := -O2 -march=nehalem -mtune=broadwell -mmovbe -mno-avx -mno-avx2 -mno-bmi -mno-bmi2 -mno-fma -Wall -Wextra -Werror -pthread
  ```
- Update `check-isa` target in `Makefile`:
  - Assert that `build/bin/5s-fb-splash` and `build/bin/5s-init` contain **zero `AVX`/`AVX2`/`FMA`/`BMI` instructions** (`\b(vmov|vadd|vpadd|vpxor|vzeroupper|shrx|shlx|sarx|rorx|andn|blsr|tzcnt|lzcnt)\b`), while permitting `SSE4.1`/`SSE4.2` (`crc32`, `pcmp`).

### Phase 1 Verification Gate
```bash
make clean && make build && make check-isa
```

---

## Phase 2: Dynamic Resolution Framebuffer Splash (`5s_fb_splash.c`)

### Step 2.1: Update `src/init/5s_fb_splash.c` for Dynamic Framebuffer Size (`1600×900` `eDP-1` & CI Mock)
- Add helper `detect_frame_bytes(int fb_fd, int snap_fd)`:
  1. Checks `ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo)` (`<linux/fb.h>`) — if `finfo.smem_len > 0`, uses `finfo.smem_len` (handles `1600×900×4 = 5,760,000` bytes or `1920×1080×4 = 8,294,400` bytes automatically on `i915` `inteldrmfb`).
  2. Otherwise checks `fstat()` on `snap_fd` or `fb_fd` — if regular file with `st_size > 0`, uses `st_size`.
  3. Otherwise falls back to `DEFAULT_FRAME_BYTES` (`1228800`).
- Preserves zero-intermediate-buffer `mmap`-to-`write_all` (`capture_frame`) and `mmap`-to-`mmap` single `memcpy` (`restore_frame`).

### Phase 2 Verification Gate
```bash
make build && bash tests/test_fb_splash.sh && bash tests/test_init_lifecycle.sh
```

---

## Phase 3: Broadwell Hardware H.264 720p/1080p Media Filter (`injected_ui.js`)

### Step 3.1: Update `src/proxy/injected_ui.js`
- Keep `BLOCKED_CODECS = /vp0?9|av01/i` so YouTube never serves CPU-heavy software VP9/AV1.
- Allow **H.264 (`avc1`) and `vp8` up to `1080p` (`height <= 1080`)** (`HIGH_RES = /height=(?:1[1-9]\d{2}|[2-9]\d{3,})/i`), taking advantage of the Pentium 3825U's Gen8 hardware VA-API video decoder on the 17.3" `1600×900` screen.

### Phase 3 Verification Gate
```bash
python3 tests/test_cache_proxy.py
```

---

## Phase 4: Intel Wireless-AC 3165 (`PD93165NG` / `iwlwifi`) Auto-Detection (`5s-net-fast.sh`)

### Step 4.1: Update `src/net/5s-net-fast.sh`
- Add automatic wireless interface discovery when `WLAN_IF` is not explicitly set:
  - Scans `/sys/class/net/wl*` (matching `wlan0`, `wlo1`, `wlp2s0`, etc. used by `iwlwifi` on HP Pavilion Board `8094`) and falls back to `wlan0`.
- Uses `iwd` (`iwctl station "$WLAN_IF" connect "$CACHED_SSID"`) + `dhcpcd -4 -q --noarp "$WLAN_IF"` and preloads `/etc/hosts` and cached IPv4 lease in `< 50 ms`.

### Phase 4 Verification Gate
```bash
bash tests/test_net_fast.sh
```

---

## Phase 5: Broadwell-U 4 GB RAM Launcher, VA-API & UEFI/BIOS GRUB Config

### Step 5.1: Update `src/checkpoint/5s-browser-launch.sh`
- Update Chromium flags for **Intel Pentium 3825U (4 GB RAM + Broadwell Gen8 VA-API GPU)**:
  ```text
  --app=${PROXY_URL}/app
  --kiosk
  --start-fullscreen
  --no-first-run
  --no-default-browser-check
  --enable-features=VaapiVideoDecoder,VaapiVideoEncoder,CanvasOopRasterization
  --ignore-gpu-blocklist
  --enable-gpu-rasterization
  --enable-zero-copy
  --renderer-process-limit=2
  --process-per-site
  --js-flags=--max-old-space-size=768
  --v8-cache-options=code
  --disk-cache-dir=${STATE_DIR}/chromium_cache
  --user-data-dir=${STATE_DIR}/chromium_profile
  --disable-extensions
  --disable-component-update
  --disable-background-networking
  --disable-sync
  --disable-translate
  --disable-features=Translate,OptimizationHints,MediaRouter,DialMediaRouteProvider
  ```

### Step 5.2: Update `src/config/zram-setup.sh` & `src/config/grub-5s.cfg`
- `src/config/zram-setup.sh`: Increase `zram0` size from `512M` to **`1024M`** (1 GB LZ4 swap with `max_comp_streams=4` on 4 GB DDR3L RAM).
- `src/config/grub-5s.cfg`: Update kernel command line for Broadwell-U `i915` (`eDP-1` internal panel, automatic native resolution with fastboot):
  ```text
  GRUB_DEFAULT=0
  GRUB_TIMEOUT=0
  GRUB_RECORDFAIL_TIMEOUT=0
  GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=0 mitigations=off i915.fastboot=1 vt.global_cursor_default=0 init=/opt/5s-browser/bin/5s-init"
  ```

### Phase 5 Verification Gate
```bash
bash tests/test_checkpoint.sh
```

---

## Phase 6: Packaging (`firmware-iwlwifi` + `i965-va-driver` + Hybrid UEFI/BIOS USB Image) & `HOWTO.md`

### Step 6.1: Update `scripts/build_release.sh`, `scripts/build_iso.sh`, and `scripts/build_usb_img.sh`
1. **`scripts/build_release.sh`:**
   - Update `Recommends:` in `DEBIAN/control` to:
     `Recommends: cage, chromium, iwd, dhcpcd-base, firmware-iwlwifi, i965-va-driver, vainfo`
   - Update `Description:` to reference **HP Pavilion 17-g111nz (`P5N65EA#UUZ`, Intel Pentium 3825U, 4 GB RAM, Intel Wireless-AC 3165)**.
2. **`scripts/build_iso.sh` & `scripts/build_usb_img.sh`:**
   - Install **`firmware-iwlwifi`** and **`i965-va-driver`** (alongside `firmware-brcm80211` fallback) in the Debian 12 rootfs so the **Intel Wireless-AC 3165 (`PD93165NG`)** and **Broadwell VA-API hardware video decode** work out-of-the-box.
   - Include `xhci_pci`, `xhci_hcd`, `usb_storage`, `uas`, `rtsx_pci`, `rtsx_pci_sdmmc`, `mmc_block`, `sdhci`, `sdhci_pci` in `/etc/initramfs-tools/modules` so USB 3.0 and the HP Pavilion SD card slot boot reliably.
   - In `scripts/build_usb_img.sh`, create a hybrid **MBR + EFI System Partition (ESP)** layout (Partition 1: 64 MB FAT32 `/boot/efi` with `grub-efi-amd64-bin` `--target=x86_64-efi --removable`, Partition 2: `ext4` `LABEL=5s-usb-root` with `grub-pc` `--target=i386-pc`) so BIOS `F.77` boots the USB stick or SD card whether UEFI mode or Legacy Support mode is active!

### Step 6.2: Update `HOWTO.md` & `tests/test_release_bundle.sh`
- Update `HOWTO.md` with the exact **HP Pavilion 17-g111nz (`P5N65EA#UUZ`, Board `8094`, BIOS `F.77`)** hardware table, UEFI/Legacy F9 USB/SD boot note, and 2-step setup flow.
- Bump `/VERSION` to `0.4.0`.

### Phase 6 Verification Gate
```bash
shellcheck scripts/*.sh src/*/*.sh tests/*.sh
python3 -m py_compile src/proxy/cache_proxy.py tests/test_cache_proxy.py
make clean && make build && make check-isa && make test && make package && bash tests/test_release_bundle.sh
```
