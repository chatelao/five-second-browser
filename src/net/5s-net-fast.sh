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
  return 1
}

WLAN_IF="${WLAN_IF:-}"

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
LOCAL_LOG_DIR="$STATE_DIR/logs"
mkdir -p "$NET_DIR" "$LOCAL_LOG_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USB_LOG_SH=""
for _cand in "$SCRIPT_DIR/5s-usb-log.sh" "$SCRIPT_DIR/../config/5s-usb-log.sh" "/opt/5s-browser/bin/5s-usb-log.sh"; do
  if [[ -f "$_cand" ]]; then
    USB_LOG_SH="$_cand"
    break
  fi
done
if [[ -n "$USB_LOG_SH" ]]; then
  # shellcheck source=/dev/null
  source "$USB_LOG_SH"
else
  usb_log() {
    printf '[%s] %s\n' "${1:-network}" "${2:-}" >> "$LOCAL_LOG_DIR/network.log" 2>/dev/null || true
  }
  sync_usb_logs() { :; }
fi

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
  if command -v timeout >/dev/null 2>&1; then
    timeout 1 getent ahostsv4 "$dom" 2>/dev/null | awk 'NR==1{print $1}' || true
  else
    getent ahostsv4 "$dom" 2>/dev/null | awk 'NR==1{print $1}' || true
  fi
}

do_shutdown() {
  local iface="${WLAN_IF:-$(detect_wlan_if || echo wlan0)}"
  local cached_ip=""
  local cached_gw=""
  local cached_ssid=""

  if [[ "$MOCK_MODE" == "1" ]]; then
    cached_ip="192.168.1.42/24"
    cached_gw="192.168.1.1"
    cached_ssid="HomeWiFi"
  else
    cached_ip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk 'NR==1{print $4}' || true)"
    cached_gw="$(ip -4 route show default dev "$iface" 2>/dev/null | awk 'NR==1{print $3}' || true)"
    cached_ssid="$(iwctl station "$iface" show 2>/dev/null | awk -F'Connected network' 'NF>1{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' || true)"
  fi

  cat > "$NET_DIR/last_lease.env" <<EOF
WLAN_IF=${iface}
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

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

notify_proxy_online() {
  local online="${1:-true}"
  local ssid="${2:-}"
  local ip="${3:-}"
  local gw="${4:-}"
  local internet_ok="${5:-true}"
  local net_error="${6:-}"
  local payload
  payload="{\"online\":${online},\"ssid\":\"$(json_escape "$ssid")\",\"ip\":\"$(json_escape "$ip")\",\"gw\":\"$(json_escape "$gw")\",\"internet_ok\":${internet_ok},\"error\":\"$(json_escape "$net_error")\"}"
  for _ in $(seq 1 40); do
    if curl -fsS -m 1 -X POST "${PROXY_URL}/__5s__/net-online" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.02
  done
  return 0
}

parse_bool() {
  local val="${1:-}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val%\"}"
  val="${val#\"}"
  val="${val%\'}"
  val="${val#\'}"
  val="${val,,}"
  case "$val" in
    1|true|yes|on|enable|enabled) echo "true" ;;
    0|false|no|off|disable|disabled) echo "false" ;;
    *) echo "" ;;
  esac
}

