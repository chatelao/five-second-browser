#!/usr/bin/env bash
set -euo pipefail

# Dedicated audio initialization for HP Pavilion 17-g111nz (Realtek ALC3241 on card PCH).
# Runs independently of ahci/optical probing so SATA timeouts cannot block audio.

MOCK_MODE="${MOCK_MODE:-0}"
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

if command -v modprobe >/dev/null 2>&1 && [[ ! -e /proc/asound/PCH ]]; then
  modprobe snd_hda_intel 2>/dev/null || true
fi

TARGET_CARD=""
for _ in $(seq 1 50); do
  if [[ -e /proc/asound/PCH ]]; then
    TARGET_CARD="PCH"
    break
  fi
  if [[ -r /proc/asound/cards ]]; then
    # Fallback: pick first card that is not HDMI
    non_hdmi="$(awk '/^[[:space:]]*[0-9]+/ && $0 !~ /HDMI/ { print $1; exit }' /proc/asound/cards 2>/dev/null || true)"
    if [[ -n "$non_hdmi" ]]; then
      TARGET_CARD="$non_hdmi"
      break
    fi
  fi
  sleep 0.1
done

if [[ -z "$TARGET_CARD" ]]; then
  TARGET_CARD="0"
  usb_log "audio" "WARN: PCH/analog ALSA card not found; falling back to card 0"
else
  usb_log "audio" "selected ALSA card: $TARGET_CARD"
fi

if [[ -f /opt/5s-browser/config/asound-5s.conf && ! -f /etc/asound.conf ]]; then
  cp -f /opt/5s-browser/config/asound-5s.conf /etc/asound.conf 2>/dev/null || true
fi
if [[ "$TARGET_CARD" != "PCH" && -w /etc/asound.conf ]]; then
  sed -i "s/PCH/${TARGET_CARD}/g" /etc/asound.conf 2>/dev/null || true
fi

if command -v amixer >/dev/null 2>&1; then
  for ctrl in Master Speaker Headphone PCM Front; do
    amixer -c "$TARGET_CARD" -q sset "$ctrl" 85% unmute 2>/dev/null || true
  done
  amixer -c "$TARGET_CARD" -q sset "Auto-Mute Mode" Enabled 2>/dev/null || true
  usb_log "audio" "unmuted mixer controls on card $TARGET_CARD"
fi

if command -v aplay >/dev/null 2>&1; then
  {
    echo "--- aplay -l ---"
    aplay -l 2>&1 || true
  } >> "$STATE_DIR/logs/audio.log" 2>/dev/null || true
fi
