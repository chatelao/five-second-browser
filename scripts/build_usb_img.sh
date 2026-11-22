#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
DEB_FILE="$ROOT_DIR/dist/5s-browser_${VERSION}_amd64.deb"
IMG_RAW="$ROOT_DIR/build/5s-browser-${VERSION}-usb-sd-amd64.img"
IMG_XZ="$ROOT_DIR/dist/5s-browser-${VERSION}-usb-sd-amd64.img.xz"
WORK_DIR="$ROOT_DIR/build/usb_work"
STAGE_ROOTFS="$WORK_DIR/rootfs"
SQFS_FILE="$WORK_DIR/rootfs.squashfs"
MNT_DIR="$WORK_DIR/mnt"
IMG_SIZE_MB="${IMG_SIZE_MB:-auto}"
OVERLAY_FREE_MB="${OVERLAY_FREE_MB:-512}"
BASE_ROOTFS="${BASE_ROOTFS:-}"

# shellcheck source=scripts/trim_rootfs.sh
source "$ROOT_DIR/scripts/trim_rootfs.sh"

if [[ ! -f "$DEB_FILE" ]]; then
  VERSION="$VERSION" bash "$ROOT_DIR/scripts/build_release.sh"
fi

rm -rf "$WORK_DIR" "$IMG_RAW"
mkdir -p "$STAGE_ROOTFS" "$MNT_DIR" "$ROOT_DIR/dist"

LOOP_DEV=""
cleanup() {
  umount "$STAGE_ROOTFS/boot/efi" 2>/dev/null || true
  umount "$STAGE_ROOTFS/boot" 2>/dev/null || true
  umount "$STAGE_ROOTFS/sys" 2>/dev/null || true
  umount "$STAGE_ROOTFS/proc" 2>/dev/null || true
  umount "$STAGE_ROOTFS/dev" 2>/dev/null || true
  umount "$MNT_DIR/boot/efi" 2>/dev/null || true
  umount "$MNT_DIR" 2>/dev/null || true
  if [[ -n "${LOOP_DEV:-}" ]]; then
    losetup -d "$LOOP_DEV" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -n "$BASE_ROOTFS" && -d "$BASE_ROOTFS/opt/5s-browser" ]]; then
  echo "1. Reusing pre-bootstrapped rootfs from $BASE_ROOTFS..."
  cp -a "$BASE_ROOTFS/." "$STAGE_ROOTFS/"
  rm -f "$STAGE_ROOTFS/etc/systemd/system/multi-user.target.wants/5s-autoinstall.service" \
        "$STAGE_ROOTFS/etc/systemd/system/5s-autoinstall.service" \
        "$STAGE_ROOTFS/opt/5s-browser/bin/iso-autoinstall.sh"
  mount --bind /dev "$STAGE_ROOTFS/dev"
  mount --bind /proc "$STAGE_ROOTFS/proc"
  mount --bind /sys "$STAGE_ROOTFS/sys"
  DEBIAN_FRONTEND=noninteractive chroot "$STAGE_ROOTFS" apt-get purge -y --auto-remove \
    live-boot live-boot-initramfs-tools squashfs-tools parted 2>/dev/null || true
  chroot "$STAGE_ROOTFS" apt-get clean
else
  echo "1. Bootstrapping minimal Debian 12 (bookworm) amd64 rootfs..."
  debootstrap \
    --arch=amd64 \
    --variant=minbase \
    --include=linux-image-amd64,systemd-sysv,grub-pc,grub-pc-bin,grub-efi-amd64-bin,dosfstools,e2fsprogs,kmod,udev,python3,lz4,curl,ca-certificates \
    bookworm "$STAGE_ROOTFS" http://deb.debian.org/debian

  configure_dpkg_filters "$STAGE_ROOTFS"

  cat > "$STAGE_ROOTFS/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware
