#!/usr/bin/env bash
set -euo pipefail

ACTION=""
CONNECT_SSID=""
STATE_DIR="${STATE_DIR:-/var/cache/5s}"
PROXY_URL="${PROXY_URL:-http://127.0.0.1:8555}"
MOCK_MODE="${MOCK_MODE:-0}"

detect_wlan_if() {
  local cand
  for cand in /sys/class/net/wl*; do
    if [[ -e "$cand" ]]; then
      basename "$cand"
      return 0
    fi
  done
  echo "wlan0"
}

WLAN_IF="${WLAN_IF:-$(detect_wlan_if)}"

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
    --connect)
      ACTION="connect"
      CONNECT_SSID="$2"
      shift 2
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

import_external_wifi_config() {
  local wifi_file=""
  for cand in "$STATE_DIR/wifi.txt" /boot/efi/wifi.txt /boot/efi/WIFI.TXT; do
    if [[ -f "$cand" ]]; then
      wifi_file="$cand"
      break
    fi
  done

  if [[ "$MOCK_MODE" != "1" && -z "$wifi_file" ]] && [[ -e /dev/disk/by-label/5S-USB-EFI || -e /dev/disk/by-label/5S-EFI ]]; then
    mkdir -p /boot/efi
    mount /dev/disk/by-label/5S-USB-EFI /boot/efi 2>/dev/null || \
      mount /dev/disk/by-label/5S-EFI /boot/efi 2>/dev/null || true
    for cand in /boot/efi/wifi.txt /boot/efi/WIFI.TXT; do
      if [[ -f "$cand" ]]; then
        wifi_file="$cand"
        break
      fi
    done
  fi

  [[ -n "$wifi_file" && -f "$wifi_file" ]] || return 0

  local ext_ssid=""
  local ext_pass=""
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="${raw_line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^SSID=(.*)$ ]]; then
      ext_ssid="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^PASSWORD=(.*)$ || "$line" =~ ^PSK=(.*)$ || "$line" =~ ^PASS=(.*)$ ]]; then
      ext_pass="${BASH_REMATCH[1]}"
    elif [[ -z "$ext_ssid" ]]; then
      ext_ssid="$line"
    elif [[ -z "$ext_pass" ]]; then
      ext_pass="$line"
    fi
  done < "$wifi_file"

  [[ -n "$ext_ssid" ]] || return 0

  echo "5s-net: importing Wi-Fi credentials for SSID '$ext_ssid' from $wifi_file"
  local iwd_dir="${IWD_DIR:-/var/lib/iwd}"
  mkdir -p "$iwd_dir"
  local psk_path="$iwd_dir/${ext_ssid}.psk"
  umask 0077
  if [[ -n "$ext_pass" ]]; then
    printf '[Security]\nPassphrase=%s\n\n[Settings]\nAutoConnect=true\n' "$ext_pass" > "$psk_path"
  else
    printf '[Settings]\nAutoConnect=true\n' > "$psk_path"
  fi
  printf '%s\n' "$ext_ssid" > "$STATE_DIR/wifi_configured"
  CACHED_SSID="$ext_ssid"
}

do_boot() {
  merge_hosts_cache

  if [[ -f "$NET_DIR/last_lease.env" ]]; then
    # shellcheck disable=SC1091
    source "$NET_DIR/last_lease.env"
  fi

  import_external_wifi_config

  if [[ "$MOCK_MODE" != "1" ]]; then
    if command -v rfkill >/dev/null 2>&1; then
      rfkill unblock wifi >/dev/null 2>&1 || true
    fi
    if [[ -x /usr/libexec/iwd ]] && ! pidof iwd >/dev/null 2>&1; then
      mkdir -p /var/lib/iwd
      /usr/libexec/iwd >/dev/null 2>&1 &
      sleep 0.2
    fi
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

  if [[ "$MOCK_MODE" != "1" ]] && command -v modprobe >/dev/null 2>&1; then
    (sleep 2; modprobe snd_hda_intel >/dev/null 2>&1 || true) &
  fi
}

do_connect() {
  if [[ -z "$CONNECT_SSID" ]]; then
    echo "ERROR: --connect requires an SSID" >&2
    exit 2
  fi
  if [[ "$MOCK_MODE" != "1" ]]; then
    if [[ -x /usr/libexec/iwd ]] && ! pidof iwd >/dev/null 2>&1; then
      mkdir -p /var/lib/iwd
      /usr/libexec/iwd >/dev/null 2>&1 &
      sleep 0.2
    fi
    ip link set "$WLAN_IF" up 2>/dev/null || true
    if command -v iwctl >/dev/null 2>&1; then
      iwctl station "$WLAN_IF" connect "$CONNECT_SSID" || true
    fi
    if command -v dhcpcd >/dev/null 2>&1; then
      dhcpcd -4 -q --noarp "$WLAN_IF" || true
    fi
  fi
  do_shutdown
  merge_hosts_cache
  notify_proxy_online
}

case "$ACTION" in
  shutdown)
    do_shutdown
    ;;
  boot)
    do_boot
    ;;
  connect)
    do_connect
    ;;
  *)
    echo "Usage: $0 --boot|--shutdown|--connect <ssid> [--state-dir <dir>]" >&2
    exit 2
    ;;
esac
