#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

NET_SCRIPT="$ROOT_DIR/src/net/5s-net-fast.sh"
PROXY_SCRIPT="$ROOT_DIR/src/proxy/cache_proxy.py"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

# 1. Test --shutdown state persistence
MOCK_MODE=1 "$NET_SCRIPT" --shutdown --state-dir "$TMP_DIR"

[[ -f "$TMP_DIR/net/last_lease.env" ]] || { echo "ERROR: missing last_lease.env"; exit 1; }
[[ -f "$TMP_DIR/net/hosts.cache" ]] || { echo "ERROR: missing hosts.cache"; exit 1; }

for dom in mail.google.com www.youtube.com i.ytimg.com googlevideo.com; do
  if ! grep -q "$dom" "$TMP_DIR/net/hosts.cache"; then
    echo "ERROR: domain $dom missing from hosts.cache"
    exit 1
  fi
done

# 2. Test --boot signaling offline proxy -> online in < 500ms
python3 "$PROXY_SCRIPT" --state-dir "$TMP_DIR" --port "$PORT" --offline &
PROXY_PID=$!
trap 'kill "$PROXY_PID" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT

# Wait for proxy port
python3 - "$PORT" <<'PYEOF'
import socket, sys, time
p = int(sys.argv[1])
deadline = time.monotonic() + 3.0
while time.monotonic() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", p), timeout=0.2):
            sys.exit(0)
    except OSError:
        time.sleep(0.02)
sys.exit(1)
PYEOF

t0="$(python3 -c 'import time; print(int(time.monotonic()*1000))')"
MOCK_MODE=1 PROXY_URL="http://127.0.0.1:${PORT}" "$NET_SCRIPT" --boot --state-dir "$TMP_DIR"
t1="$(python3 -c 'import time; print(int(time.monotonic()*1000))')"
elapsed=$((t1 - t0))

if [[ "$elapsed" -ge 500 ]]; then
  echo "ERROR: net-fast --boot took ${elapsed}ms (>= 500ms)"
  exit 1
fi

[[ -f "$TMP_DIR/net/active_hosts" ]] || { echo "ERROR: active_hosts not created"; exit 1; }

status_json="$(curl -fsS "http://127.0.0.1:${PORT}/__5s__/status")"
if ! echo "$status_json" | grep -q '"online": true'; then
  echo "ERROR: proxy status did not become online: $status_json"
  exit 1
fi

echo "test_net_fast: shutdown cache + boot preload + proxy online transition in ${elapsed}ms"
