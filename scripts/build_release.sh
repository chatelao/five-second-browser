#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_BIN="$ROOT_DIR/build/bin"
DEB_ROOT="$ROOT_DIR/build/deb_root"
DIST_DIR="$ROOT_DIR/dist"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
DEB_NAME="5s-browser_${VERSION}_amd64.deb"

rm -rf "$DEB_ROOT" "$DIST_DIR"
mkdir -p "$DIST_DIR" \
  "$DEB_ROOT/DEBIAN" \
  "$DEB_ROOT/opt/5s-browser/bin" \
  "$DEB_ROOT/opt/5s-browser/config" \
  "$DEB_ROOT/opt/5s-browser/ext" \
  "$DEB_ROOT/usr/share/doc/5s-browser"
chmod 0755 "$DEB_ROOT" "$DEB_ROOT/DEBIAN" \
  "$DEB_ROOT/opt" "$DEB_ROOT/opt/5s-browser" \
  "$DEB_ROOT/opt/5s-browser/bin" "$DEB_ROOT/opt/5s-browser/config" "$DEB_ROOT/opt/5s-browser/ext" \
  "$DEB_ROOT/usr" "$DEB_ROOT/usr/share" "$DEB_ROOT/usr/share/doc" "$DEB_ROOT/usr/share/doc/5s-browser"

cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: 5s-browser
Version: ${VERSION}
Section: web
Priority: optional
Architecture: amd64
Maintainer: five-second-browser <maintainers@example.com>
Depends: python3, lz4, curl
Recommends: dbus, seatd, xwayland, cage, chromium, iwd, dhcpcd-base, firmware-iwlwifi, i965-va-driver, vainfo, mpv, libdvdnav4, libdvdread8, libbluray2, libaacs0, libbdplus0, eject, alsa-utils
Description: Five-second Gmail, YouTube & Optical Disc appliance for HP Pavilion 17-g111nz
 Boots directly into cached Gmail and YouTube on Intel Pentium 3825U (Broadwell-U,
 4GB RAM, Gen8 VA-API, Intel Wireless-AC 3165) while syncing live deltas,
 with built-in DVD and conditional Blu-ray playback.
EOF

cat > "$DEB_ROOT/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /var/cache/5s/net /var/cache/5s/logs
chmod 0755 /opt/5s-browser/bin/*
if ! id -u kiosk >/dev/null 2>&1 && command -v useradd >/dev/null 2>&1; then
  useradd -r -m -d /home/kiosk -s /bin/sh kiosk || true
fi
if id -u kiosk >/dev/null 2>&1; then
  for grp in video render input audio tty cdrom; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" kiosk || true
  done
fi
EOF
chmod 0755 "$DEB_ROOT/DEBIAN/postinst"

cp "$BUILD_BIN/5s-init" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/5s-fb-splash" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/cache_proxy.py" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/injected_ui.js" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/disc_manager.py" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/5s-optical-init.sh" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/5s-net-fast.sh" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/5s-checkpoint.sh" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/5s-browser-launch.sh" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/zram-setup.sh" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/5s-audio-init.sh" "$DEB_ROOT/opt/5s-browser/bin/"
cp "$BUILD_BIN/5s-usb-log.sh" "$DEB_ROOT/opt/5s-browser/bin/"
chmod 0755 "$DEB_ROOT/opt/5s-browser/bin/"*
chmod 0644 "$DEB_ROOT/opt/5s-browser/bin/injected_ui.js"

cp "$ROOT_DIR/build/ext/"* "$DEB_ROOT/opt/5s-browser/ext/"
chmod 0644 "$DEB_ROOT/opt/5s-browser/ext/"*

cp "$ROOT_DIR/src/config/grub-5s.cfg" "$DEB_ROOT/opt/5s-browser/config/grub-5s.cfg"
cp "$ROOT_DIR/src/config/asound-5s.conf" "$DEB_ROOT/opt/5s-browser/config/asound-5s.conf"
mkdir -p "$DEB_ROOT/etc/chromium/policies/managed"
cp "$ROOT_DIR/src/config/chromium-policy.json" "$DEB_ROOT/etc/chromium/policies/managed/5s-family.json"
chmod 0644 "$DEB_ROOT/etc/chromium/policies/managed/5s-family.json"
cp "$ROOT_DIR/VERSION" "$DEB_ROOT/opt/5s-browser/VERSION"
chmod 0644 "$DEB_ROOT/opt/5s-browser/VERSION"
cp "$ROOT_DIR/HOWTO.md" "$DEB_ROOT/usr/share/doc/5s-browser/HOWTO.md"

dpkg-deb --root-owner-group --build "$DEB_ROOT" "$DIST_DIR/$DEB_NAME"
cp "$ROOT_DIR/HOWTO.md" "$DIST_DIR/HOWTO.md"

(
  cd "$DIST_DIR"
  sha256sum "$DEB_NAME" "HOWTO.md" > SHA256SUMS
)

echo "Built release assets in $DIST_DIR:"
ls -lh "$DIST_DIR"
