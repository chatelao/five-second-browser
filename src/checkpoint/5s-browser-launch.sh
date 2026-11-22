#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/cache/5s}"
PROXY_URL="${PROXY_URL:-http://127.0.0.1:8555}"
MOCK_MODE="${MOCK_MODE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      STATE_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

log_msg() {
  echo "$*"
  echo "<6>$*" > /dev/kmsg 2>/dev/null || true
}

mkdir -p "$STATE_DIR/chromium_cache" "$STATE_DIR/chromium_profile"

if [[ "$MOCK_MODE" == "1" ]]; then
  for _ in $(seq 1 150); do
    if curl -fsS -m 1 "${PROXY_URL}/__5s__/status" >/dev/null 2>&1; then
      break
    fi
    sleep 0.02
  done
  curl -fsS -m 2 "${PROXY_URL}/app" > "$STATE_DIR/browser_app.html"
  python3 -c 'import time; print(int(time.monotonic()*1000))' > "$STATE_DIR/browser_ready.ts"
  while true; do
    sleep 1
  done
fi

PROXY_READY="async"
log_msg "5s-browser: proxy_ready=${PROXY_READY}, preparing Wayland & DRM..."

BASE_CHROMIUM_FLAGS=(
  "--app=${PROXY_URL}/app"
  "--kiosk"
  "--start-fullscreen"
  "--no-first-run"
  "--no-default-browser-check"
  "--disable-vulkan"
  "--renderer-process-limit=2"
  "--process-per-site"
  "--js-flags=--max-old-space-size=768"
  "--v8-cache-options=code"
  "--disk-cache-dir=${STATE_DIR}/chromium_cache"
  "--user-data-dir=${STATE_DIR}/chromium_profile"
  "--password-store=basic"
  "--use-mock-keychain"
  "--disable-notifications"
  "--disable-extensions"
  "--disable-component-update"
  "--disable-background-networking"
  "--disable-sync"
  "--disable-translate"
  "--disable-features=Vulkan,Translate,OptimizationHints,MediaRouter,DialMediaRouteProvider"
)

if [[ "$(id -u)" -eq 0 ]]; then
  BASE_CHROMIUM_FLAGS+=("--no-sandbox" "--test-type")
fi

export XDG_VTNR="${XDG_VTNR:-1}"
export WLR_LIBINPUT_NO_DEVICES="${WLR_LIBINPUT_NO_DEVICES:-1}"
export WLR_RENDERER_ALLOW_SOFTWARE="${WLR_RENDERER_ALLOW_SOFTWARE:-1}"

RUN_USER=""
RUN_UID=""
RUN_GID=""
SEATD_PID=""
DEFAULT_LIBSEAT_BACKEND="builtin"

if [[ "$(id -u)" -eq 0 ]]; then
  if id -u kiosk >/dev/null 2>&1; then
    RUN_USER="kiosk"
  elif id -u nobody >/dev/null 2>&1; then
    RUN_USER="nobody"
  fi

  if [[ -n "$RUN_USER" ]]; then
    RUN_UID="$(id -u "$RUN_USER")"
    RUN_GID="$(id -g "$RUN_USER")"
    HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6 || true)"
    export HOME="${HOME_DIR:-/home/$RUN_USER}"
    export XDG_RUNTIME_DIR="/run/user/${RUN_UID}"
    mkdir -p "$XDG_RUNTIME_DIR" "$HOME" /tmp /tmp/.X11-unix
    chmod 1777 /tmp /tmp/.X11-unix
    chown "${RUN_UID}:${RUN_GID}" "$XDG_RUNTIME_DIR" "$HOME"
    chmod 0700 "$XDG_RUNTIME_DIR"
    chown -R "${RUN_UID}:${RUN_GID}" "$STATE_DIR/chromium_cache" "$STATE_DIR/chromium_profile"
  else
    export HOME="${HOME:-/root}"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
    mkdir -p "$XDG_RUNTIME_DIR" "$HOME"
    chmod 0700 "$XDG_RUNTIME_DIR"
  fi

  if command -v seatd >/dev/null 2>&1; then
    rm -f /run/seatd.sock
    SEATD_GROUP="video"
    if [[ "$RUN_USER" == "nobody" ]] || ! getent group video >/dev/null 2>&1; then
      SEATD_GROUP="$(id -gn "${RUN_USER:-root}")"
    fi
    seatd -g "$SEATD_GROUP" >"$STATE_DIR/seatd.log" 2>&1 &
    SEATD_PID=$!
    for _ in $(seq 1 100); do
      [[ -S /run/seatd.sock ]] && break
      sleep 0.02
    done
    DEFAULT_LIBSEAT_BACKEND="seatd"
  fi
