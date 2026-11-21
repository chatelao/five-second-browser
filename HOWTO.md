# `5s-browser` Installation & Setup Guide (`HP Mini 210-2000` / Atom N550)

`5s-browser` turns an old **HP Mini netbook (Intel Atom N550, 2 GB DDR3 RAM)** into a dedicated dual-tab **Gmail & YouTube** appliance that boots into your last shutdown screen in **≤ 5 seconds**, while connecting Wi-Fi and syncing live updates in the background.

---

## 1. Exact Hardware Requirements

| Component | Required / Tested Specification |
| :--- | :--- |
| **Netbook Model** | HP Mini 210-2000 / 110-3500 Series (or compatible Pineview-M netbook) |
| **CPU** | **Intel Atom N550** (`x86_64`, 1.50 GHz, 2 physical cores / 4 threads, `SSSE3` + `MOVBE`, no `SSE4.1+`) |
| **RAM** | **2 GB DDR3** (2048 MB SODIMM @ 667 MHz) + 512 MB 4-stream LZ4 `zram0` (auto-configured) |
| **GPU & Display** | **Intel GMA 3150** (`8086:a011`, `i915` KMS) driving a **1024×600** LVDS panel (`LVDS-1`, 16-bit RGB565 `/dev/fb0`) |
| **Storage** | 2.5" SATA II HDD or SSD on Intel NM10 `ahci` (`/dev/sda1`, `ext4`, ≥ 4 GB free) |
| **Wi-Fi Card** | **Broadcom BCM4313** (`14e4:4727`, `brcmsmac` + `firmware-brcm80211`, interface `wlan0`) |

---

## 2. Step-by-Step Installation Process

### Step 1: Install Minimal Debian 12 (`Bookworm` `amd64`)
1. Download the **Debian 12 (`bookworm`) `amd64` netinst ISO** and flash it to a USB stick.
2. Boot the HP Mini from USB (press `F9` at power-on for Boot Menu) and run the Debian installer onto `/dev/sda1` (`ext4`).
3. At **Software selection (`tasksel`)**:
   - **Uncheck** *Debian desktop environment*, *GNOME*, and all other desktops.
   - Keep only **standard system utilities** and **SSH server** selected.
4. Reboot into your minimal Debian console and log in.

### Step 2: Install Base Runtime Dependencies
Ensure `non-free-firmware` is enabled in `/etc/apt/sources.list` (Debian 12 enables it by default), then install the Wi-Fi firmware, kiosk compositor, and browser:

```bash
sudo apt-get update
sudo apt-get install -y firmware-brcm80211 iwd dhcpcd-base cage chromium python3 lz4 curl
```

*(Note: If your HP Mini uses a different Wi-Fi card such as Atheros AR9285 (`ath9k`), `firmware-brcm80211` is harmless, though `iwd` will manage `wlan0` automatically.)*

### Step 3: Download & Install `5s-browser_0.1.0_amd64.deb`
Download `5s-browser_0.1.0_amd64.deb` and `SHA256SUMS` from the [GitHub Releases page](https://github.com/chatelao/five-second-browser/releases), verify the checksum, and install:

```bash
sha256sum -c SHA256SUMS --ignore-missing
sudo dpkg -i 5s-browser_0.1.0_amd64.deb
```

This installs all binaries and scripts into `/opt/5s-browser/bin/`, the GRUB2 config into `/opt/5s-browser/config/grub-5s.cfg`, and creates `/var/cache/5s/`.

### Step 4: One-Time First-Boot Seeding (Wi-Fi + Gmail & YouTube)
Before switching to 5-second direct boot, connect Wi-Fi once and populate the initial offline cache:

1. Connect `wlan0` via `iwd` (your WPA2 key is saved automatically in `/var/lib/iwd/` for future boots):
   ```bash
   sudo systemctl enable --now iwd
   iwctl station wlan0 connect "<YOUR_WIFI_SSID>"
   ```
2. Start the local SQLite cache proxy and launch the seeding browser session:
   ```bash
   sudo /opt/5s-browser/bin/cache_proxy.py --state-dir /var/cache/5s --port 8555 &
   sudo /opt/5s-browser/bin/5s-browser-launch.sh --state-dir /var/cache/5s
   ```
   - **Gmail tab (`F1`):** Sign in, then open *Settings → See all settings → Offline → Enable offline mail* so recent threads are stored locally in IndexedDB.
   - **YouTube tab (`F2`):** Sign in and let your home/subscriptions feed load once.
3. Capture your first clean shutdown snapshot (framebuffer, SQLite WAL, and `wlan0` lease/DNS):
   ```bash
   sudo /opt/5s-browser/bin/5s-checkpoint.sh --shutdown --state-dir /var/cache/5s
   ```

### Step 5: Enable 5-Second Direct Boot in GRUB2
Install the zero-timeout GRUB2 configuration (`i915.fastboot=1`, `video=LVDS-1:1024x600@60e`, `init=/opt/5s-browser/bin/5s-init`) and reboot:

```bash
sudo cp /opt/5s-browser/config/grub-5s.cfg /etc/default/grub.d/5s-browser.cfg
sudo update-grub
sudo reboot
```

---

## 3. What Happens on Every Boot

- **0.0 – 1.8 s:** BIOS + GRUB2 (`TIMEOUT=0`) + Linux kernel (`i915.fastboot=1`).
- **1.8 – 2.0 s:** `5s-fb-splash` maps `/var/cache/5s/last_frame.fb` (`1,228,800` bytes) directly to `/dev/fb0` — your last screen appears immediately.
- **2.0 – 4.8 s:** Physical Core 0 (`cpus 0,2`) launches `cage` + `chromium` (`--disable-gpu`) against `cache_proxy.py`, while Physical Core 1 (`cpus 1,3`) associates `wlan0` and streams live deltas into the open tabs.

---

## 4. Daily Hotkeys & Recovery

| Key | Action |
| :--- | :--- |
| `F1` or `Alt+1` | Switch instantly to **Gmail** |
| `F2` or `Alt+2` | Switch instantly to **YouTube** |
| `Power Button` | Trigger `5s-checkpoint.sh --shutdown` and power off cleanly |

- **Status Pill (Top Right):** `● Cached (Connecting...)` (offline SQLite/IndexedDB cache) → `● Live` (synced).
- **Maintenance / Recovery Shell:** Hold `Shift` during power-on to open GRUB, press `e`, and change `init=/opt/5s-browser/bin/5s-init` to `init=/bin/bash`.
