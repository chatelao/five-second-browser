#!/usr/bin/env bash
set -euo pipefail

ACTION=""
STATE_DIR="${STATE_DIR:-/var/cache/5s}"
PROXY_URL="${PROXY_URL:-http://127.0.0.1:8555}"
MOCK_MODE="${MOCK_MODE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shutdown)
      ACTION="shutdown"
      shift
      ;;
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

if [[ "$ACTION" != "shutdown" ]]; then
  echo "Usage: $0 --shutdown [--state-dir <dir>]" >&2
  exit 2
fi

mkdir -p "$STATE_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BIN_DIR:-$SCRIPT_DIR}"

# 1. Stop any active disc playback and flush SQLite WAL & app state via proxy (<= 150ms)
curl -fsS -m 1 -X POST "${PROXY_URL}/__5s__/disc/stop" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1 || true
curl -fsS -m 1 -X POST "${PROXY_URL}/__5s__/snapshot" -H "Content-Type: application/json" -d '{}' >/dev/null 2>&1 || true

# 2. Capture framebuffer (<= 40ms) and save per-profile copy if active_profile is set
SPLASH_BIN="$BIN_DIR/5s-fb-splash"
if [[ -x "$SPLASH_BIN" ]]; then
  "$SPLASH_BIN" --capture "$STATE_DIR/last_frame.fb"
  if [[ -f "$STATE_DIR/active_profile" ]]; then
    ACTIVE_PROF="$(tr -d '[:space:]' < "$STATE_DIR/active_profile" 2>/dev/null || true)"
    if [[ "$ACTIVE_PROF" =~ ^p[1-5]$ && -f "$STATE_DIR/last_frame.fb" ]]; then
      cp -f "$STATE_DIR/last_frame.fb" "$STATE_DIR/last_frame_${ACTIVE_PROF}.fb" 2>/dev/null || true
    fi
  fi
fi

# 3. Save wlan0 lease & DNS cache (<= 40ms)
NET_SCRIPT="$BIN_DIR/5s-net-fast.sh"
if [[ ! -x "$NET_SCRIPT" ]]; then
  NET_SCRIPT="$(cd "$SCRIPT_DIR/../net" 2>/dev/null && pwd)/5s-net-fast.sh"
fi
if [[ -x "$NET_SCRIPT" ]]; then
  MOCK_MODE="$MOCK_MODE" "$NET_SCRIPT" --shutdown --state-dir "$STATE_DIR"
fi

# 4. Write completion manifest
FRAME_SHA256="none"
FRAME_BYTES=0
if [[ -f "$STATE_DIR/last_frame.fb" ]]; then
  FRAME_BYTES="$(stat -c%s "$STATE_DIR/last_frame.fb")"
  FRAME_SHA256="$(sha256sum "$STATE_DIR/last_frame.fb" | awk '{print $1}')"
fi

cat > "$STATE_DIR/checkpoint.manifest" <<EOF
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FRAME_BYTES=${FRAME_BYTES}
FRAME_SHA256=${FRAME_SHA256}
EOF

sync
