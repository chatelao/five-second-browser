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

CHROMIUM_FLAGS=(
  "--app=${PROXY_URL}/app"
  "--kiosk"
  "--start-fullscreen"
  "--no-first-run"
  "--no-default-browser-check"
  "--ozone-platform=wayland"
  "--enable-features=UseOzonePlatform,VaapiVideoDecoder,VaapiVideoEncoder,CanvasOopRasterization"
  "--ignore-gpu-blocklist"
  "--enable-gpu-rasterization"
  "--enable-zero-copy"
  "--renderer-process-limit=2"
  "--process-per-site"
  "--js-flags=--max-old-space-size=768"
  "--v8-cache-options=code"
  "--disk-cache-dir=${STATE_DIR}/chromium_cache"
  "--user-data-dir=${STATE_DIR}/chromium_profile"
  "--disable-extensions"
  "--disable-component-update"
  "--disable-background-networking"
  "--disable-sync"
  "--disable-translate"
  "--disable-features=Translate,OptimizationHints,MediaRouter,DialMediaRouteProvider"
)

if [[ "$(id -u)" -eq 0 ]]; then
  CHROMIUM_FLAGS+=("--no-sandbox" "--test-type")
fi

export HOME="${HOME:-/root}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_VTNR="${XDG_VTNR:-1}"
export LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-builtin}"
export WLR_LIBINPUT_NO_DEVICES="${WLR_LIBINPUT_NO_DEVICES:-1}"
export WLR_RENDERER_ALLOW_SOFTWARE="${WLR_RENDERER_ALLOW_SOFTWARE:-1}"
mkdir -p "$XDG_RUNTIME_DIR" "$HOME"
chmod 0700 "$XDG_RUNTIME_DIR"

if [[ ! -e /dev/dri/card0 && ! -e /dev/dri/card1 ]] && command -v modprobe >/dev/null 2>&1; then
  log_msg "5s-browser: running modprobe i915..."
  modprobe i915 2>&1 | while IFS= read -r line; do log_msg "modprobe i915: $line"; done || true
fi

for _ in $(seq 1 100); do
  if [[ -e /dev/dri/card0 || -e /dev/dri/card1 ]]; then
    break
  fi
  sleep 0.05
done

DRI_NODES="$(compgen -G '/dev/dri/card*' | tr '\n' ' ' || true)"
FB_NODES="$(compgen -G '/dev/fb*' | tr '\n' ' ' || true)"
log_msg "5s-browser: starting Cage + Chromium (dri=[${DRI_NODES:-none}] fb=[${FB_NODES:-none}] proxy=${PROXY_URL}/app)..."

set +e
/usr/bin/cage -s -- /usr/bin/chromium "${CHROMIUM_FLAGS[@]}" >"$STATE_DIR/cage.log" 2>&1
RC=$?
set -e
log_msg "5s-browser: cage exited with code ${RC}. Last log lines:"
while IFS= read -r line; do
  log_msg "  [cage] $line"
done < <(tail -n 25 "$STATE_DIR/cage.log" 2>/dev/null || true)
exit "$RC"
