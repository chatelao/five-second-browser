# `5s-browser` — 2-Step Setup Guide (`HP Pavilion 17-g111nz` / `P5N65EA#UUZ`)

`5s-browser` turns your **HP Pavilion 17-g111nz (`P5N65EA#UUZ`, Pentium 3825U, 4 GB RAM)** into a dedicated **Gmail & YouTube** appliance that cold-boots into your cached inbox and feed in **≤ 3–5 seconds** while connecting 5 GHz Wi-Fi and syncing live updates in the background.

---

## Verified Hardware Specifications

| Component | Verified Specification (`P5N65EA#UUZ`) |
| :--- | :--- |
| **Laptop Model** | **HP Pavilion 17-g111nz (`P5N65EA#UUZ`)** — System Board ID `8094`, BIOS `F.77` |
| **CPU** | **Intel Pentium 3825U @ 1.90 GHz** (Broadwell-U, 2 cores / 4 threads, `SSE4.2` + `MOVBE`, no `AVX`) |
| **RAM** | **4 GB DDR3L-1600** + 1024 MB 4-stream LZ4 `zram0` (auto-configured) |
| **GPU & Display** | **Intel HD Graphics (Broadwell Gen8)** (`i915` KMS + hardware VA-API H.264/VP8 decode via `i965-va-driver`) driving 17.3" **1600×900** (`eDP-1`) |
| **Storage** | **Option A:** Any **USB 3.0 stick** or **SD card** (≥ 4 GB) — *leaves internal drive untouched*<br>**Option B:** Internal 2.5" SATA III HDD/SSD (`/dev/sda`, ≥ 4 GB) |
| **Wi-Fi Card** | **Intel Dual Band Wireless-AC 3165** (`FCC ID: PD93165NG`, 802.11ac 5 GHz + 2.4 GHz, `iwlwifi` + `firmware-iwlwifi`) |

---

## Installation (2 Steps Only)

### Step 1: Flash & Boot (UEFI or Legacy BIOS)
Choose **either** the 100% portable USB 3.0 / SD card image (leaves your internal drive untouched) **or** the internal-disk installer ISO:

- **Option A — Run 100% from USB 3.0 Stick or SD Card (Zero Internal Disk Changes):**
  1. Download **`5s-browser-0.5.0-usb-sd-amd64.img.xz`** from the [GitHub Releases page](https://github.com/chatelao/five-second-browser/releases).
  2. Flash it directly to a USB 3.0 stick (recommended for ~2.5 s cold boot) or SD card (≥ 4 GB) using **BalenaEtcher**, **Rufus**, or **Raspberry Pi Imager** (they decompress `.img.xz` automatically).
  3. *(Optional)* Open the small **`5S-USB-EFI`** FAT32 drive on any Windows/Mac/Linux PC and edit **`wifi.txt`** with `SSID=YourWiFiName` and `PASSWORD=YourWiFiPassword` to pre-configure Wi-Fi before booting.
  4. Insert the USB stick into a **SuperSpeed USB 3.0 port** (or insert the SD card), power on, and press **`F9`** to select it in the HP Boot Menu. *(Supports both UEFI `F.77` and Legacy Boot modes; disable Secure Boot in `F10` BIOS Setup if prompted.)*
  5. *(Recommended for fastest power-on)* In **`F10` BIOS Setup → System Configuration → Boot Options**, set **Legacy Support = `Disabled`**, **POST Hotkey Delay = `0 sec`**, **Network Boot = `Disabled`**, and move **USB Diskette on Key/USB Hard Disk** to #1 in **UEFI Boot Order** (skips the multi-second HP pre-boot delay and `F9` menu).

- **Option B — Install Permanently to Internal Drive (`/dev/sda`):**
  1. Download **`5s-browser-0.5.0-amd64.iso`**, flash to a USB stick, and boot with **`F9`**.
  2. Wait ~60–90 seconds while it automatically partitions `/dev/sda` (UEFI ESP + ext4), installs Debian 12 + `firmware-iwlwifi` + `i965-va-driver` + `cage` + `chromium` + `5s-browser`, and **reboots automatically**.

### Step 2: Enter Wi-Fi Name + Password (On Screen or via `wifi.txt`)
1. Either edit **`wifi.txt`** on the **`5S-USB-EFI`** FAT32 partition before booting (`SSID=...` / `PASSWORD=...`), **or** on first boot use the on-screen **Connect to Wi-Fi** setup card.
2. Enter your **Wi-Fi Name (SSID)** (5 GHz or 2.4 GHz) and **Wi-Fi Password**, then click **Connect & Start**.
3. Everything else is automatic:
   - `iwd` saves your credentials and pre-caches your IP lease and DNS records.
   - The dual-tab **Gmail & YouTube** browser opens (`F1` / `F2`) with Broadwell VA-API hardware video decoding up to 1080p.
   - Every shutdown automatically saves your `1600×900` framebuffer, SQLite cache, and V8 bytecode cache.

---

## Daily Hotkeys & Recovery

| Key | Action |
| :--- | :--- |
| `F1` or `Alt+1` | Switch instantly to **Gmail** |
| `F2` or `Alt+2` | Switch instantly to **YouTube** |
| `Power Button` | Save snapshot and power off cleanly |

- **Status Pill (Top Right):** `● Cached (Connecting...)` (instant local cache) → `● Live` (synced).
- **Maintenance / Recovery Shell:** Hold `Shift` (or `Esc`) during power-on to open GRUB, press `e`, and change `init=/opt/5s-browser/bin/5s-init` to `init=/bin/bash`.

*(Advanced users who already have Debian 12 `amd64` installed can alternatively install `5s-browser_0.5.0_amd64.deb` manually via `sudo dpkg -i 5s-browser_0.5.0_amd64.deb`.)*
