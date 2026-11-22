#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_QEMU="${REQUIRE_QEMU:-0}"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
IMG_XZ="${IMG_XZ:-$ROOT_DIR/dist/5s-browser-${VERSION}-usb-sd-amd64.img.xz}"

skip_or_fail() {
  local msg="$1"
  if [[ "$REQUIRE_QEMU" == "1" ]]; then
    echo "ERROR: $msg" >&2
    exit 1
  fi
  echo "SKIP: $msg"
  exit 0
}

for cmd in qemu-system-x86_64 xz losetup mount umount; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    skip_or_fail "$cmd not installed; skipping USB/UEFI QEMU boot test"
  fi
done

if [[ "$(id -u)" -ne 0 ]]; then
  skip_or_fail "USB image loop-mount inspection requires root (run under sudo in CI/release)"
fi

if [[ ! -f "$IMG_XZ" ]]; then
  skip_or_fail "USB/SD image $IMG_XZ not found; build it with scripts/build_usb_img.sh first"
fi

OVMF_CODE=""
for candidate in \
  /usr/share/OVMF/OVMF_CODE_4M.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/ovmf/OVMF.fd; do
  if [[ -f "$candidate" ]]; then
    OVMF_CODE="$candidate"
    break
  fi
done
if [[ -z "$OVMF_CODE" ]]; then
  skip_or_fail "OVMF firmware not found; skipping UEFI USB QEMU test"
fi

OVMF_VARS=""
for candidate in \
  /usr/share/OVMF/OVMF_VARS_4M.fd \
  /usr/share/OVMF/OVMF_VARS.fd; do
  if [[ -f "$candidate" ]]; then
    OVMF_VARS="$candidate"
    break
  fi
done

WORK_DIR="$(mktemp -d /tmp/5s-qemu-usb-XXXXXX)"
TEST_IMG="$WORK_DIR/usb-test.img"
MNT_DIR="$WORK_DIR/mnt"
SQFS_DIR="$WORK_DIR/sqfs"
SERIAL_LOG="$WORK_DIR/serial.log"
LOOP_DEV=""
QEMU_PID=""

cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  umount "$SQFS_DIR" 2>/dev/null || true
  umount "$MNT_DIR/boot/efi" 2>/dev/null || true
  umount "$MNT_DIR" 2>/dev/null || true
  if [[ -n "$LOOP_DEV" ]]; then
    losetup -d "$LOOP_DEV" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "[usb-uefi] Decompressing $IMG_XZ to temporary test image..."
xz -dc "$IMG_XZ" > "$TEST_IMG"

mkdir -p "$MNT_DIR" "$SQFS_DIR"
LOOP_DEV="$(losetup --find --show --partscan "$TEST_IMG")"
EFI_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"
for _ in $(seq 1 20); do
  [[ -b "$ROOT_PART" ]] && break
  partprobe "$LOOP_DEV" 2>/dev/null || true
  sleep 0.2
done

if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
  echo "ERROR: Expected EFI (${EFI_PART}) and root (${ROOT_PART}) partitions on USB image" >&2
  exit 1
fi

mount "$ROOT_PART" "$MNT_DIR"
mkdir -p "$MNT_DIR/boot/efi"
mount "$EFI_PART" "$MNT_DIR/boot/efi"

for required in \
  "$MNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" \
  "$MNT_DIR/boot/grub/grub.cfg"; do
  if [[ ! -e "$required" ]]; then
    echo "ERROR: Missing $required in USB/SD image" >&2
    exit 1
  fi
done

if [[ -f "$MNT_DIR/rootfs.squashfs" ]]; then
  mount -o loop,ro "$MNT_DIR/rootfs.squashfs" "$SQFS_DIR"
  if [[ ! -e "$SQFS_DIR/opt/5s-browser/bin/5s-init" ]]; then
    echo "ERROR: Missing /opt/5s-browser/bin/5s-init in rootfs.squashfs" >&2
    exit 1
  fi
  mkdir -p "$MNT_DIR/overlay/upper/opt/5s-browser/bin"
  cp -a "$SQFS_DIR/opt/5s-browser/bin/5s-browser-launch.sh" \
    "$MNT_DIR/overlay/upper/opt/5s-browser/bin/5s-browser-launch.sh"
  LAUNCH_SCRIPT="$MNT_DIR/overlay/upper/opt/5s-browser/bin/5s-browser-launch.sh"
  umount "$SQFS_DIR"
else
  if [[ ! -e "$MNT_DIR/opt/5s-browser/bin/5s-init" ]]; then
    echo "ERROR: Missing $MNT_DIR/opt/5s-browser/bin/5s-init in USB/SD image" >&2
    exit 1
  fi
  LAUNCH_SCRIPT="$MNT_DIR/opt/5s-browser/bin/5s-browser-launch.sh"
