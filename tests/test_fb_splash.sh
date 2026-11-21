#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPLASH_BIN="$ROOT_DIR/build/bin/5s-fb-splash"

# Use RAM-backed /dev/shm when available to model /dev/fb0 VRAM (avoids ext4 disk jitter)
if [[ -d /dev/shm && -w /dev/shm ]]; then
  TMP_DIR="$(mktemp -d /dev/shm/5s-fb.XXXXXX)"
  DEFAULT_MAX_MS=50
else
  TMP_DIR="$(mktemp -d)"
  DEFAULT_MAX_MS=150
fi
trap 'rm -rf "$TMP_DIR"' EXIT

MAX_FB_MS="${MAX_FB_MS:-$DEFAULT_MAX_MS}"
FRAME_BYTES=1228800
FB_MOCK="$TMP_DIR/fb0"
SNAP_FILE="$TMP_DIR/last_frame.fb"

# Create deterministic 1,228,800-byte non-sparse test framebuffer pattern
python3 - "$FB_MOCK" "$FRAME_BYTES" <<'PYEOF'
import sys
path, size = sys.argv[1], int(sys.argv[2])
pattern = bytes(range(256))
with open(path, "wb") as f:
    f.write((pattern * (size // len(pattern) + 1))[:size])
PYEOF

cp "$FB_MOCK" "$TMP_DIR/fb0.orig"

now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local ts="$EPOCHREALTIME"
    local sec="${ts%.*}"
    local usec="${ts#*.}"
    printf '%s%s\n' "$sec" "${usec:0:3}"
  else
    date +%s%3N
  fi
}

# Unmeasured warm-up to page-in binary and shared libraries
FB_DEVICE="$FB_MOCK" "$SPLASH_BIN" --capture "$SNAP_FILE"

t0="$(now_ms)"
FB_DEVICE="$FB_MOCK" "$SPLASH_BIN" --capture "$SNAP_FILE"
t1="$(now_ms)"
cap_ms=$((10#$t1 - 10#$t0))

if [[ "$cap_ms" -ge "$MAX_FB_MS" ]]; then
  echo "ERROR: capture took ${cap_ms} ms (>= ${MAX_FB_MS} ms)"
  exit 1
fi

# Zero out mock framebuffer in-place (non-sparse)
dd if=/dev/zero of="$FB_MOCK" bs="$FRAME_BYTES" count=1 conv=notrunc status=none

t2="$(now_ms)"
FB_DEVICE="$FB_MOCK" "$SPLASH_BIN" --restore "$SNAP_FILE"
t3="$(now_ms)"
res_ms=$((10#$t3 - 10#$t2))

if [[ "$res_ms" -ge "$MAX_FB_MS" ]]; then
  echo "ERROR: restore took ${res_ms} ms (>= ${MAX_FB_MS} ms)"
  exit 1
fi

if ! cmp -s "$TMP_DIR/fb0.orig" "$FB_MOCK"; then
  echo "ERROR: restored framebuffer does not match original"
  exit 1
fi

echo "test_fb_splash: capture=${cap_ms}ms restore=${res_ms}ms (pixel-identical, limit=${MAX_FB_MS}ms)"
