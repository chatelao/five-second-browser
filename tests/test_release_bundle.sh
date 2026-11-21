#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DEB_FILE="$DIST_DIR/5s-browser_0.1.0_amd64.deb"
HOWTO_FILE="$DIST_DIR/HOWTO.md"
SUMS_FILE="$DIST_DIR/SHA256SUMS"

if [[ ! -s "$DEB_FILE" || ! -s "$HOWTO_FILE" || ! -s "$SUMS_FILE" ]]; then
  make -s -C "$ROOT_DIR" package
fi

[[ -s "$DEB_FILE" ]] || { echo "ERROR: missing $DEB_FILE"; exit 1; }
[[ -s "$HOWTO_FILE" ]] || { echo "ERROR: missing $HOWTO_FILE"; exit 1; }
[[ -s "$SUMS_FILE" ]] || { echo "ERROR: missing $SUMS_FILE"; exit 1; }

(
  cd "$DIST_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)

TMP_EXTRACT="$(mktemp -d)"
trap 'rm -rf "$TMP_EXTRACT"' EXIT
dpkg-deb -x "$DEB_FILE" "$TMP_EXTRACT"

REQUIRED_EXECS=(
  "opt/5s-browser/bin/5s-init"
  "opt/5s-browser/bin/5s-fb-splash"
  "opt/5s-browser/bin/cache_proxy.py"
  "opt/5s-browser/bin/5s-net-fast.sh"
  "opt/5s-browser/bin/5s-checkpoint.sh"
  "opt/5s-browser/bin/5s-browser-launch.sh"
  "opt/5s-browser/bin/zram-setup.sh"
)

for rel in "${REQUIRED_EXECS[@]}"; do
  if [[ ! -x "$TMP_EXTRACT/$rel" ]]; then
    echo "ERROR: $rel missing or not executable in .deb"
    exit 1
  fi
done

[[ -f "$TMP_EXTRACT/opt/5s-browser/bin/injected_ui.js" ]] || { echo "ERROR: missing injected_ui.js"; exit 1; }
[[ -f "$TMP_EXTRACT/opt/5s-browser/config/grub-5s.cfg" ]] || { echo "ERROR: missing grub-5s.cfg"; exit 1; }
[[ -f "$TMP_EXTRACT/usr/share/doc/5s-browser/HOWTO.md" ]] || { echo "ERROR: missing packaged HOWTO.md"; exit 1; }

REQUIRED_DOC_STRINGS=(
  "5s-browser-0.2.0-amd64.iso"
  "Connect to Wi-Fi"
  "Connect & Start"
  "5s-browser_0.1.0_amd64.deb"
  "F1"
  "F2"
)

for needle in "${REQUIRED_DOC_STRINGS[@]}"; do
  if ! grep -qF "$needle" "$HOWTO_FILE"; then
    echo "ERROR: HOWTO.md missing required section/string: $needle"
    exit 1
  fi
done

echo "test_release_bundle: .deb, HOWTO.md, and SHA256SUMS verified"
