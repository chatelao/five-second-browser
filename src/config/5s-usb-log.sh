#!/usr/bin/env bash
set -euo pipefail

# Centralized persistent USB-stick logging helper for 5s-browser.
# Can be sourced for usb_log / ensure_usb_log_dir / rotate_usb_logs / sync_usb_logs,
# or executed directly with: --rotate | --sync | --log <component> <message...>

STATE_DIR="${STATE_DIR:-/var/cache/5s}"
MOCK_MODE="${MOCK_MODE:-0}"
LOCAL_LOG_DIR="${LOCAL_LOG_DIR:-$STATE_DIR/logs}"
_EFI_MOUNTED_BY_US=0

_resolve_usb_log_dir() {
  if [[ -n "${USB_LOG_DIR:-}" ]]; then
    echo "$USB_LOG_DIR"
    return 0
  fi
  if [[ "$MOCK_MODE" == "1" ]]; then
    echo "$STATE_DIR/usb_logs"
    return 0
  fi
  echo "/boot/efi/logs"
}

ensure_usb_log_dir() {
  mkdir -p "$LOCAL_LOG_DIR"
  local udir
  udir="$(_resolve_usb_log_dir)"
  _EFI_MOUNTED_BY_US=0

  if [[ "$MOCK_MODE" != "1" && "$udir" == /boot/efi* ]]; then
    if ! mountpoint -q /boot/efi 2>/dev/null; then
      local efi_dev=""
      if [[ -e /dev/disk/by-label/5S-USB-EFI ]]; then
        efi_dev="/dev/disk/by-label/5S-USB-EFI"
      elif [[ -e /dev/disk/by-label/5S-EFI ]]; then
        efi_dev="/dev/disk/by-label/5S-EFI"
      fi
      if [[ -n "$efi_dev" ]]; then
        mkdir -p /boot/efi
        if mount -o rw "$efi_dev" /boot/efi 2>/dev/null; then
          _EFI_MOUNTED_BY_US=1
        fi
      fi
    else
      mount -o remount,rw /boot/efi 2>/dev/null || true
    fi
  fi

  mkdir -p "$udir/current" 2>/dev/null || true
}

release_usb_log_dir() {
  if [[ "$MOCK_MODE" != "1" ]]; then
    sync 2>/dev/null || true
    if [[ "${_EFI_MOUNTED_BY_US:-0}" == "1" ]]; then
      umount /boot/efi 2>/dev/null || true
      _EFI_MOUNTED_BY_US=0
    fi
  fi
}

rotate_usb_logs() {
  ensure_usb_log_dir
  local udir
  udir="$(_resolve_usb_log_dir)"
  if [[ -d "$udir/current" ]]; then
    rm -rf "$udir/prev" 2>/dev/null || true
    mv "$udir/current" "$udir/prev" 2>/dev/null || true
  fi
  mkdir -p "$udir/current" 2>/dev/null || true
  release_usb_log_dir
}

usb_log() {
  local comp="${1:-general}"
  shift || true
  local msg="${*:-}"
  mkdir -p "$LOCAL_LOG_DIR"
  local up="0.00"
  if [[ -r /proc/uptime ]]; then
    read -r up _ < /proc/uptime || up="0.00"
  fi
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")"
  local line="[${up}s] [${ts}] [${comp}] ${msg}"
  printf '%s\n' "$line" >> "$LOCAL_LOG_DIR/${comp}.log" 2>/dev/null || true
  printf '%s\n' "$line" >> "$LOCAL_LOG_DIR/boot-timeline.log" 2>/dev/null || true
}

capture_pre_init_timing() {
  local out_file="$LOCAL_LOG_DIR/pre-init-timing.log"
  {
    echo "=== 5s-browser pre-init & boot gap timing ==="
    echo "captured_at_uptime: $(cat /proc/uptime 2>/dev/null || echo unknown)"
    echo "cmdline: $(cat /proc/cmdline 2>/dev/null || echo unknown)"
    echo "--- /run/5s-boot-marks ---"
    if [[ -f /run/5s-boot-marks ]]; then
      cat /run/5s-boot-marks 2>/dev/null || true
    else
      echo "(no /run/5s-boot-marks)"
    fi
    echo "--- kernel dmesg gaps >= 0.20s (first 20s) ---"
    if command -v dmesg >/dev/null 2>&1; then
      dmesg 2>/dev/null | awk '
        /^\[[[:space:]]*[0-9]+\.[0-9]+\]/ {
          s = $0
          sub(/^\[[[:space:]]*/, "", s)
          sub(/\].*$/, "", s)
          t = s + 0.0
          if (t > 20.0) exit
          if (have_prev && (t - prev_t) >= 0.20) {
            printf "+%6.3fs  (%6.3fs -> %6.3fs)  %s\n", (t - prev_t), prev_t, t, $0
          }
          prev_t = t
          have_prev = 1
        }
      ' || true
    fi
  } > "$out_file" 2>&1 || true
}

sync_usb_logs() {
  ensure_usb_log_dir
  local udir
  udir="$(_resolve_usb_log_dir)"

  if [[ "$MOCK_MODE" != "1" && ! -f /run/5s-usb-logs-rotated && -d /run ]]; then
    rotate_usb_logs
    touch /run/5s-usb-logs-rotated 2>/dev/null || true
  fi

  if [[ "$MOCK_MODE" != "1" ]]; then
    for rlog in /run/5s-cage-*.log; do
      if [[ -f "$rlog" ]]; then
        cp -f "$rlog" "$LOCAL_LOG_DIR/${rlog#/run/5s-}" 2>/dev/null || true
      fi
    done
    capture_pre_init_timing
    if command -v dmesg >/dev/null 2>&1; then
      dmesg > "$LOCAL_LOG_DIR/kernel-dmesg.log" 2>/dev/null || true
    fi
    {
      echo "=== 5s-browser system snapshot ($(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)) ==="
      echo "uptime: $(cat /proc/uptime 2>/dev/null || true)"
      echo "uname: $(uname -a 2>/dev/null || true)"
      echo "--- memory ---"
      free -m 2>&1 || true
      echo "--- audio ---"
      cat /proc/asound/cards 2>&1 || true
      echo "--- network interfaces ---"
      ip -4 -o addr 2>&1 || true
      ip -4 route 2>&1 || true
      echo "--- /etc/resolv.conf ---"
      cat /etc/resolv.conf 2>&1 || true
      echo "--- devices ---"
      ls -la /dev/dri /dev/sr* /dev/input /dev/fb* 2>&1 || true
      echo "--- processes ---"
      ps -eo pid,ppid,stat,comm,args 2>&1 || ps 2>&1 || true
    } > "$LOCAL_LOG_DIR/system-snapshot.log" 2>&1 || true
  fi

  if [[ -d "$udir/current" ]]; then
    cp -f "$LOCAL_LOG_DIR"/* "$udir/current/" 2>/dev/null || true
  fi
  release_usb_log_dir
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --rotate)
      rotate_usb_logs
      ;;
    --sync)
      sync_usb_logs
      ;;
    --log)
      shift
      usb_log "$@"
      ;;
    *)
      echo "Usage: $0 --rotate|--sync|--log <component> <message>" >&2
      exit 2
      ;;
  esac
fi
