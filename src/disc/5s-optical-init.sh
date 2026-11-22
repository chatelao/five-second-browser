#!/usr/bin/env bash
set -euo pipefail

# Asynchronous optical drive & audio initialization (runs on Track B after boot).
# Keeps ahci/sr_mod off the critical 0-5s USB/SD boot path while enabling
# built-in DVD/Blu-ray drives once the browser UI is already interactive.

MOCK_MODE="${MOCK_MODE:-0}"
OPTICAL_DEV="${OPTICAL_DEV:-/dev/sr0}"
STATE_DIR="${STATE_DIR:-/var/cache/5s}"

if [[ "$MOCK_MODE" == "1" ]]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USB_LOG_SH=""
for _cand in "$SCRIPT_DIR/5s-usb-log.sh" "$SCRIPT_DIR/../config/5s-usb-log.sh" "/opt/5s-browser/bin/5s-usb-log.sh"; do
  if [[ -f "$_cand" ]]; then
    USB_LOG_SH="$_cand"
    break
  fi
done
if [[ -n "$USB_LOG_SH" ]]; then
  # shellcheck source=/dev/null
  source "$USB_LOG_SH"
else
  usb_log() { :; }
fi

usb_log "optical" "starting optical init (sleep 15s so Track A & Wi-Fi/DHCP finish cleanly)"

if [[ -f "$STATE_DIR/features.json" ]] && grep -q '"disc"[[:space:]]*:[[:space:]]*false' "$STATE_DIR/features.json" 2>/dev/null; then
  usb_log "optical" "disc feature disabled in features.json; skipping ahci/sr_mod"
  exit 0
fi

# Give Track A (Cage + Chromium) and Wi-Fi/DHCP a clean 15s head start before probing AHCI/SATA
sleep 15

# Load optical & filesystem modules first so sr_mod binds immediately when ahci probes ata2
for mod in sr_mod cdrom sg udf isofs; do
  if modprobe "$mod" 2>/dev/null; then
    usb_log "optical" "modprobe $mod: ok"
  else
    usb_log "optical" "modprobe $mod: failed/unavailable"
  fi
done

# Run modprobe ahci asynchronously so a slow/failing internal SATA port cannot stall init
if modprobe ahci 2>/dev/null & then
  usb_log "optical" "modprobe ahci started asynchronously"
fi

# Wait briefly for /dev/sr0 to appear on ata2
for _ in $(seq 1 40); do
  if [[ -e "$OPTICAL_DEV" ]]; then
    break
  fi
  sleep 0.1
done

# Ensure udev populates /dev/sr0 properties for disc_manager.py
if command -v udevadm >/dev/null 2>&1; then
  udevadm trigger --subsystem-match=block --action=add 2>/dev/null || true
fi

if [[ -e "$OPTICAL_DEV" ]]; then
  usb_log "optical" "optical device present: $OPTICAL_DEV"
else
  usb_log "optical" "optical device not found yet: $OPTICAL_DEV"
fi

# Sync optional Blu-ray AACS KEYDB.cfg from FAT32 EFI partition if present
EFI_MOUNTED_BY_US=0
if [[ ! -f /boot/efi/KEYDB.cfg ]] && ! mountpoint -q /boot/efi 2>/dev/null && \
   [[ -e /dev/disk/by-label/5S-USB-EFI || -e /dev/disk/by-label/5S-EFI ]]; then
  mkdir -p /boot/efi
  if mount -o ro /dev/disk/by-label/5S-USB-EFI /boot/efi 2>/dev/null || \
     mount -o ro /dev/disk/by-label/5S-EFI /boot/efi 2>/dev/null; then
    EFI_MOUNTED_BY_US=1
  fi
fi

if [[ -f /boot/efi/KEYDB.cfg ]]; then
  KIOSK_HOME="/home/kiosk"
  if id -u kiosk >/dev/null 2>&1; then
    KIOSK_HOME="$(getent passwd kiosk | cut -d: -f6 || echo /home/kiosk)"
  fi
  mkdir -p "${KIOSK_HOME}/.config/aacs"
  cp -f /boot/efi/KEYDB.cfg "${KIOSK_HOME}/.config/aacs/KEYDB.cfg"
  chmod 0644 "${KIOSK_HOME}/.config/aacs/KEYDB.cfg"
  if id -u kiosk >/dev/null 2>&1; then
    chown -R kiosk:kiosk "${KIOSK_HOME}/.config" 2>/dev/null || true
  fi
  usb_log "optical" "synced /boot/efi/KEYDB.cfg to ${KIOSK_HOME}/.config/aacs/KEYDB.cfg"
fi

if [[ "$EFI_MOUNTED_BY_US" == "1" ]]; then
  umount /boot/efi 2>/dev/null || true
fi