EOF

  printf '#!/bin/sh\nexit 101\n' > "$STAGE_ROOTFS/usr/sbin/policy-rc.d"
  chmod +x "$STAGE_ROOTFS/usr/sbin/policy-rc.d"

  mount --bind /dev "$STAGE_ROOTFS/dev"
  mount --bind /proc "$STAGE_ROOTFS/proc"
  mount --bind /sys "$STAGE_ROOTFS/sys"

  echo "2. Installing Intel AC-3165 Wi-Fi firmware, Gen8 VA-API, iwd, seatd, xwayland, cage, chromium, mpv/disc libs, and 5s-browser..."
  chroot "$STAGE_ROOTFS" apt-get update
  DEBIAN_FRONTEND=noninteractive chroot "$STAGE_ROOTFS" apt-get install -y --no-install-recommends \
    firmware-iwlwifi wireless-regdb iproute2 i965-va-driver dbus iwd dhcpcd-base seatd xwayland cage chromium \
    mpv libdvdnav4 libdvdread8 libbluray2 libaacs0 libbdplus0 eject alsa-utils
  if [[ "${ENABLE_LIBDVDCSS:-0}" == "1" ]]; then
    DEBIAN_FRONTEND=noninteractive chroot "$STAGE_ROOTFS" apt-get install -y --no-install-recommends libdvd-pkg || true
    DEBIAN_FRONTEND=noninteractive chroot "$STAGE_ROOTFS" dpkg-reconfigure -f noninteractive libdvd-pkg || true
  fi
  cp "$DEB_FILE" "$STAGE_ROOTFS/tmp/5s-browser.deb"
  chroot "$STAGE_ROOTFS" dpkg -i /tmp/5s-browser.deb
  rm -f "$STAGE_ROOTFS/tmp/5s-browser.deb" "$STAGE_ROOTFS/usr/sbin/policy-rc.d"
  chroot "$STAGE_ROOTFS" apt-get clean
fi

if ! chroot "$STAGE_ROOTFS" id -u kiosk >/dev/null 2>&1; then
  chroot "$STAGE_ROOTFS" useradd -r -m -d /home/kiosk -s /bin/sh kiosk
fi
for grp in video render input audio tty cdrom; do
  if chroot "$STAGE_ROOTFS" getent group "$grp" >/dev/null 2>&1; then
    chroot "$STAGE_ROOTFS" usermod -aG "$grp" kiosk || true
  fi
done

echo "5s-browser" > "$STAGE_ROOTFS/etc/hostname"

cat > "$STAGE_ROOTFS/etc/fstab" <<'EOF'
LABEL=5s-usb-root  /          ext4  defaults,noatime,commit=60  0  1
LABEL=5S-USB-EFI   /boot/efi  vfat  umask=0077                  0  2
EOF

mkdir -p "$STAGE_ROOTFS/etc/default/grub.d"
cat > "$STAGE_ROOTFS/etc/default/grub.d/5s-browser.cfg" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_LINUX_UUID=true
GRUB_CMDLINE_LINUX_DEFAULT="root=LABEL=5s-usb-root rootwait quiet loglevel=3 log_buf_len=4M rd.udev.log_level=3 mitigations=off i915.fastboot=1 vt.global_cursor_default=0 libata.force=1:disable modprobe.blacklist=ahci,btusb,bluetooth,uvcvideo,pcspkr,hp_accel,lis3lv02d init=/opt/5s-browser/bin/5s-init"
EOF

echo "3. Trimming rootfs & configuring SquashFS+OverlayFS initramfs..."
trim_rootfs "$STAGE_ROOTFS"

# Cap initramfs udevadm settle to 2s so a stalled non-boot device (e.g. optical/SATA/card reader)
# cannot block USB root boot ("Timed out waiting for udev queue being empty")
if [[ -f "$STAGE_ROOTFS/usr/share/initramfs-tools/scripts/init-top/udev" ]]; then
  mkdir -p "$STAGE_ROOTFS/etc/initramfs-tools/scripts/init-top"
  cp "$STAGE_ROOTFS/usr/share/initramfs-tools/scripts/init-top/udev" \
     "$STAGE_ROOTFS/etc/initramfs-tools/scripts/init-top/udev"
  sed -i 's/udevadm settle/udevadm settle --timeout=2/g' \
     "$STAGE_ROOTFS/etc/initramfs-tools/scripts/init-top/udev"
  chmod +x "$STAGE_ROOTFS/etc/initramfs-tools/scripts/init-top/udev"