fi

if ! grep -q "init=/opt/5s-browser/bin/5s-init" "$MNT_DIR/boot/grub/grub.cfg"; then
  echo "ERROR: grub.cfg missing init=/opt/5s-browser/bin/5s-init" >&2
  exit 1
fi
if ! grep -q "root=LABEL=5s-usb-root" "$MNT_DIR/boot/grub/grub.cfg"; then
  echo "ERROR: grub.cfg missing root=LABEL=5s-usb-root" >&2
  exit 1
fi

# Enable serial console logging and software renderer fallback ONLY on the temporary test image copy
sed -i -E 's/(quiet )?loglevel=[0-7]/loglevel=7 console=ttyS0,115200/g' "$MNT_DIR/boot/grub/grub.cfg"
sed -i '/export LIBSEAT_BACKEND=/a export WLR_RENDERER=pixman\nexport WLR_RENDERER_ALLOW_SOFTWARE=1' "$LAUNCH_SCRIPT"
sync

umount "$MNT_DIR/boot/efi"
umount "$MNT_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

QEMU_ARGS=(
  -machine q35
  -cpu "qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,-avx,-avx2"
  -smp 4
  -m 4096
  -vga virtio
  -display none
  -net none
  -serial "file:${SERIAL_LOG}"
  -no-reboot
  -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
  -device "qemu-xhci,id=xhci"
  -drive "id=usbstick,if=none,format=raw,file=${TEST_IMG}"
  -device "usb-storage,bus=xhci.0,drive=usbstick,bootindex=1"
)

if [[ -n "$OVMF_VARS" ]]; then
  cp "$OVMF_VARS" "$WORK_DIR/OVMF_VARS.fd"
  QEMU_ARGS+=(-drive "if=pflash,format=raw,file=${WORK_DIR}/OVMF_VARS.fd")
fi

echo "[usb-uefi] Booting USB 3.0 image under OVMF UEFI (Pentium 3825U 4C/4GB -avx,-avx2)..."
: > "$SERIAL_LOG"
qemu-system-x86_64 "${QEMU_ARGS[@]}" >/dev/null 2>&1 &
QEMU_PID=$!

DEADLINE=$((SECONDS + 90))
BOOTED_KERNEL=0
RAN_ZRAM_INIT=0
STARTED_BROWSER=0

while (( SECONDS < DEADLINE )); do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    break
  fi
  if grep -qE "Kernel panic|Invalid opcode|Attempted to kill init|XDG_RUNTIME_DIR is not set|5s-init: browser (exited|killed)" "$SERIAL_LOG" 2>/dev/null; then
    echo "ERROR: Fatal kernel/PID 1/browser failure detected during USB UEFI boot:" >&2
    tail -n 60 "$SERIAL_LOG" >&2 || true
    exit 1
  fi
  if grep -q "init=/opt/5s-browser/bin/5s-init" "$SERIAL_LOG" 2>/dev/null; then
    BOOTED_KERNEL=1
  fi
  if grep -qE "zram0: (detected capacity change|configured)|Adding .* swap on /dev/zram0" "$SERIAL_LOG" 2>/dev/null; then
    RAN_ZRAM_INIT=1
  fi
  if grep -q "5s-browser: starting Cage + Chromium" "$SERIAL_LOG" 2>/dev/null; then
    STARTED_BROWSER=1
    sleep 4
    if grep -qE "Kernel panic|Invalid opcode|Attempted to kill init|XDG_RUNTIME_DIR is not set|5s-init: browser (exited|killed)|Unable to create the wlroots backend" "$SERIAL_LOG" 2>/dev/null; then
      echo "ERROR: Fatal browser/wlroots failure detected after launch:" >&2
      tail -n 60 "$SERIAL_LOG" >&2 || true
      exit 1
    fi
    break
  fi
  sleep 1
done

kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=""

if [[ "$BOOTED_KERNEL" != "1" || "$RAN_ZRAM_INIT" != "1" || "$STARTED_BROWSER" != "1" ]]; then
  echo "ERROR: USB 3.0 UEFI boot verification timed out (BOOTED_KERNEL=$BOOTED_KERNEL RAN_ZRAM_INIT=$RAN_ZRAM_INIT STARTED_BROWSER=$STARTED_BROWSER)" >&2
  tail -n 80 "$SERIAL_LOG" >&2 || true
  exit 1
fi

echo "PASS: OVMF UEFI + qemu-xhci USB 3.0 boot test passed (GRUB2 -> kernel -> 5s-init -> zram0 active on Pentium 3825U -avx,-avx2)."