else
  export HOME="${HOME:-/tmp}"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  mkdir -p "$XDG_RUNTIME_DIR" "$HOME"
  chmod 0700 "$XDG_RUNTIME_DIR"
fi

export LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-$DEFAULT_LIBSEAT_BACKEND}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

if command -v dbus-daemon >/dev/null 2>&1 && [[ ! -S "${XDG_RUNTIME_DIR}/bus" ]]; then
  if [[ "$(id -u)" -eq 0 && -n "$RUN_UID" ]] && command -v setpriv >/dev/null 2>&1; then
    setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --init-groups \
      dbus-daemon --session --address="unix:path=${XDG_RUNTIME_DIR}/bus" --fork --nopidfile 2>/dev/null || true
  else
    dbus-daemon --session --address="unix:path=${XDG_RUNTIME_DIR}/bus" --fork --nopidfile 2>/dev/null || true
  fi
fi

if [[ ! -e /dev/dri/card0 && ! -e /dev/dri/card1 ]] && command -v modprobe >/dev/null 2>&1; then
  log_msg "5s-browser: running modprobe i915..."
  modprobe i915 2>&1 | while IFS= read -r line; do log_msg "modprobe i915: $line"; done || true
fi

for _ in $(seq 1 200); do
  if [[ -e /dev/dri/card0 || -e /dev/dri/card1 ]]; then
    break
  fi
  sleep 0.05
done

dump_debug_log() {
  local reason="${1:-snapshot}"
  local efi_log="/boot/efi/debug.log"
  local local_log="$STATE_DIR/debug.log"

  {
    echo "=== 5s-browser debug (${reason}) ==="
    echo "uptime: $(cat /proc/uptime 2>/dev/null || true)"
    echo "uname: $(uname -a 2>/dev/null || true)"
    echo "--- proxy status ---"
    curl -fsS -m 1 "${PROXY_URL}/__5s__/status" 2>&1 || echo "(proxy unreachable)"
    echo ""
    echo "--- devices (/dev/dri, /dev/input, /dev/fb*) ---"
    ls -la /dev/dri /dev/input /dev/fb* 2>&1 || true
    echo "--- processes ---"
    ps -eo pid,ppid,stat,comm,args 2>&1 || ps 2>&1 || true
    echo "--- cage.log (last 120 lines) ---"
    tail -n 120 "$STATE_DIR/cage.log" 2>&1 || echo "(no cage.log)"
    if [[ -f "$STATE_DIR/seatd.log" ]]; then
      echo "--- seatd.log (last 40 lines) ---"
      tail -n 40 "$STATE_DIR/seatd.log" 2>&1 || true
    fi
    echo "--- dmesg (last 80 lines) ---"
    dmesg 2>/dev/null | tail -n 80 || true
  } > "$local_log" 2>&1 || true

  if [[ ! -d /boot/efi/EFI ]] && [[ -e /dev/disk/by-label/5S-USB-EFI || -e /dev/disk/by-label/5S-EFI ]]; then
    mkdir -p /boot/efi
    mount /dev/disk/by-label/5S-USB-EFI /boot/efi 2>/dev/null || \
      mount /dev/disk/by-label/5S-EFI /boot/efi 2>/dev/null || true
  fi
  if [[ -d /boot/efi ]] && cp "$local_log" "$efi_log" 2>/dev/null; then
    sync 2>/dev/null || true
  fi
}

