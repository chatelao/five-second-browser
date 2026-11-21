# `5s-browser` — 2-Step Setup Guide (`HP Mini 210-2000` / Atom N550)

`5s-browser` turns an old **HP Mini netbook (Intel Atom N550, 2 GB DDR3 RAM)** into a dedicated **Gmail & YouTube** appliance that boots into your last shutdown screen in **≤ 5 seconds**, while connecting Wi-Fi and syncing live updates in the background.

---

## Hardware Requirements

| Component | Required / Tested Specification |
| :--- | :--- |
| **Netbook Model** | HP Mini 210-2000 / 110-3500 Series (or compatible Pineview-M netbook) |
| **CPU** | **Intel Atom N550** (`x86_64`, 1.50 GHz, 2 physical cores / 4 threads, `SSSE3` + `MOVBE`, no `SSE4.1+`) |
| **RAM** | **2 GB DDR3** (2048 MB SODIMM @ 667 MHz) + 512 MB 4-stream LZ4 `zram0` (auto-configured) |
| **GPU & Display** | **Intel GMA 3150** (`8086:a011`, `i915` KMS) driving a **1024×600** LVDS panel (`LVDS-1`, 16-bit RGB565 `/dev/fb0`) |
| **Storage** | 2.5" SATA II HDD or SSD on Intel NM10 `ahci` (`/dev/sda`, ≥ 4 GB) |
| **Wi-Fi Card** | **Broadcom BCM4313** (`14e4:4727`, `brcmsmac` + `firmware-brcm80211`, interface `wlan0`) |

---

## Installation (2 Steps Only)

### Step 1: Install the ISO
1. Download **`5s-browser-0.2.0-amd64.iso`** from the [GitHub Releases page](https://github.com/chatelao/five-second-browser/releases) and flash it to a USB stick (using Rufus, BalenaEtcher, or `dd`).
2. Plug the USB stick into your HP Mini, power on, and press **`F9`** to boot from USB.
3. Wait ~90 seconds: the installer automatically partitions `/dev/sda`, installs Debian 12 + `firmware-brcm80211` + `cage` + `chromium` + `5s-browser`, configures GRUB2 (`TIMEOUT=0`, `i915.fastboot=1`, `init=/opt/5s-browser/bin/5s-init`), and **reboots automatically**. *(Remove the USB stick when the screen goes black for reboot.)*

### Step 2: Enter Wi-Fi Name + Password
1. On first boot, the screen displays the **Connect to Wi-Fi** setup card.
2. Enter your **Wi-Fi Name (SSID)** and **Wi-Fi Password**, then click **Connect & Start**.
3. Everything else is automatic:
   - `iwd` saves your credentials and pre-caches your IP lease and DNS records.
   - The dual-tab **Gmail & YouTube** browser opens (`F1` / `F2`).
   - Every shutdown automatically saves your framebuffer, SQLite cache, and V8 bytecode cache so every subsequent boot is **≤ 5 seconds**.

---

## Daily Hotkeys & Recovery

| Key | Action |
| :--- | :--- |
| `F1` or `Alt+1` | Switch instantly to **Gmail** |
| `F2` or `Alt+2` | Switch instantly to **YouTube** |
| `Power Button` | Save snapshot and power off cleanly |

- **Status Pill (Top Right):** `● Cached (Connecting...)` (instant local cache) → `● Live` (synced).
- **Maintenance / Recovery Shell:** Hold `Shift` during power-on to open GRUB, press `e`, and change `init=/opt/5s-browser/bin/5s-init` to `init=/bin/bash`.

*(Advanced users who already have Debian 12 `amd64` installed can alternatively install `5s-browser_0.1.0_amd64.deb` manually via `sudo dpkg -i 5s-browser_0.1.0_amd64.deb`.)*
