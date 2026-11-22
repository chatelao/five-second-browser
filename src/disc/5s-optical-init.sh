#!/usr/bin/env bash
set -euo pipefail

# Asynchronous optical drive & audio initialization (runs on Track B after boot).
# Keeps ahci/sr_mod off the critical 0-5s USB/SD boot path while enabling
# built-in DVD/Blu-ray drives once the browser UI is already interactive.

MOCK_MODE="${MOCK_MODE:-0}"
OPTICAL_DEV="${OPTICAL_DEV:-/dev/sr0}"

if [[ "$MOCK_MODE" == "1" ]]; then
  exit 0
fi

# Give Track A (Cage + Chromium) a clean 1.5s head start on boot
sleep 1.5

# Load SATA AHCI + optical drive + UDF/ISO9660 modules (bypasses modprobe.blacklist)
for mod in ahci sr_mod cdrom sg udf isofs; do
  modprobe "$mod" 2>/dev/null || true
done

# Ensure udev populates /dev/sr0 properties for disc_manager.py
if command -v udevadm >/dev/null 2>&1; then
  udevadm trigger --subsystem-match=block --action=add 2>/dev/null || true
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
fi

if [[ "$EFI_MOUNTED_BY_US" == "1" ]]; then
  umount /boot/efi 2>/dev/null || true
fi

# Unmute ALSA playback channels so DVD/Blu-ray & browser audio work immediately
if command -v amixer >/dev/null 2>&1; then
  for ctrl in Master Speaker Headphone PCM; do
    amixer -q sset "$ctrl" 85% unmute 2>/dev/null || true
  done
fi
