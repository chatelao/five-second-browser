#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${VERSION:-0.3.0}"
DEB_FILE="$ROOT_DIR/dist/5s-browser_0.1.0_amd64.deb"
IMG_RAW="$ROOT_DIR/build/5s-browser-${VERSION}-usb-sd-amd64.img"
IMG_XZ="$ROOT_DIR/dist/5s-browser-${VERSION}-usb-sd-amd64.img.xz"
WORK_DIR="$ROOT_DIR/build/usb_work"
MNT_DIR="$WORK_DIR/mnt"
IMG_SIZE_MB="${IMG_SIZE_MB:-3200}"

if [[ ! -f "$DEB_FILE" ]]; then
  bash "$ROOT_DIR/scripts/build_release.sh"
fi

rm -rf "$WORK_DIR" "$IMG_RAW"
mkdir -p "$MNT_DIR" "$ROOT_DIR/dist"

echo "1. Creating ${IMG_SIZE_MB}MB raw disk image..."
truncate -s "${IMG_SIZE_MB}M" "$IMG_RAW"
parted -s "$IMG_RAW" mklabel msdos
parted -s "$IMG_RAW" mkpart primary ext4 1MiB 100%
parted -s "$IMG_RAW" set 1 boot on

LOOP_DEV="$(losetup --find --show --partscan "$IMG_RAW")"
cleanup() {
  umount "$MNT_DIR/sys" 2>/dev/null || true
  umount "$MNT_DIR/proc" 2>/dev/null || true
  umount "$MNT_DIR/dev" 2>/dev/null || true
  umount "$MNT_DIR" 2>/dev/null || true
  if [[ -n "${LOOP_DEV:-}" ]]; then
    losetup -d "$LOOP_DEV" 2>/dev/null || true
  fi
}
trap cleanup EXIT

LOOP_PART="${LOOP_DEV}p1"
for _ in $(seq 1 20); do
  [[ -b "$LOOP_PART" ]] && break
  partprobe "$LOOP_DEV" 2>/dev/null || true
  sleep 0.2
done

mkfs.ext4 -F -L 5s-usb-root "$LOOP_PART"
mount "$LOOP_PART" "$MNT_DIR"

echo "2. Bootstrapping Debian 12 (bookworm) amd64 onto USB/SD image..."
debootstrap \
  --arch=amd64 \
  --variant=minbase \
  --include=linux-image-amd64,systemd-sysv,grub-pc,grub-pc-bin,e2fsprogs,kmod,udev,python3,lz4,curl,ca-certificates \
  bookworm "$MNT_DIR" http://deb.debian.org/debian

cat > "$MNT_DIR/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware
EOF

cat > "$MNT_DIR/etc/fstab" <<'EOF'
LABEL=5s-usb-root  /  ext4  defaults,noatime,commit=60  0  1
EOF

printf '#!/bin/sh\nexit 101\n' > "$MNT_DIR/usr/sbin/policy-rc.d"
chmod +x "$MNT_DIR/usr/sbin/policy-rc.d"

mount --bind /dev "$MNT_DIR/dev"
mount --bind /proc "$MNT_DIR/proc"
mount --bind /sys "$MNT_DIR/sys"

echo "3. Installing firmware-brcm80211, iwd, cage, chromium, and 5s-browser..."
chroot "$MNT_DIR" apt-get update
DEBIAN_FRONTEND=noninteractive chroot "$MNT_DIR" apt-get install -y --no-install-recommends \
  firmware-brcm80211 iwd dhcpcd-base cage chromium
cp "$DEB_FILE" "$MNT_DIR/tmp/5s-browser.deb"
chroot "$MNT_DIR" dpkg -i /tmp/5s-browser.deb
rm -f "$MNT_DIR/tmp/5s-browser.deb" "$MNT_DIR/usr/sbin/policy-rc.d"
chroot "$MNT_DIR" apt-get clean

echo "4. Configuring GRUB2 for portable USB/SD boot (root=LABEL=5s-usb-root rootwait)..."
mkdir -p "$MNT_DIR/etc/default/grub.d"
cat > "$MNT_DIR/etc/default/grub.d/5s-browser.cfg" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_DISABLE_OS_PROBER=true
GRUB_CMDLINE_LINUX_DEFAULT="root=LABEL=5s-usb-root rootwait quiet loglevel=0 mitigations=off i915.fastboot=1 video=LVDS-1:1024x600@60e vt.global_cursor_default=0 init=/opt/5s-browser/bin/5s-init"
EOF

# Allow root=LABEL= resolution in initramfs and update GRUB
chroot "$MNT_DIR" grub-install --target=i386-pc --recheck "$LOOP_DEV"
chroot "$MNT_DIR" update-grub

# Ensure initramfs includes usb-storage and mmc_block for USB/SD card boot
cat >> "$MNT_DIR/etc/initramfs-tools/modules" <<'EOF'
usb_storage
uas
mmc_block
sdhci
sdhci_pci
EOF
chroot "$MNT_DIR" update-initramfs -u

sync
cleanup
trap - EXIT

echo "5. Compressing portable USB/SD image with xz..."
xz -T0 -6 -c "$IMG_RAW" > "$IMG_XZ"
rm -f "$IMG_RAW"

(
  cd "$ROOT_DIR/dist"
  sha256sum ./*.deb ./*.iso ./*.img.xz HOWTO.md 2>/dev/null > SHA256SUMS || sha256sum ./*.deb ./*.img.xz HOWTO.md > SHA256SUMS
)
ls -lh "$IMG_XZ"
