#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
DEB_FILE="$ROOT_DIR/dist/5s-browser_${VERSION}_amd64.deb"
ISO_OUT="$ROOT_DIR/dist/5s-browser-${VERSION}-amd64.iso"
WORK_DIR="$ROOT_DIR/build/iso_work"
ROOTFS="$WORK_DIR/rootfs"
ISO_DIR="$WORK_DIR/iso"

if [[ ! -f "$DEB_FILE" ]]; then
  VERSION="$VERSION" bash "$ROOT_DIR/scripts/build_release.sh"
fi

rm -rf "$WORK_DIR"
mkdir -p "$ROOTFS" "$ISO_DIR/live" "$ISO_DIR/boot/grub"

# shellcheck source=scripts/trim_rootfs.sh
source "$ROOT_DIR/scripts/trim_rootfs.sh"

echo "1. Bootstrapping minimal Debian 12 (bookworm) amd64 rootfs..."
debootstrap \
  --arch=amd64 \
  --variant=minbase \
  --include=linux-image-amd64,live-boot,systemd-sysv,grub-pc,grub-pc-bin,grub-efi-amd64-bin,dosfstools,parted,e2fsprogs,squashfs-tools,kmod,udev,python3,lz4,curl,ca-certificates \
  bookworm "$ROOTFS" http://deb.debian.org/debian

configure_dpkg_filters "$ROOTFS"

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

echo "2. Installing Intel AC-3165 Wi-Fi firmware, Gen8 VA-API driver, iwd, seatd, xwayland, cage, chromium, and 5s-browser..."
chroot "$ROOTFS" apt-get update
DEBIAN_FRONTEND=noninteractive chroot "$ROOTFS" apt-get install -y --no-install-recommends \
  firmware-iwlwifi wireless-regdb iproute2 i965-va-driver iwd dhcpcd-base seatd xwayland cage chromium
cp "$DEB_FILE" "$ROOTFS/tmp/5s-browser.deb"
chroot "$ROOTFS" dpkg -i /tmp/5s-browser.deb
rm -f "$ROOTFS/tmp/5s-browser.deb" "$ROOTFS/usr/sbin/policy-rc.d"
chroot "$ROOTFS" apt-get clean

if ! chroot "$ROOTFS" id -u kiosk >/dev/null 2>&1; then
  chroot "$ROOTFS" useradd -r -m -d /home/kiosk -s /bin/sh kiosk
fi
for grp in video render input audio tty; do
  if chroot "$ROOTFS" getent group "$grp" >/dev/null 2>&1; then
    chroot "$ROOTFS" usermod -aG "$grp" kiosk || true
  fi
done

echo "5s-browser" > "$ROOTFS/etc/hostname"

mkdir -p "$ROOTFS/etc/default/grub.d"
cp "$ROOTFS/opt/5s-browser/config/grub-5s.cfg" "$ROOTFS/etc/default/grub.d/5s-browser.cfg"
cp "$ROOT_DIR/scripts/iso-autoinstall.sh" "$ROOTFS/opt/5s-browser/bin/iso-autoinstall.sh"
chmod 0755 "$ROOTFS/opt/5s-browser/bin/iso-autoinstall.sh"

cat > "$ROOTFS/etc/systemd/system/5s-autoinstall.service" <<'EOF'
[Unit]
Description=5s-browser Unattended USB Installer
After=local-fs.target
Conflicts=getty@tty1.service
Before=getty@tty1.service
ConditionKernelCommandLine=5s_autoinstall=1

[Service]
Type=oneshot
ExecStart=/opt/5s-browser/bin/iso-autoinstall.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/5s-autoinstall.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/5s-autoinstall.service"

trim_rootfs "$ROOTFS"

if [[ -f "$ROOTFS/etc/initramfs-tools/initramfs.conf" ]]; then
  sed -i 's/^COMPRESS=.*/COMPRESS=lz4/' "$ROOTFS/etc/initramfs-tools/initramfs.conf"
fi

if [[ -f "$ROOTFS/usr/share/initramfs-tools/scripts/init-top/udev" ]]; then
  mkdir -p "$ROOTFS/etc/initramfs-tools/scripts/init-top" "$ROOTFS/etc/initramfs-tools/conf.d"
  cat > "$ROOTFS/etc/initramfs-tools/conf.d/5s-fastboot.conf" <<'EOF'
COMPRESS=lz4
COMPRESSLEVEL=1
EOF
  cp "$ROOTFS/usr/share/initramfs-tools/scripts/init-top/udev" \
     "$ROOTFS/etc/initramfs-tools/scripts/init-top/udev"
  sed -i 's/udevadm settle/udevadm settle --timeout=2/g' \
     "$ROOTFS/etc/initramfs-tools/scripts/init-top/udev"
  chmod +x "$ROOTFS/etc/initramfs-tools/scripts/init-top/udev"
  chroot "$ROOTFS" update-initramfs -u
fi

cleanup_mounts
trap - EXIT

echo "3. Extracting kernel/initrd and building SquashFS..."
VMLINUZ="$(find "$ROOTFS/boot" -maxdepth 1 -name 'vmlinuz-*' | sort | tail -n 1)"
INITRD="$(find "$ROOTFS/boot" -maxdepth 1 -name 'initrd.img-*' | sort | tail -n 1)"
cp "$VMLINUZ" "$ISO_DIR/live/vmlinuz"
cp "$INITRD" "$ISO_DIR/live/initrd.img"

mksquashfs "$ROOTFS" "$ISO_DIR/live/filesystem.squashfs" -comp lz4 -Xhc -noappend

cat > "$ISO_DIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=3

menuentry "Install 5s-browser automatically to internal disk (HP Pavilion 3825U)" {
    linux /live/vmlinuz boot=live components loglevel=7 5s_autoinstall=1
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
