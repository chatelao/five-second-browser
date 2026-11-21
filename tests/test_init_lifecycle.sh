#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_MOCK="$TMP_DIR/bin"
STATE_DIR="$TMP_DIR/state"
mkdir -p "$BIN_MOCK" "$STATE_DIR"

cp "$ROOT_DIR/build/bin/5s-fb-splash" "$BIN_MOCK/5s-fb-splash"
cp "$ROOT_DIR/build/bin/5s-init" "$BIN_MOCK/5s-init"

# Prepare mock framebuffer and snapshot
FRAME_BYTES=1228800
FB_MOCK="$TMP_DIR/fb0"
python3 - "$STATE_DIR/last_frame.fb" "$FRAME_BYTES" <<'PYEOF'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"\xab\xcd" * (int(sys.argv[2]) // 2))
PYEOF
truncate -s "$FRAME_BYTES" "$FB_MOCK"

EVENTS_LOG="$TMP_DIR/events.log"

cat > "$BIN_MOCK/cache_proxy.py" <<EOF
#!/usr/bin/env bash
echo "proxy" >> "$EVENTS_LOG"
sleep 5
EOF

cat > "$BIN_MOCK/5s-net-fast.sh" <<EOF
#!/usr/bin/env bash
echo "net" >> "$EVENTS_LOG"
EOF

cat > "$BIN_MOCK/5s-browser-launch.sh" <<EOF
#!/usr/bin/env bash
echo "browser" >> "$EVENTS_LOG"
sleep 5
EOF

cat > "$BIN_MOCK/5s-checkpoint.sh" <<EOF
#!/usr/bin/env bash
echo "shutdown" >> "$EVENTS_LOG"
touch "$STATE_DIR/checkpoint.manifest"
EOF

chmod +x "$BIN_MOCK"/*

FB_DEVICE="$FB_MOCK" BIN_DIR="$BIN_MOCK" \
  "$BIN_MOCK/5s-init" --test-mode --state-dir "$STATE_DIR" &
INIT_PID=$!

# Wait briefly for children to log startup
for _ in $(seq 1 40); do
  if [[ -f "$EVENTS_LOG" ]] && grep -q "browser" "$EVENTS_LOG" && grep -q "proxy" "$EVENTS_LOG"; then
    break
  fi
  sleep 0.05
done

if ! cmp -s "$STATE_DIR/last_frame.fb" "$FB_MOCK"; then
  kill -9 "$INIT_PID" 2>/dev/null || true
  echo "ERROR: framebuffer was not restored by 5s-init"
  exit 1
fi

kill -TERM "$INIT_PID"
wait "$INIT_PID"

if [[ ! -f "$STATE_DIR/checkpoint.manifest" ]]; then
  echo "ERROR: SIGTERM did not trigger shutdown checkpoint"
  exit 1
fi

echo "test_init_lifecycle: framebuffer restored, Track A/B spawned, SIGTERM checkpoint verified"
