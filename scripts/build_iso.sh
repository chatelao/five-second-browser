#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${VERSION:-0.2.0}"
DEB_FILE="$ROOT_DIR/dist/5s-browser_0.1.0_amd64.deb"
ISO_OUT="$ROOT_DIR/dist/5s-browser-${VERSION}-amd64.iso"
WORK_DIR="$ROOT_DIR/build/iso_work"
ROOTFS="$WORK_DIR/rootfs"
ISO_DIR="$WORK_DIR/iso"

if [[ ! -f "$DEB_FILE" ]]; then
  bash "$ROOT_DIR/scripts/build_release.sh"
fi

rm -rf "$WORK_DIR"
mkdir -p "$ROOTFS" "$ISO_DIR/live" "$ISO_DIR/boot/grub"

echo "1. Bootstrapping minimal Debian 12 (bookworm) amd64 rootfs..."
debootstrap \
  --arch=amd64 \
  --variant=minbase \
  --include=linux-image-amd64,live-boot,systemd-sysv,grub-pc,grub-pc-bin,parted,e2fsprogs,squashfs-tools,kmod,udev,python3,lz4,curl,ca-certificates \
  bookworm "$ROOTFS" http://deb.debian.org/debian

cat > "$ROOTFS/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware
EOF

printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

mount --bind /dev "$ROOTFS/dev"
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
cleanup_mounts() {
  umount "$ROOTFS/sys" 2>/dev/null || true
  umount "$ROOTFS/proc" 2>/dev/null || true
  umount "$ROOTFS/dev" 2>/dev/null || true
}
trap cleanup_mounts EXIT

echo "2. Installing Broadcom BCM4313 firmware, iwd, cage, chromium, and 5s-browser..."
chroot "$ROOTFS" apt-get update
DEBIAN_FRONTEND=noninteractive chroot "$ROOTFS" apt-get install -y --no-install-recommends \
  firmware-brcm80211 iwd dhcpcd-base cage chromium
cp "$DEB_FILE" "$ROOTFS/tmp/5s-browser.deb"
chroot "$ROOTFS" dpkg -i /tmp/5s-browser.deb
rm -f "$ROOTFS/tmp/5s-browser.deb" "$ROOTFS/usr/sbin/policy-rc.d"
chroot "$ROOTFS" apt-get clean

mkdir -p "$ROOTFS/etc/default/grub.d"
cp "$ROOTFS/opt/5s-browser/config/grub-5s.cfg" "$ROOTFS/etc/default/grub.d/5s-browser.cfg"
cp "$ROOT_DIR/scripts/iso-autoinstall.sh" "$ROOTFS/opt/5s-browser/bin/iso-autoinstall.sh"
chmod 0755 "$ROOTFS/opt/5s-browser/bin/iso-autoinstall.sh"

cat > "$ROOTFS/etc/systemd/system/5s-autoinstall.service" <<'EOF'
[Unit]
Description=5s-browser Unattended USB Installer
After=local-fs.target
ConditionKernelCommandLine=5s_autoinstall=1

[Service]
Type=oneshot
ExecStart=/opt/5s-browser/bin/iso-autoinstall.sh
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/5s-autoinstall.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/5s-autoinstall.service"

cleanup_mounts
trap - EXIT

echo "3. Extracting kernel/initrd and building LZ4 SquashFS..."
VMLINUZ="$(find "$ROOTFS/boot" -maxdepth 1 -name 'vmlinuz-*' | sort | tail -n 1)"
INITRD="$(find "$ROOTFS/boot" -maxdepth 1 -name 'initrd.img-*' | sort | tail -n 1)"
cp "$VMLINUZ" "$ISO_DIR/live/vmlinuz"
cp "$INITRD" "$ISO_DIR/live/initrd.img"

mksquashfs "$ROOTFS" "$ISO_DIR/live/filesystem.squashfs" -comp lz4 -Xhc -noappend

cat > "$ISO_DIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=3

menuentry "Install 5s-browser automatically to /dev/sda (HP Mini Atom N550)" {
    linux /live/vmlinuz boot=live components quiet 5s_autoinstall=1
    initrd /live/initrd.img
}
EOF

echo "4. Creating hybrid BIOS/UEFI ISO: $ISO_OUT"
grub-mkrescue -o "$ISO_OUT" "$ISO_DIR"

(
  cd "$ROOT_DIR/dist"
  sha256sum ./*.deb ./*.iso HOWTO.md > SHA256SUMS
)
ls -lh "$ISO_OUT"
