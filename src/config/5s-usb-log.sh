#!/usr/bin/env bash
set -euo pipefail

# Centralized persistent USB-stick logging helper for 5s-browser.
# Can be sourced for usb_log / ensure_usb_log_dir / rotate_usb_logs / sync_usb_logs,
# or executed directly with: --rotate | --sync | --log <component> <message...>

STATE_DIR="${STATE_DIR:-/var/cache/5s}"
MOCK_MODE="${MOCK_MODE:-0}"
LOCAL_LOG_DIR="${LOCAL_LOG_DIR:-$STATE_DIR/logs}"

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

  if [[ "$MOCK_MODE" != "1" && "$udir" == /boot/efi* ]]; then
    if ! mountpoint -q /boot/efi 2>/dev/null; then
      if [[ -e /dev/disk/by-label/5S-USB-EFI || -e /dev/disk/by-label/5S-EFI ]]; then
        mkdir -p /boot/efi
        mount -o rw /dev/disk/by-label/5S-USB-EFI /boot/efi 2>/dev/null || \
          mount -o rw /dev/disk/by-label/5S-EFI /boot/efi 2>/dev/null || true
      fi
    else
      mount -o remount,rw /boot/efi 2>/dev/null || true
    fi
  fi

  mkdir -p "$udir/current" 2>/dev/null || true
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

sync_usb_logs() {
  ensure_usb_log_dir
  local udir
  udir="$(_resolve_usb_log_dir)"

  if [[ "$MOCK_MODE" != "1" ]]; then
    if command -v dmesg >/dev/null 2>&1; then
      dmesg > "$LOCAL_LOG_DIR/kernel-dmesg.log" 2>/dev/null || true
    fi
    {
      echo "=== 5s-browser system snapshot ($(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)) ==="
      echo "uptime: $(cat /proc/uptime 2>/dev/null || true)"
      echo "uname: $(uname -a 2>/dev/null || true)"
      echo "--- memory ---"
      free -m 2>&1 || true
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
    if [[ "$MOCK_MODE" != "1" ]]; then
      sync 2>/dev/null || true
    fi
  fi
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
