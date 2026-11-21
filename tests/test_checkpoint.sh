#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
INIT_PID=""
cleanup() {
  if [[ -n "$INIT_PID" ]]; then
    kill -TERM "$INIT_PID" 2>/dev/null || true
    wait "$INIT_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

make -s -C "$ROOT_DIR" build

STATE_DIR="$TMP_DIR/state"
FB_MOCK="$TMP_DIR/fb0"
BIN_DIR="$ROOT_DIR/build/bin"
mkdir -p "$STATE_DIR"
touch "$STATE_DIR/wifi_configured"

# Seed mock 1,228,800-byte framebuffer
python3 - "$FB_MOCK" <<'PYEOF'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"\x12\x34" * (1228800 // 2))
PYEOF
cp "$FB_MOCK" "$TMP_DIR/fb0.orig"

now_ms() {
  python3 -c 'import time; print(int(time.monotonic() * 1000))'
}

export MOCK_MODE=1
export FB_DEVICE="$FB_MOCK"
export BIN_DIR

# 1. Run shutdown checkpoint
t0="$(now_ms)"
"$BIN_DIR/5s-checkpoint.sh" --shutdown --state-dir "$STATE_DIR"
t1="$(now_ms)"
ckpt_ms=$((t1 - t0))

if [[ "$ckpt_ms" -ge 1000 ]]; then
  echo "ERROR: checkpoint took ${ckpt_ms}ms (>= 1000ms)"
  exit 1
fi

[[ -f "$STATE_DIR/last_frame.fb" ]] || { echo "ERROR: missing last_frame.fb"; exit 1; }
[[ -f "$STATE_DIR/net/last_lease.env" ]] || { echo "ERROR: missing last_lease.env"; exit 1; }
[[ -f "$STATE_DIR/checkpoint.manifest" ]] || { echo "ERROR: missing checkpoint.manifest"; exit 1; }

# Zero out mock framebuffer before simulated cold boot
truncate -s 0 "$FB_MOCK"
truncate -s 1228800 "$FB_MOCK"

# 2. Simulate cold boot via 5s-init --test-mode
boot_start="$(now_ms)"
"$BIN_DIR/5s-init" --test-mode --state-dir "$STATE_DIR" &
INIT_PID=$!

# Assert framebuffer restored < 100ms
fb_restored=0
for _ in $(seq 1 50); do
  if cmp -s "$TMP_DIR/fb0.orig" "$FB_MOCK"; then
    fb_restored=1
    break
  fi
  sleep 0.005
done
fb_ms=$(($(now_ms) - boot_start))
if [[ "$fb_restored" -ne 1 || "$fb_ms" -ge 100 ]]; then
  echo "ERROR: framebuffer restore failed or too slow (${fb_ms}ms)"
  exit 1
fi

# Assert browser /app interactive HTTP 200 and background network online < 1500ms
e2e_ok=0
for _ in $(seq 1 150); do
  if [[ -f "$STATE_DIR/browser_app.html" ]]; then
    status_json="$(curl -fsS "http://127.0.0.1:8555/__5s__/status" 2>/dev/null || true)"
    if echo "$status_json" | grep -q '"online": true'; then
      e2e_ok=1
      break
    fi
  fi
  sleep 0.01
done
e2e_ms=$(($(now_ms) - boot_start))

if [[ "$e2e_ok" -ne 1 || "$e2e_ms" -ge 1500 ]]; then
  echo "ERROR: E2E boot-to-interactive+online failed or too slow (${e2e_ms}ms)"
  exit 1
fi

kill -TERM "$INIT_PID"
wait "$INIT_PID"
INIT_PID=""

echo "test_checkpoint: shutdown=${ckpt_ms}ms, fb_restore=${fb_ms}ms, e2e_interactive=${e2e_ms}ms (<1500ms budget)"