fi

# Slim LZ4 initramfs: include only USB 3.0/SD/ext4/HID/i915 KMS/SquashFS/OverlayFS modules
mkdir -p "$STAGE_ROOTFS/etc/initramfs-tools/conf.d"
cat > "$STAGE_ROOTFS/etc/initramfs-tools/conf.d/5s-fastboot.conf" <<'EOF'
COMPRESS=lz4
COMPRESSLEVEL=1
MODULES=list
EOF

# Mount SquashFS + writable OverlayFS from LABEL=5s-usb-root during initramfs local-bottom
mkdir -p "$STAGE_ROOTFS/etc/initramfs-tools/scripts/local-bottom"
cat > "$STAGE_ROOTFS/etc/initramfs-tools/scripts/local-bottom/5s-overlay" <<'EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "${1:-}" in
  prereqs) prereqs; exit 0 ;;
esac

[ -f "${rootmnt}/rootfs.squashfs" ] || exit 0

modprobe loop 2>/dev/null || true
modprobe squashfs 2>/dev/null || true
modprobe overlay 2>/dev/null || true

mkdir -p /run/5s-backing /run/5s-ro
mount -n -o move "${rootmnt}" /run/5s-backing
mount -n -o remount,rw,noatime /run/5s-backing 2>/dev/null || mount -n -o remount,rw /run/5s-backing

if ! mount -n -t squashfs -o loop,ro /run/5s-backing/rootfs.squashfs /run/5s-ro; then
  mount -n -o move /run/5s-backing "${rootmnt}"
  exit 1
fi

mkdir -p /run/5s-backing/overlay/upper /run/5s-backing/overlay/work
if ! mount -n -t overlay overlay \
  -o "lowerdir=/run/5s-ro,upperdir=/run/5s-backing/overlay/upper,workdir=/run/5s-backing/overlay/work" \
  "${rootmnt}"; then
  umount /run/5s-ro 2>/dev/null || true
  mount -n -o move /run/5s-backing "${rootmnt}"
  exit 1
fi

mkdir -p "${rootmnt}/boot" "${rootmnt}/mnt/5s-backing"
mount -n --bind /run/5s-backing/boot "${rootmnt}/boot" || true
mount -n -o move /run/5s-backing "${rootmnt}/mnt/5s-backing" || true
EOF
chmod +x "$STAGE_ROOTFS/etc/initramfs-tools/scripts/local-bottom/5s-overlay"

for mod in rc-core cec drm drm_kms_helper drm_display_helper drm_buddy ttm video i2c_algo_bit intel_gtt i915 xhci_pci xhci_hcd ehci_pci ehci_hcd usb_storage uas sd_mod scsi_mod rtsx_pci rtsx_pci_sdmmc mmc_block sdhci sdhci_pci ext4 crc32c_generic jbd2 mbcache hid usbhid hid_generic atkbd i8042 loop squashfs overlay zstd_decompress lz4_decompress; do
  if ! grep -qx "$mod" "$STAGE_ROOTFS/etc/initramfs-tools/modules" 2>/dev/null; then
    echo "$mod" >> "$STAGE_ROOTFS/etc/initramfs-tools/modules"
  fi
done
chroot "$STAGE_ROOTFS" update-initramfs -u

umount "$STAGE_ROOTFS/sys"
umount "$STAGE_ROOTFS/proc"
umount "$STAGE_ROOTFS/dev"

echo "4. Building compressed SquashFS rootfs..."
if mksquashfs "$STAGE_ROOTFS" "$SQFS_FILE" -e boot -comp zstd -Xcompression-level 19 -noappend 2>/dev/null; then
  true
else
  mksquashfs "$STAGE_ROOTFS" "$SQFS_FILE" -e boot -comp xz -noappend
fi

