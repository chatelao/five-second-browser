#!/usr/bin/env bash
set -euo pipefail

# Automated unattended installer executed when booted from the 5s-browser USB ISO
# (triggered when /proc/cmdline contains 5s_autoinstall=1).

if ! grep -qw '5s_autoinstall=1' /proc/cmdline 2>/dev/null; then
  exit 0
fi

on_error() {
  local rc=$?
  local line=$1
  echo ""
  echo "============================================================"
  echo "ERROR: 5s-browser installer failed at line ${line} (exit ${rc})"
  echo "============================================================"
  lsblk -o NAME,SIZE,TYPE,TRAN,MOUNTPOINTS 2>/dev/null || lsblk 2>/dev/null || true
  echo "Dropping to recovery shell so you can inspect the error..."
  exec /bin/bash
}
trap 'on_error $LINENO' ERR

MOUNT_TARGET="/mnt/5s-target"

echo "=== 5s-browser Unattended Installer (HP Pavilion 3825U) ==="

# 1. Locate SquashFS image on live medium
SQUASHFS_PATH="${SQUASHFS_PATH:-}"
if [[ -z "$SQUASHFS_PATH" ]]; then
  for cand in \
    /run/live/medium/live/filesystem.squashfs \
    /usr/lib/live/mount/medium/live/filesystem.squashfs \
    /lib/live/mount/medium/live/filesystem.squashfs; do
    if [[ -f "$cand" ]]; then
      SQUASHFS_PATH="$cand"
      break
    fi
  done
fi

if [[ -z "$SQUASHFS_PATH" || ! -f "$SQUASHFS_PATH" ]]; then
  echo "ERROR: SquashFS image not found on live medium." >&2
  false
fi

# 2. Detect live boot disk so we never overwrite the installer USB stick
LIVE_SRC=""
for mp in /run/live/medium /usr/lib/live/mount/medium /lib/live/mount/medium; do
  LIVE_SRC="$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)"
  [[ -n "$LIVE_SRC" ]] && break
done

LIVE_DISK=""
if [[ -n "$LIVE_SRC" ]]; then
  LIVE_PARENT="$(lsblk -no PKNAME "$LIVE_SRC" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$LIVE_PARENT" ]]; then
    LIVE_DISK="/dev/${LIVE_PARENT}"
  else
    LIVE_DISK="$LIVE_SRC"
  fi
fi

TARGET_DISK="${TARGET_DISK:-}"
if [[ -z "$TARGET_DISK" ]]; then
  while read -r dev type; do
    [[ "$type" == "disk" ]] || continue
    [[ "$dev" == /dev/loop* || "$dev" == /dev/ram* || "$dev" == /dev/zram* || "$dev" == /dev/sr* ]] && continue
    if [[ -n "$LIVE_DISK" && "$dev" == "$LIVE_DISK" ]]; then
      continue
    fi
    TARGET_DISK="$dev"
    break
  done < <(lsblk -dpno NAME,TYPE 2>/dev/null || true)
fi

echo "Live medium: ${LIVE_DISK:-unknown} (${SQUASHFS_PATH})"
echo "Target disk: ${TARGET_DISK:-none}"

if [[ -z "$TARGET_DISK" || ! -b "$TARGET_DISK" ]]; then
  echo "ERROR: No suitable internal target disk found (live USB is ${LIVE_DISK:-unknown})." >&2
  false
fi

if [[ -n "$LIVE_DISK" && "$TARGET_DISK" == "$LIVE_DISK" ]]; then
  echo "ERROR: Refusing to overwrite live boot medium $LIVE_DISK." >&2
  false
fi

# 3. Partition target disk: 128MiB FAT32 ESP + ext4 root (supports both UEFI F.77 and Legacy BIOS)
echo "Partitioning $TARGET_DISK..."
parted -s "$TARGET_DISK" mklabel msdos
parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 129MiB
parted -s "$TARGET_DISK" set 1 esp on
parted -s "$TARGET_DISK" mkpart primary ext4 129MiB 100%
parted -s "$TARGET_DISK" set 2 boot on
partprobe "$TARGET_DISK" 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || sleep 2

if [[ "$TARGET_DISK" =~ [0-9]$ ]]; then
  EFI_PART="${TARGET_DISK}p1"
  ROOT_PART="${TARGET_DISK}p2"
else
  EFI_PART="${TARGET_DISK}1"
  ROOT_PART="${TARGET_DISK}2"
fi

for _ in $(seq 1 20); do
  [[ -b "$EFI_PART" && -b "$ROOT_PART" ]] && break
  partprobe "$TARGET_DISK" 2>/dev/null || true
  sleep 0.25
done

echo "Formatting $EFI_PART (FAT32) and $ROOT_PART (ext4)..."
mkfs.vfat -F 32 -n 5S-EFI "$EFI_PART"
mkfs.ext4 -F -L 5s-root "$ROOT_PART"

mkdir -p "$MOUNT_TARGET"
mount "$ROOT_PART" "$MOUNT_TARGET"

# 4. Extract pre-configured Debian 12 + 5s-browser rootfs
echo "Installing system image from $SQUASHFS_PATH..."
unsquashfs -f -d "$MOUNT_TARGET" "$SQUASHFS_PATH"

mkdir -p "$MOUNT_TARGET/boot/efi"
mount "$EFI_PART" "$MOUNT_TARGET/boot/efi"

# Remove live-only autoinstall hook from installed disk
rm -f "$MOUNT_TARGET/etc/systemd/system/multi-user.target.wants/5s-autoinstall.service"
rm -f "$MOUNT_TARGET/etc/systemd/system/5s-autoinstall.service"

# 5. Write /etc/fstab
cat > "$MOUNT_TARGET/etc/fstab" <<EOF
LABEL=5s-root  /          ext4  defaults,noatime  0  1
LABEL=5S-EFI   /boot/efi  vfat  umask=0077        0  2
EOF

# 6. Install both UEFI (x86_64-efi --removable) and Legacy BIOS (i386-pc) GRUB2 bootloaders
echo "Installing UEFI + Legacy BIOS GRUB2 to $TARGET_DISK..."
mount --bind /dev "$MOUNT_TARGET/dev"
mount --bind /proc "$MOUNT_TARGET/proc"
mount --bind /sys "$MOUNT_TARGET/sys"

chroot "$MOUNT_TARGET" grub-install --target=i386-pc --recheck "$TARGET_DISK" || true
chroot "$MOUNT_TARGET" grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram || true
chroot "$MOUNT_TARGET" update-grub

umount "$MOUNT_TARGET/sys" "$MOUNT_TARGET/proc" "$MOUNT_TARGET/dev" "$MOUNT_TARGET/boot/efi" "$MOUNT_TARGET"
sync

echo "Installation complete! Remove the USB stick and rebooting into 5s-browser..."
sleep 3
reboot -f
