#!/usr/bin/env bash
set -euo pipefail

# Automated unattended installer executed when booted from the 5s-browser USB ISO
# (triggered when /proc/cmdline contains 5s_autoinstall=1).

if ! grep -qw '5s_autoinstall=1' /proc/cmdline 2>/dev/null; then
  exit 0
fi

TARGET_DISK="${TARGET_DISK:-/dev/sda}"
SQUASHFS_PATH="${SQUASHFS_PATH:-/run/live/medium/live/filesystem.squashfs}"
MOUNT_TARGET="/mnt/5s-target"

echo "=== 5s-browser Unattended Installer (HP Pavilion 3825U) ==="
echo "Target disk: $TARGET_DISK"

if [[ ! -b "$TARGET_DISK" ]]; then
  echo "ERROR: Target disk $TARGET_DISK not found." >&2
  sleep 10
  exit 1
fi

if [[ ! -f "$SQUASHFS_PATH" ]]; then
  echo "ERROR: SquashFS image $SQUASHFS_PATH not found." >&2
  sleep 10
  exit 1
fi

# 1. Partition /dev/sda: 128MiB FAT32 ESP + ext4 root (supports both UEFI F.77 and Legacy BIOS)
parted -s "$TARGET_DISK" mklabel msdos
parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 129MiB
parted -s "$TARGET_DISK" set 1 esp on
parted -s "$TARGET_DISK" mkpart primary ext4 129MiB 100%
parted -s "$TARGET_DISK" set 2 boot on
partprobe "$TARGET_DISK" 2>/dev/null || true
sleep 1

EFI_PART="${TARGET_DISK}1"
ROOT_PART="${TARGET_DISK}2"
mkfs.vfat -F 32 -n 5S-EFI "$EFI_PART"
mkfs.ext4 -F -L 5s-root "$ROOT_PART"

mkdir -p "$MOUNT_TARGET"
mount "$ROOT_PART" "$MOUNT_TARGET"

# 2. Extract pre-configured Debian 12 + 5s-browser rootfs
echo "Installing system image..."
unsquashfs -f -d "$MOUNT_TARGET" "$SQUASHFS_PATH"

mkdir -p "$MOUNT_TARGET/boot/efi"
mount "$EFI_PART" "$MOUNT_TARGET/boot/efi"

# Remove live-only autoinstall hook from installed disk
rm -f "$MOUNT_TARGET/etc/systemd/system/multi-user.target.wants/5s-autoinstall.service"
rm -f "$MOUNT_TARGET/etc/systemd/system/5s-autoinstall.service"

# 3. Write /etc/fstab
cat > "$MOUNT_TARGET/etc/fstab" <<EOF
LABEL=5s-root  /          ext4  defaults,noatime  0  1
LABEL=5S-EFI   /boot/efi  vfat  umask=0077        0  2
EOF

# 4. Install both UEFI (x86_64-efi --removable) and Legacy BIOS (i386-pc) GRUB2 bootloaders
mount --bind /dev "$MOUNT_TARGET/dev"
mount --bind /proc "$MOUNT_TARGET/proc"
mount --bind /sys "$MOUNT_TARGET/sys"

chroot "$MOUNT_TARGET" grub-install --target=i386-pc "$TARGET_DISK" || true
chroot "$MOUNT_TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram || true
chroot "$MOUNT_TARGET" update-grub

umount "$MOUNT_TARGET/sys" "$MOUNT_TARGET/proc" "$MOUNT_TARGET/dev" "$MOUNT_TARGET/boot/efi" "$MOUNT_TARGET"
sync

echo "Installation complete! Rebooting into 5s-browser..."
sleep 2
reboot -f
