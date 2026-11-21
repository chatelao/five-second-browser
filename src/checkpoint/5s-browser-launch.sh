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

mkdir -p "$STATE_DIR/chromium_cache" "$STATE_DIR/chromium_profile"

# Wait for local SQLite WAL proxy to accept connections
for _ in $(seq 1 100); do
  if curl -fsS -m 1 "${PROXY_URL}/__5s__/status" >/dev/null 2>&1; then
    break
  fi
  sleep 0.01
done

if [[ "$MOCK_MODE" == "1" ]]; then
  curl -fsS -m 2 "${PROXY_URL}/app" > "$STATE_DIR/browser_app.html"
  python3 -c 'import time; print(int(time.monotonic()*1000))' > "$STATE_DIR/browser_ready.ts"
  while true; do
    sleep 1
  done
fi

CHROMIUM_FLAGS=(
  "--app=${PROXY_URL}/app"
  "--kiosk"
  "--start-fullscreen"
  "--no-first-run"
  "--no-default-browser-check"
  "--enable-features=VaapiVideoDecoder,VaapiVideoEncoder,CanvasOopRasterization"
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
  CHROMIUM_FLAGS+=("--no-sandbox")
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_VTNR="${XDG_VTNR:-1}"
export LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-builtin}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

exec taskset -c 0,2 /usr/bin/cage -s -- /usr/bin/chromium "${CHROMIUM_FLAGS[@]}"