import_external_wifi_config() {
  local wifi_file=""
  for cand in "$STATE_DIR/wifi.txt" /boot/efi/wifi.txt /boot/efi/WIFI.TXT; do
    if [[ -f "$cand" ]]; then
      wifi_file="$cand"
      break
    fi
  done

  local efi_mounted_by_us=0
  if [[ "$MOCK_MODE" != "1" && -z "$wifi_file" ]]; then
    local efi_dev=""
    if [[ -e /dev/disk/by-label/5S-USB-EFI ]]; then
      efi_dev="/dev/disk/by-label/5S-USB-EFI"
    elif [[ -e /dev/disk/by-label/5S-EFI ]]; then
      efi_dev="/dev/disk/by-label/5S-EFI"
    fi
    if [[ -n "$efi_dev" ]]; then
      mkdir -p /boot/efi
      if mount -o ro "$efi_dev" /boot/efi 2>/dev/null; then
        efi_mounted_by_us=1
      fi
      for cand in /boot/efi/wifi.txt /boot/efi/WIFI.TXT; do
        if [[ -f "$cand" ]]; then
          wifi_file="$cand"
          break
        fi
      done
    fi
  fi

  if [[ -z "$wifi_file" || ! -f "$wifi_file" ]]; then
    if [[ "$efi_mounted_by_us" == "1" ]]; then
      umount /boot/efi 2>/dev/null || true
    fi
    usb_log "network" "wifi.txt: not found in $STATE_DIR or /boot/efi"
    return 0
  fi

  local ext_ssid=""
  local ext_pass=""
  local enable_gmail="true"
  local enable_youtube="true"
  local enable_disc="true"
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="${raw_line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*SSID=(.*)$ ]]; then
      ext_ssid="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*(PASSWORD|PSK|PASS)=(.*)$ ]]; then
      ext_pass="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^[[:space:]]*ENABLE_GMAIL=(.*)$ ]]; then
      local parsed
      parsed="$(parse_bool "${BASH_REMATCH[1]}")"
      [[ -n "$parsed" ]] && enable_gmail="$parsed"
    elif [[ "$line" =~ ^[[:space:]]*ENABLE_YOUTUBE=(.*)$ ]]; then
      local parsed
      parsed="$(parse_bool "${BASH_REMATCH[1]}")"
      [[ -n "$parsed" ]] && enable_youtube="$parsed"
    elif [[ "$line" =~ ^[[:space:]]*ENABLE_DISC=(.*)$ ]]; then
      local parsed
      parsed="$(parse_bool "${BASH_REMATCH[1]}")"
      [[ -n "$parsed" ]] && enable_disc="$parsed"
    elif [[ -z "$ext_ssid" ]]; then
      ext_ssid="$line"
    elif [[ -z "$ext_pass" ]]; then
      ext_pass="$line"
    fi
  done < "$wifi_file"

  cat > "$STATE_DIR/features.json" <<EOF
{"gmail": ${enable_gmail}, "youtube": ${enable_youtube}, "disc": ${enable_disc}}
EOF

  if [[ "$efi_mounted_by_us" == "1" ]]; then
    umount /boot/efi 2>/dev/null || true
  fi

  if [[ -z "$ext_ssid" ]]; then
    usb_log "network" "wifi.txt: found at $wifi_file but no active SSID configured"
    return 0
  fi

  echo "5s-net: importing Wi-Fi credentials for SSID '$ext_ssid' from $wifi_file"
  usb_log "network" "wifi.txt: imported SSID='$ext_ssid' from $wifi_file (password_len=${#ext_pass})"
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

ensure_system_dbus() {
  if [[ ! -S /run/dbus/system_bus_socket && -x /usr/bin/dbus-daemon ]]; then
    mkdir -p /run/dbus /var/lib/dbus
    if [[ -x /usr/bin/dbus-uuidgen ]]; then
      /usr/bin/dbus-uuidgen --ensure 2>/dev/null || true
    fi
    /usr/bin/dbus-daemon --system --fork --nopidfile 2>/dev/null || true
  fi
}

wait_for_wlan_if() {
  if [[ -n "$WLAN_IF" && -e "/sys/class/net/$WLAN_IF" ]]; then
    return 0
  fi
  local found=""
  for _ in $(seq 1 75); do
    if found="$(detect_wlan_if)"; then
      WLAN_IF="$found"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

ensure_iwd_running() {
  if [[ -x /usr/libexec/iwd ]] && ! pidof iwd >/dev/null 2>&1; then
    mkdir -p /var/lib/iwd /etc/iwd
    if [[ ! -f /etc/iwd/main.conf ]] || ! grep -q 'EnableNetworkConfiguration=true' /etc/iwd/main.conf 2>/dev/null; then
      cat > /etc/iwd/main.conf <<'EOF'
[General]
EnableNetworkConfiguration=true
[Network]
EnableIPv6=false
EOF
    fi
    /usr/libexec/iwd >> "$LOCAL_LOG_DIR/iwd.log" 2>&1 &
    for _ in $(seq 1 25); do
      if iwctl device list >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
  fi
}

scan_and_connect_wifi() {
  local iface="$1"
  local target_ssid="$2"

  if [[ -z "$target_ssid" ]]; then
    usb_log "network" "NETWORK_FOUND=no (reason=no_ssid_configured)"
    return 1
  fi

  if ! command -v iwctl >/dev/null 2>&1; then
    usb_log "network" "ERROR: iwctl not found"
    return 1
  fi

  # Let iwd's AutoConnect=true finish first (avoids fighting its initial scan)
  local st_out=""
  for _ in $(seq 1 25); do
    st_out="$(iwctl station "$iface" show 2>&1 || true)"
    if printf '%s\n' "$st_out" | grep -qiE 'State[[:space:]]+connected'; then
      usb_log "network" "NETWORK_FOUND=yes (ssid='$target_ssid' iface='$iface' autoconnect=1)"
      usb_log "network" "WIFI_ASSOCIATED=yes (ssid='$target_ssid' iface='$iface')"
      printf '%s\n' "$st_out" >> "$LOCAL_LOG_DIR/network.log" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done

  # Fallback: explicit scan + connect if AutoConnect didn't complete within 2.5s
  iwctl station "$iface" scan >> "$LOCAL_LOG_DIR/network.log" 2>&1 || true
  sleep 1.0

  local networks_out=""
  networks_out="$(iwctl station "$iface" get-networks 2>&1 || true)"
  usb_log "network" "scan results on $iface:"
  printf '%s\n' "$networks_out" >> "$LOCAL_LOG_DIR/network.log" 2>/dev/null || true

  if printf '%s\n' "$networks_out" | grep -Fq "$target_ssid"; then
    usb_log "network" "NETWORK_FOUND=yes (ssid='$target_ssid' iface='$iface')"
  else
    usb_log "network" "NETWORK_FOUND=no (ssid='$target_ssid' not visible in scan; attempting connect anyway)"
  fi

  local conn_out=""
  conn_out="$(iwctl station "$iface" connect "$target_ssid" 2>&1 || true)"
  if [[ -n "$conn_out" ]]; then
    usb_log "network" "iwctl connect output: $conn_out"
  fi

  local assoc_ok=0
  for _ in $(seq 1 60); do
    st_out="$(iwctl station "$iface" show 2>&1 || true)"
    if printf '%s\n' "$st_out" | grep -qiE 'State[[:space:]]+connected'; then
      assoc_ok=1
      break
    fi
    sleep 0.2
  done

  if [[ "$assoc_ok" -eq 1 ]]; then
    usb_log "network" "WIFI_ASSOCIATED=yes (ssid='$target_ssid' iface='$iface')"
    printf '%s\n' "$st_out" >> "$LOCAL_LOG_DIR/network.log" 2>/dev/null || true
    return 0
  fi

  usb_log "network" "WIFI_ASSOCIATED=no (ssid='$target_ssid' iface='$iface')"
  printf '%s\n' "$st_out" >> "$LOCAL_LOG_DIR/network.log" 2>/dev/null || true
  return 1
}

wait_for_ip_and_internet() {
  local iface="$1"
  local ssid="$2"

  # Wait up to 3s for iwd's built-in DHCP client first (no dhcpcd / 8021q overhead)
  local cur_ip=""
  local cur_gw=""
  local dhcp_fallback_started=0
  for i in $(seq 1 75); do
    cur_ip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk 'NR==1{print $4}' || true)"
    cur_gw="$(ip -4 route show default dev "$iface" 2>/dev/null | awk 'NR==1{print $3}' || true)"
    if [[ -n "$cur_ip" && -n "$cur_gw" ]]; then
      break
    fi
    if [[ "$i" -eq 15 && "$dhcp_fallback_started" -eq 0 ]] && command -v dhcpcd >/dev/null 2>&1; then
      dhcp_fallback_started=1
      usb_log "network" "iwd DHCP still pending after 3s; starting dhcpcd fallback on $iface"
      dhcpcd -4 -q --noarp --nohook lookup-hostname "$iface" >> "$LOCAL_LOG_DIR/dhcpcd.log" 2>&1 &
    fi
    sleep 0.2
  done

  if [[ -z "$cur_ip" || -z "$cur_gw" ]]; then
    usb_log "network" "CONNECTION_ESTABLISHED=no (ssid='$ssid' ip='${cur_ip:-none}' gw='${cur_gw:-none}' reason=dhcp_timeout)"
    notify_proxy_online "false" "$ssid" "${cur_ip:-}" "${cur_gw:-}" "false" "DHCP lease timeout"
    return 1
  fi

  if [[ ! -s /etc/resolv.conf ]] || grep -q "127.0.0.53" /etc/resolv.conf 2>/dev/null; then
    usb_log "network" "replacing broken/stub /etc/resolv.conf with fallback DNS (1.1.1.1, 8.8.8.8)"
    rm -f /etc/resolv.conf 2>/dev/null || true
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf 2>/dev/null || true
  fi

  # Notify proxy immediately once IP + default gateway are configured (don't block on ping/curl)
  usb_log "network" "CONNECTION_ESTABLISHED=yes (ssid='$ssid' ip='$cur_ip' gw='$cur_gw' internet=ok)"
  notify_proxy_online "true" "$ssid" "$cur_ip" "$cur_gw" "true" ""

  # Persist lease immediately so unclean power-offs still have cached lease data on next boot
  cat > "$NET_DIR/last_lease.env" <<EOF
WLAN_IF=${iface}
CACHED_IP=${cur_ip}
CACHED_GW=${cur_gw}
CACHED_SSID=${ssid}
EOF
  return 0
}

do_boot() {
  usb_log "network" "boot network sequence started (mock=$MOCK_MODE)"
  merge_hosts_cache

  if [[ -f "$NET_DIR/last_lease.env" ]]; then
    # shellcheck disable=SC1091
    source "$NET_DIR/last_lease.env"
  fi
  if [[ -z "${CACHED_SSID:-}" && -f "$STATE_DIR/wifi_configured" ]]; then
    CACHED_SSID="$(head -n 1 "$STATE_DIR/wifi_configured" 2>/dev/null | tr -d '\r\n' || true)"
  fi

  import_external_wifi_config

  if [[ "$MOCK_MODE" == "1" ]]; then
    local mock_ssid="${CACHED_SSID:-MockWiFi}"
    usb_log "network" "NETWORK_FOUND=yes (ssid='$mock_ssid' mock=1)"
    usb_log "network" "CONNECTION_ESTABLISHED=yes (ssid='$mock_ssid' ip='${CACHED_IP:-192.168.1.42/24}' gw='${CACHED_GW:-192.168.1.1}' internet=ok mock=1)"
    notify_proxy_online "true" "$mock_ssid" "${CACHED_IP:-192.168.1.42/24}" "${CACHED_GW:-192.168.1.1}" "true" ""
    return 0
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe iwlwifi 2>/dev/null || true
    modprobe iwlmvm 2>/dev/null || true
  fi

  if ! wait_for_wlan_if; then
    usb_log "network" "ERROR: no wireless interface (/sys/class/net/wl*) appeared within 15s"
    usb_log "network" "CONNECTION_ESTABLISHED=no (reason=no_wifi_interface)"
    notify_proxy_online "false" "" "" "" "false" "No Wi-Fi adapter detected"
    return 0
  fi
  usb_log "network" "wireless interface detected: $WLAN_IF"

  if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock wifi >/dev/null 2>&1 || true
  fi
  ensure_system_dbus
  ensure_iwd_running

  ip link set "$WLAN_IF" up 2>/dev/null || true

  if [[ -z "${CACHED_SSID:-}" ]]; then
    usb_log "network" "no SSID configured yet; waiting for user setup"
    return 0
  fi

  if scan_and_connect_wifi "$WLAN_IF" "$CACHED_SSID"; then
    wait_for_ip_and_internet "$WLAN_IF" "$CACHED_SSID" || true
  else
    usb_log "network" "CONNECTION_ESTABLISHED=no (ssid='$CACHED_SSID' reason=wifi_association_failed)"
    notify_proxy_online "false" "$CACHED_SSID" "" "" "false" "Wi-Fi association failed for $CACHED_SSID"
  fi
}

do_connect() {
  if [[ -z "$CONNECT_SSID" ]]; then
    echo "ERROR: --connect requires an SSID" >&2
    exit 2
  fi
  usb_log "network" "interactive --connect requested for SSID='$CONNECT_SSID'"

  if [[ "$MOCK_MODE" == "1" ]]; then
    usb_log "network" "NETWORK_FOUND=yes (ssid='$CONNECT_SSID' mock=1)"
    usb_log "network" "CONNECTION_ESTABLISHED=yes (ssid='$CONNECT_SSID' ip='192.168.1.42/24' gw='192.168.1.1' internet=ok mock=1)"
    do_shutdown
    merge_hosts_cache
    notify_proxy_online "true" "$CONNECT_SSID" "192.168.1.42/24" "192.168.1.1" "true" ""
    return 0
  fi

  if ! wait_for_wlan_if; then
    usb_log "network" "CONNECTION_ESTABLISHED=no (ssid='$CONNECT_SSID' reason=no_wifi_interface)"
    notify_proxy_online "false" "$CONNECT_SSID" "" "" "false" "No Wi-Fi adapter detected"
    sync_usb_logs
    return 1
  fi

  if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock wifi >/dev/null 2>&1 || true
  fi
  ensure_system_dbus
  ensure_iwd_running
  ip link set "$WLAN_IF" up 2>/dev/null || true

  if scan_and_connect_wifi "$WLAN_IF" "$CONNECT_SSID"; then
    if wait_for_ip_and_internet "$WLAN_IF" "$CONNECT_SSID"; then
      do_shutdown
      merge_hosts_cache
      sync_usb_logs
      return 0
    fi
  else
    usb_log "network" "CONNECTION_ESTABLISHED=no (ssid='$CONNECT_SSID' reason=wifi_association_failed)"
    notify_proxy_online "false" "$CONNECT_SSID" "" "" "false" "Wi-Fi association failed for $CONNECT_SSID"
  fi

  sync_usb_logs
  return 1
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