DRI_NODES="$(compgen -G '/dev/dri/card*' | tr '\n' ' ' || true)"
FB_NODES="$(compgen -G '/dev/fb*' | tr '\n' ' ' || true)"
log_msg "5s-browser: starting Cage + Chromium (user=${RUN_USER:-$(id -un)} backend=${LIBSEAT_BACKEND} dri=[${DRI_NODES:-none}] fb=[${FB_NODES:-none}] proxy=${PROXY_URL}/app)..."

run_cage_tier() {
  local tier="$1"
  shift
  local tier_flags=("${BASE_CHROMIUM_FLAGS[@]}" "$@")

  rm -f "${STATE_DIR}/chromium_profile/Singleton"* 2>/dev/null || true

  # shellcheck disable=SC2016
  local wrapper='
    /usr/bin/chromium "$@"
    rc=$?
    echo "5s-browser: chromium exited with code $rc" >&2
    exit "$rc"
  '

  set +e
  if [[ "$(id -u)" -eq 0 && -n "$RUN_UID" ]] && command -v setpriv >/dev/null 2>&1; then
    setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --init-groups \
      /usr/bin/cage -d -s -- /bin/sh -c "$wrapper" _ "${tier_flags[@]}" >"$STATE_DIR/cage.log" 2>&1 &
  else
    /usr/bin/cage -d -s -- /bin/sh -c "$wrapper" _ "${tier_flags[@]}" >"$STATE_DIR/cage.log" 2>&1 &
  fi
  CAGE_PID=$!

  (
    sleep 5
    kill -0 "$CAGE_PID" 2>/dev/null && dump_debug_log "5s-${tier}"
    sleep 7
    if kill -0 "$CAGE_PID" 2>/dev/null && ! pidof chromium >/dev/null 2>&1; then
      log_msg "5s-browser: watchdog: chromium not running after 12s; last cage.log lines:"
      while IFS= read -r line; do
        log_msg "  [cage] $line"
      done < <(tail -n 20 "$STATE_DIR/cage.log" 2>/dev/null || true)
    fi
    sleep 3
    kill -0 "$CAGE_PID" 2>/dev/null && dump_debug_log "15s-${tier}"
  ) >/dev/null 2>&1 &
  WATCHDOG_PID=$!

  local t_start
  t_start="$(date +%s)"
  wait "$CAGE_PID"
  RC=$?
  local t_end
  t_end="$(date +%s)"
  ELAPSED=$(( t_end - t_start ))

  kill "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  set -e

  CHROMIUM_RC="$(grep -oE 'chromium exited with code [0-9]+' "$STATE_DIR/cage.log" 2>/dev/null | tail -n 1 | awk '{print $NF}' || true)"
  if [[ "$RC" -eq 0 && ( -z "$CHROMIUM_RC" || "$CHROMIUM_RC" -eq 0 ) && "$ELAPSED" -ge 8 ]]; then
    return 0
  fi
  log_msg "5s-browser: tier '${tier}' ended after ${ELAPSED}s (cage_rc=${RC}, chromium_rc=${CHROMIUM_RC:-unknown}). Last log lines:"
  while IFS= read -r line; do
    log_msg "  [cage] $line"
  done < <(tail -n 25 "$STATE_DIR/cage.log" 2>/dev/null || true)
  return 1
}

FINAL_RC=1
if run_cage_tier "wayland-vaapi" "--ozone-platform=wayland" "--enable-features=UseOzonePlatform,VaapiVideoDecoder" "--enable-gpu-rasterization"; then
  FINAL_RC=0
elif run_cage_tier "x11-vaapi" "--ozone-platform=x11" "--enable-features=VaapiVideoDecoder"; then
  FINAL_RC=0
elif run_cage_tier "x11-software" "--ozone-platform=x11" "--disable-gpu"; then
  FINAL_RC=0
fi

if [[ -n "$SEATD_PID" ]]; then
  kill "$SEATD_PID" 2>/dev/null || true
  wait "$SEATD_PID" 2>/dev/null || true
fi

dump_debug_log "exit-${FINAL_RC}"
exit "$FINAL_RC"
