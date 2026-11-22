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

t0="$(date +%s%3N)"
MOCK_MODE=1 PROXY_URL="http://127.0.0.1:${PORT}" "$NET_SCRIPT" --boot --state-dir "$TMP_DIR"
t1="$(date +%s%3N)"
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

cat > "$TMP_DIR/wifi.txt" <<'EOF'
ENABLE_GMAIL=false
ENABLE_YOUTUBE=0
ENABLE_DISC=yes
EOF

IWD_DIR="$TMP_DIR/iwd" MOCK_MODE=1 PROXY_URL="http://127.0.0.1:${PORT}" \
  "$NET_SCRIPT" --boot --state-dir "$TMP_DIR"

[[ -f "$TMP_DIR/features.json" ]] || { echo "ERROR: features.json not created from wifi.txt"; exit 1; }
python3 - "$TMP_DIR/features.json" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
assert data == {"gmail": False, "youtube": False, "disc": True}, data
PYEOF

cat > "$TMP_DIR/wifi.txt" <<'EOF'
SSID=ExternalHome5G
PASSWORD=SuperSecret123!
ENABLE_GMAIL=true
ENABLE_YOUTUBE=false
ENABLE_DISC=off
EOF

IWD_DIR="$TMP_DIR/iwd" MOCK_MODE=1 PROXY_URL="http://127.0.0.1:${PORT}" \
  "$NET_SCRIPT" --boot --state-dir "$TMP_DIR"

[[ -f "$TMP_DIR/iwd/ExternalHome5G.psk" ]] || { echo "ERROR: ExternalHome5G.psk not created from wifi.txt"; exit 1; }
grep -q "Passphrase=SuperSecret123!" "$TMP_DIR/iwd/ExternalHome5G.psk" || { echo "ERROR: Passphrase missing in .psk"; exit 1; }
grep -qx "ExternalHome5G" "$TMP_DIR/wifi_configured" || { echo "ERROR: wifi_configured not updated from wifi.txt"; exit 1; }
grep -q "NETWORK_FOUND=yes" "$TMP_DIR/logs/network.log" || { echo "ERROR: NETWORK_FOUND=yes missing from network.log"; exit 1; }
grep -q "CONNECTION_ESTABLISHED=yes" "$TMP_DIR/logs/network.log" || { echo "ERROR: CONNECTION_ESTABLISHED=yes missing from network.log"; exit 1; }
python3 - "$TMP_DIR/features.json" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
assert data == {"gmail": True, "youtube": False, "disc": False}, data
PYEOF

echo "test_net_fast: shutdown cache + boot preload + wifi.txt import + network.log + feature toggles + proxy online transition in ${elapsed}ms"