if [[ "$IMG_SIZE_MB" == "auto" ]]; then
  BOOT_MB="$(du -sm "$STAGE_ROOTFS/boot" | awk '{print $1}')"
  SQFS_MB="$(du -sm "$SQFS_FILE" | awk '{print $1}')"
  RAW_TOTAL_MB=$(( 65 + BOOT_MB + SQFS_MB + OVERLAY_FREE_MB ))
  # Round up to next 16 MiB boundary
  IMG_SIZE_MB=$(( ((RAW_TOTAL_MB + 15) / 16) * 16 ))
fi

echo "5. Creating ${IMG_SIZE_MB}MB hybrid UEFI+BIOS USB/SD disk image (SquashFS + ${OVERLAY_FREE_MB}MB overlay)..."
truncate -s "${IMG_SIZE_MB}M" "$IMG_RAW"
parted -s "$IMG_RAW" mklabel msdos
parted -s "$IMG_RAW" mkpart primary fat32 1MiB 65MiB
parted -s "$IMG_RAW" set 1 esp on
parted -s "$IMG_RAW" mkpart primary ext4 65MiB 100%
parted -s "$IMG_RAW" set 2 boot on

LOOP_DEV="$(losetup --find --show --partscan "$IMG_RAW")"
EFI_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"
for _ in $(seq 1 20); do
  [[ -b "$ROOT_PART" ]] && break
  partprobe "$LOOP_DEV" 2>/dev/null || true
  sleep 0.2
done

mkfs.vfat -F 32 -n 5S-USB-EFI "$EFI_PART"
mkfs.ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 -L 5s-usb-root "$ROOT_PART"
mount "$ROOT_PART" "$MNT_DIR"

mkdir -p "$MNT_DIR/boot/efi" "$MNT_DIR/overlay/upper" "$MNT_DIR/overlay/work"
cp -a "$STAGE_ROOTFS/boot/." "$MNT_DIR/boot/"
cp "$SQFS_FILE" "$MNT_DIR/rootfs.squashfs"

mount "$EFI_PART" "$MNT_DIR/boot/efi"
cat > "$MNT_DIR/boot/efi/wifi.txt" <<'EOF'
# 5s-browser External Wi-Fi & Feature Configuration (FAT32 partition: 5S-USB-EFI)
# Uncomment and fill in SSID and PASSWORD below (or put SSID on line 1 and PASSWORD on line 2):
#SSID=YourWiFiName
#PASSWORD=YourWiFiPassword
#
# Optional feature toggles (true/false, 1/0, yes/no, on/off; default: true):
#ENABLE_GMAIL=true
#ENABLE_YOUTUBE=true
#ENABLE_DISC=true
EOF

echo "6. Installing hybrid UEFI + Legacy BIOS GRUB2 for USB 3.0 & SD Card boot..."
mount --bind /dev "$STAGE_ROOTFS/dev"
mount --bind /proc "$STAGE_ROOTFS/proc"
mount --bind /sys "$STAGE_ROOTFS/sys"
mount --rbind "$MNT_DIR/boot" "$STAGE_ROOTFS/boot"

chroot "$STAGE_ROOTFS" grub-install --target=i386-pc --recheck --boot-directory=/boot "$LOOP_DEV"
chroot "$STAGE_ROOTFS" grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable --no-nvram
chroot "$STAGE_ROOTFS" update-grub
sed -i 's/root=[^ ]*/root=LABEL=5s-usb-root/g' "$MNT_DIR/boot/grub/grub.cfg"

sync
cleanup
trap - EXIT

echo "7. Compressing portable USB/SD image with xz..."
xz -T0 -6 -c "$IMG_RAW" > "$IMG_XZ"
rm -f "$IMG_RAW"

(
  cd "$ROOT_DIR/dist"
  sha256sum ./*.deb ./*.iso ./*.img.xz HOWTO.md 2>/dev/null > SHA256SUMS || sha256sum ./*.deb ./*.img.xz HOWTO.md > SHA256SUMS
)
ls -lh "$IMG_XZ"
