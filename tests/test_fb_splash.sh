#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPLASH_BIN="$ROOT_DIR/build/bin/5s-fb-splash"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FRAME_BYTES=1228800
FB_MOCK="$TMP_DIR/fb0"
SNAP_FILE="$TMP_DIR/last_frame.fb"

# Create deterministic 1,228,800-byte test framebuffer pattern
python3 - "$FB_MOCK" "$FRAME_BYTES" <<'PYEOF'
import sys
path, size = sys.argv[1], int(sys.argv[2])
pattern = bytes(range(256))
with open(path, "wb") as f:
    f.write((pattern * (size // len(pattern) + 1))[:size])
PYEOF

cp "$FB_MOCK" "$TMP_DIR/fb0.orig"

now_ms() {
  date +%s%3N
}

t0="$(now_ms)"
FB_DEVICE="$FB_MOCK" "$SPLASH_BIN" --capture "$SNAP_FILE"
t1="$(now_ms)"
cap_ms=$((t1 - t0))

if [[ "$cap_ms" -ge 50 ]]; then
  echo "ERROR: capture took ${cap_ms} ms (>= 50 ms)"
  exit 1
fi

# Zero out mock framebuffer
truncate -s 0 "$FB_MOCK"
truncate -s "$FRAME_BYTES" "$FB_MOCK"

t2="$(now_ms)"
FB_DEVICE="$FB_MOCK" "$SPLASH_BIN" --restore "$SNAP_FILE"
t3="$(now_ms)"
res_ms=$((t3 - t2))

if [[ "$res_ms" -ge 50 ]]; then
  echo "ERROR: restore took ${res_ms} ms (>= 50 ms)"
  exit 1
fi

if ! cmp -s "$TMP_DIR/fb0.orig" "$FB_MOCK"; then
  echo "ERROR: restored framebuffer does not match original"
  exit 1
fi

echo "test_fb_splash: capture=${cap_ms}ms restore=${res_ms}ms (pixel-identical)"
