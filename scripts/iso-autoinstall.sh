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

echo "=== 5s-browser Unattended Installer ==="
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

# 1. Partition /dev/sda (single ext4 root partition)
parted -s "$TARGET_DISK" mklabel msdos
parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 100%
parted -s "$TARGET_DISK" set 1 boot on
partprobe "$TARGET_DISK" 2>/dev/null || true
sleep 1

TARGET_PART="${TARGET_DISK}1"
mkfs.ext4 -F -L 5s-root "$TARGET_PART"

mkdir -p "$MOUNT_TARGET"
mount "$TARGET_PART" "$MOUNT_TARGET"

# 2. Extract pre-configured Debian 12 + 5s-browser rootfs
echo "Installing system image..."
unsquashfs -f -d "$MOUNT_TARGET" "$SQUASHFS_PATH"

# Remove live-only autoinstall hook from installed disk
rm -f "$MOUNT_TARGET/etc/systemd/system/multi-user.target.wants/5s-autoinstall.service"
rm -f "$MOUNT_TARGET/etc/systemd/system/5s-autoinstall.service"

# 3. Write /etc/fstab
cat > "$MOUNT_TARGET/etc/fstab" <<EOF
${TARGET_PART}  /  ext4  defaults,noatime  0  1
EOF

# 4. Install GRUB2 bootloader to /dev/sda
mount --bind /dev "$MOUNT_TARGET/dev"
mount --bind /proc "$MOUNT_TARGET/proc"
mount --bind /sys "$MOUNT_TARGET/sys"

chroot "$MOUNT_TARGET" grub-install --target=i386-pc "$TARGET_DISK"
chroot "$MOUNT_TARGET" update-grub

umount "$MOUNT_TARGET/sys" "$MOUNT_TARGET/proc" "$MOUNT_TARGET/dev" "$MOUNT_TARGET"
sync

echo "Installation complete! Rebooting into 5s-browser..."
sleep 2
reboot -f
