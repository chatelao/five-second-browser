#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
DEB_FILE="$ROOT_DIR/dist/5s-browser_${VERSION}_amd64.deb"
IMG_RAW="$ROOT_DIR/build/5s-browser-${VERSION}-usb-sd-amd64.img"
IMG_XZ="$ROOT_DIR/dist/5s-browser-${VERSION}-usb-sd-amd64.img.xz"
WORK_DIR="$ROOT_DIR/build/usb_work"
MNT_DIR="$WORK_DIR/mnt"
IMG_SIZE_MB="${IMG_SIZE_MB:-3200}"
BASE_ROOTFS="${BASE_ROOTFS:-}"

if [[ ! -f "$DEB_FILE" ]]; then
  VERSION="$VERSION" bash "$ROOT_DIR/scripts/build_release.sh"
fi

rm -rf "$WORK_DIR" "$IMG_RAW"
mkdir -p "$MNT_DIR" "$ROOT_DIR/dist"

echo "1. Creating ${IMG_SIZE_MB}MB hybrid UEFI+BIOS USB/SD disk image..."
truncate -s "${IMG_SIZE_MB}M" "$IMG_RAW"
parted -s "$IMG_RAW" mklabel msdos
parted -s "$IMG_RAW" mkpart primary fat32 1MiB 65MiB
parted -s "$IMG_RAW" set 1 esp on
parted -s "$IMG_RAW" mkpart primary ext4 65MiB 100%
parted -s "$IMG_RAW" set 2 boot on

LOOP_DEV="$(losetup --find --show --partscan "$IMG_RAW")"
cleanup() {
  umount "$MNT_DIR/sys" 2>/dev/null || true
  umount "$MNT_DIR/proc" 2>/dev/null || true
  umount "$MNT_DIR/dev" 2>/dev/null || true
  umount "$MNT_DIR/boot/efi" 2>/dev/null || true
  umount "$MNT_DIR" 2>/dev/null || true
  if [[ -n "${LOOP_DEV:-}" ]]; then
    losetup -d "$LOOP_DEV" 2>/dev/null || true
  fi
}
trap cleanup EXIT

EFI_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"
for _ in $(seq 1 20); do
  [[ -b "$ROOT_PART" ]] && break
  partprobe "$LOOP_DEV" 2>/dev/null || true
  sleep 0.2
done

mkfs.vfat -F 32 -n 5S-USB-EFI "$EFI_PART"
mkfs.ext4 -F -L 5s-usb-root "$ROOT_PART"
mount "$ROOT_PART" "$MNT_DIR"

if [[ -n "$BASE_ROOTFS" && -d "$BASE_ROOTFS/opt/5s-browser" ]]; then
  echo "2. Reusing pre-bootstrapped rootfs from $BASE_ROOTFS..."
  cp -a "$BASE_ROOTFS/." "$MNT_DIR/"
  rm -f "$MNT_DIR/etc/systemd/system/multi-user.target.wants/5s-autoinstall.service" \
        "$MNT_DIR/etc/systemd/system/5s-autoinstall.service"
  mount --bind /dev "$MNT_DIR/dev"
  mount --bind /proc "$MNT_DIR/proc"
  mount --bind /sys "$MNT_DIR/sys"
else
  echo "2. Bootstrapping Debian 12 (bookworm) amd64 onto USB/SD image..."
  debootstrap \
    --arch=amd64 \
    --variant=minbase \
    --include=linux-image-amd64,systemd-sysv,grub-pc,grub-pc-bin,grub-efi-amd64-bin,dosfstools,e2fsprogs,kmod,udev,python3,lz4,curl,ca-certificates \
    bookworm "$MNT_DIR" http://deb.debian.org/debian

  cat > "$MNT_DIR/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware
EOF

  printf '#!/bin/sh\nexit 101\n' > "$MNT_DIR/usr/sbin/policy-rc.d"
  chmod +x "$MNT_DIR/usr/sbin/policy-rc.d"

  mount --bind /dev "$MNT_DIR/dev"
  mount --bind /proc "$MNT_DIR/proc"
  mount --bind /sys "$MNT_DIR/sys"

  echo "3. Installing Intel AC-3165 Wi-Fi firmware, Gen8 VA-API, iwd, cage, chromium, and 5s-browser..."
  chroot "$MNT_DIR" apt-get update
  DEBIAN_FRONTEND=noninteractive chroot "$MNT_DIR" apt-get install -y --no-install-recommends \
    firmware-iwlwifi firmware-brcm80211 i965-va-driver iwd dhcpcd-base cage chromium
  cp "$DEB_FILE" "$MNT_DIR/tmp/5s-browser.deb"
  chroot "$MNT_DIR" dpkg -i /tmp/5s-browser.deb
  rm -f "$MNT_DIR/tmp/5s-browser.deb" "$MNT_DIR/usr/sbin/policy-rc.d"
  chroot "$MNT_DIR" apt-get clean
fi

mkdir -p "$MNT_DIR/boot/efi"
mount "$EFI_PART" "$MNT_DIR/boot/efi"

echo "5s-browser" > "$MNT_DIR/etc/hostname"

cat > "$MNT_DIR/etc/fstab" <<'EOF'
LABEL=5s-usb-root  /          ext4  defaults,noatime,commit=60  0  1
LABEL=5S-USB-EFI   /boot/efi  vfat  umask=0077                  0  2
EOF

echo "4. Installing hybrid UEFI + Legacy BIOS GRUB2 for USB 3.0 & SD Card boot..."
mkdir -p "$MNT_DIR/etc/default/grub.d"
cat > "$MNT_DIR/etc/default/grub.d/5s-browser.cfg" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_DISABLE_OS_PROBER=true
GRUB_CMDLINE_LINUX_DEFAULT="root=LABEL=5s-usb-root rootwait loglevel=7 mitigations=off i915.fastboot=1 vt.global_cursor_default=0 init=/opt/5s-browser/bin/5s-init"
EOF

chroot "$MNT_DIR" grub-install --target=i386-pc --recheck "$LOOP_DEV"
chroot "$MNT_DIR" grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram
chroot "$MNT_DIR" update-grub

# Cap initramfs udevadm settle to 5s so a stalled non-boot device (e.g. optical/SATA/card reader)
# cannot block USB root boot for 120 seconds ("Timed out waiting for udev queue being empty")
if [[ -f "$MNT_DIR/usr/share/initramfs-tools/scripts/init-top/udev" ]]; then
  mkdir -p "$MNT_DIR/etc/initramfs-tools/scripts/init-top"
  cp "$MNT_DIR/usr/share/initramfs-tools/scripts/init-top/udev" \
     "$MNT_DIR/etc/initramfs-tools/scripts/init-top/udev"
  sed -i 's/udevadm settle/udevadm settle --timeout=5/g' \
     "$MNT_DIR/etc/initramfs-tools/scripts/init-top/udev"
  chmod +x "$MNT_DIR/etc/initramfs-tools/scripts/init-top/udev"
fi

# Ensure initramfs includes USB 3.0 (xHCI) & Realtek PCIe SD card reader modules
for mod in xhci_pci xhci_hcd usb_storage uas rtsx_pci rtsx_pci_sdmmc mmc_block sdhci sdhci_pci; do
  if ! grep -qx "$mod" "$MNT_DIR/etc/initramfs-tools/modules" 2>/dev/null; then
    echo "$mod" >> "$MNT_DIR/etc/initramfs-tools/modules"
  fi
done
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
