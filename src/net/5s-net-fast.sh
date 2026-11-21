#!/usr/bin/env bash
set -euo pipefail

ACTION=""
STATE_DIR="${STATE_DIR:-/var/cache/5s}"
WLAN_IF="${WLAN_IF:-wlan0}"
PROXY_URL="${PROXY_URL:-http://127.0.0.1:8555}"
MOCK_MODE="${MOCK_MODE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot)
      ACTION="boot"
      shift
      ;;
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

NET_DIR="$STATE_DIR/net"
mkdir -p "$NET_DIR"

DOMAINS=(
  "mail.google.com"
  "www.youtube.com"
  "i.ytimg.com"
  "googlevideo.com"
)

resolve_domain() {
  local dom="$1"
  if [[ "$MOCK_MODE" == "1" ]]; then
    echo "142.250.185.10"
    return 0
  fi
  getent ahostsv4 "$dom" 2>/dev/null | awk 'NR==1{print $1}' || true
}

do_shutdown() {
  local cached_ip=""
  local cached_gw=""
  local cached_ssid=""

  if [[ "$MOCK_MODE" == "1" ]]; then
    cached_ip="192.168.1.42/24"
    cached_gw="192.168.1.1"
    cached_ssid="HomeWiFi"
  else
    cached_ip="$(ip -4 -o addr show dev "$WLAN_IF" 2>/dev/null | awk 'NR==1{print $4}' || true)"
    cached_gw="$(ip -4 route show default dev "$WLAN_IF" 2>/dev/null | awk 'NR==1{print $3}' || true)"
    cached_ssid="$(iwctl station "$WLAN_IF" show 2>/dev/null | awk -F'Connected network' 'NF>1{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' || true)"
  fi

  cat > "$NET_DIR/last_lease.env" <<EOF
WLAN_IF=${WLAN_IF}
CACHED_IP=${cached_ip}
CACHED_GW=${cached_gw}
CACHED_SSID=${cached_ssid}
EOF

  : > "$NET_DIR/hosts.cache.tmp"
  for d in "${DOMAINS[@]}"; do
    local ip
    ip="$(resolve_domain "$d")"
    if [[ -n "$ip" ]]; then
      echo "$ip $d" >> "$NET_DIR/hosts.cache.tmp"
    fi
  done
  mv "$NET_DIR/hosts.cache.tmp" "$NET_DIR/hosts.cache"
}

merge_hosts_cache() {
  local hosts_cache="$NET_DIR/hosts.cache"
  [[ -f "$hosts_cache" ]] || return 0
  cp "$hosts_cache" "$NET_DIR/active_hosts"

  if [[ "$MOCK_MODE" != "1" && "$(id -u)" == "0" && -w /etc/hosts ]]; then
    local tmp_hosts
    tmp_hosts="$(mktemp)"
    awk '
      /^# BEGIN 5S-CACHE$/ { skip=1; next }
      /^# END 5S-CACHE$/ { skip=0; next }
      !skip { print }
    ' /etc/hosts > "$tmp_hosts"
    {
      echo "# BEGIN 5S-CACHE"
      cat "$hosts_cache"
      echo "# END 5S-CACHE"
    } >> "$tmp_hosts"
    mv "$tmp_hosts" /etc/hosts
  fi
}

notify_proxy_online() {
  for _ in $(seq 1 40); do
    if curl -fsS -m 1 -X POST "${PROXY_URL}/__5s__/net-online" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.02
  done
  return 0
}

do_boot() {
  merge_hosts_cache

  if [[ -f "$NET_DIR/last_lease.env" ]]; then
    # shellcheck disable=SC1091
    source "$NET_DIR/last_lease.env"
  fi

  if [[ "$MOCK_MODE" != "1" ]]; then
    ip link set "$WLAN_IF" up 2>/dev/null || true
    if [[ -n "${CACHED_IP:-}" ]]; then
      ip addr replace "$CACHED_IP" dev "$WLAN_IF" 2>/dev/null || true
    fi
    if [[ -n "${CACHED_GW:-}" ]]; then
      ip route replace default via "$CACHED_GW" dev "$WLAN_IF" 2>/dev/null || true
    fi
    if [[ -n "${CACHED_SSID:-}" ]] && command -v iwctl >/dev/null 2>&1; then
      iwctl station "$WLAN_IF" connect "$CACHED_SSID" >/dev/null 2>&1 &
    fi
    if command -v dhcpcd >/dev/null 2>&1; then
      dhcpcd -4 -q --noarp "$WLAN_IF" >/dev/null 2>&1 &
    fi
    # Wait briefly for gateway/internet reachability before notifying proxy
    for _ in $(seq 1 50); do
      if [[ -n "${CACHED_GW:-}" ]] && ping -c 1 -W 1 "$CACHED_GW" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
  fi

  notify_proxy_online
}

case "$ACTION" in
  shutdown)
    do_shutdown
    ;;
  boot)
    do_boot
    ;;
  *)
    echo "Usage: $0 --boot|--shutdown [--state-dir <dir>]" >&2
    exit 2
    ;;
esac
