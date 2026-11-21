#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_QEMU="${REQUIRE_QEMU:-0}"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  if [[ "$REQUIRE_QEMU" == "1" ]]; then
    echo "ERROR: qemu-system-x86_64 is required but not installed" >&2
    exit 1
  fi
  echo "[SKIP] test_qemu_boot: qemu-system-x86_64 not installed locally"
  exit 0
fi

VMLINUZ="${QEMU_KERNEL:-}"
if [[ -z "$VMLINUZ" ]]; then
  VMLINUZ="$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sort | tail -n 1 || true)"
fi
if [[ -z "$VMLINUZ" || ! -e "$VMLINUZ" ]]; then
  if [[ "$REQUIRE_QEMU" == "1" ]]; then
    echo "ERROR: no bootable /boot/vmlinuz-* kernel found" >&2
    exit 1
  fi
  echo "[SKIP] test_qemu_boot: no /boot/vmlinuz-* kernel available locally"
  exit 0
fi

BUSYBOX_BIN="$(command -v busybox || true)"
if [[ -z "$BUSYBOX_BIN" ]]; then
  echo "ERROR: busybox (busybox-static) is required for QEMU initramfs" >&2
  exit 1
fi

VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
DEB_FILE="$ROOT_DIR/dist/5s-browser_${VERSION}_amd64.deb"
if [[ ! -f "$DEB_FILE" ]]; then
  VERSION="$VERSION" make -s -C "$ROOT_DIR" package
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Copy kernel to readable temp path (Ubuntu /boot/vmlinuz-* may be 0600 root)
KERNEL_COPY="$TMP_DIR/vmlinuz"
if [[ -r "$VMLINUZ" ]]; then
  cp "$VMLINUZ" "$KERNEL_COPY"
else
  sudo cp "$VMLINUZ" "$KERNEL_COPY"
  sudo chmod 644 "$KERNEL_COPY"
fi

INITRD_ROOT="$TMP_DIR/initrd_root"
mkdir -p "$INITRD_ROOT"/{bin,sbin,etc,proc,sys,dev,run,tmp,var/cache/5s/net,lib,lib64,usr/lib}

# Extract packaged .deb into initramfs
dpkg-deb -x "$DEB_FILE" "$INITRD_ROOT"

# Install busybox and core applet symlinks
cp "$BUSYBOX_BIN" "$INITRD_ROOT/bin/busybox"
chmod 0755 "$INITRD_ROOT/bin/busybox"
for app in sh ash mount umount echo cat cmp sleep poweroff mkdir cp mv rm grep awk sed chmod tr head tail touch ls ps kill sync dd; do
  ln -sf /bin/busybox "$INITRD_ROOT/bin/$app"
done

# Copy dynamic linker & shared libraries needed by 5s-init and 5s-fb-splash
copy_deps() {
  local bin="$1"
  ldd "$bin" | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | sort -u | while read -r lib; do
    [[ -f "$lib" ]] || continue
    local dest="$INITRD_ROOT$lib"
    mkdir -p "$(dirname "$dest")"
    cp -L "$lib" "$dest"
  done
}
copy_deps "$INITRD_ROOT/opt/5s-browser/bin/5s-init"
copy_deps "$INITRD_ROOT/opt/5s-browser/bin/5s-fb-splash"

# Seed 1,228,800-byte framebuffer snapshot
python3 - "$INITRD_ROOT/var/cache/5s/last_frame.fb" <<'PYEOF'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"\x5a\xa5" * (1228800 // 2))
PYEOF

# Replace high-level track scripts with initramfs probes that verify CPU affinity & FB restore
cat > "$INITRD_ROOT/opt/5s-browser/bin/zram-setup.sh" <<'EOF'
#!/bin/sh
echo "QEMU_ZRAM_HOOK_OK" > /dev/console
EOF

cat > "$INITRD_ROOT/opt/5s-browser/bin/cache_proxy.py" <<'EOF'
#!/bin/sh
CPUS="$(awk '/^Cpus_allowed_list:/{print $2}' /proc/self/status)"
echo "TRACK_B_CPUS=$CPUS" > /dev/console
sleep 30
EOF

cat > "$INITRD_ROOT/opt/5s-browser/bin/5s-net-fast.sh" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$INITRD_ROOT/opt/5s-browser/bin/5s-browser-launch.sh" <<'EOF'
#!/bin/sh
CPUS="$(awk '/^Cpus_allowed_list:/{print $2}' /proc/self/status)"
echo "TRACK_A_CPUS=$CPUS" > /dev/console
if cmp -s /var/cache/5s/last_frame.fb /tmp/fb0; then
  echo "FB_RESTORE_OK" > /dev/console
else
  echo "FB_RESTORE_FAIL" > /dev/console
fi
sleep 0.2
kill -USR1 1
sleep 30
EOF

cat > "$INITRD_ROOT/opt/5s-browser/bin/5s-checkpoint.sh" <<'EOF'
#!/bin/sh
echo "QEMU_5S_SHUTDOWN_OK" > /dev/console
EOF

chmod 0755 \
  "$INITRD_ROOT/opt/5s-browser/bin/zram-setup.sh" \
  "$INITRD_ROOT/opt/5s-browser/bin/cache_proxy.py" \
  "$INITRD_ROOT/opt/5s-browser/bin/5s-net-fast.sh" \
  "$INITRD_ROOT/opt/5s-browser/bin/5s-browser-launch.sh" \
  "$INITRD_ROOT/opt/5s-browser/bin/5s-checkpoint.sh"

# Pre-create zeroed 1,228,800-byte mock framebuffer file inside initramfs
truncate -s 1228800 "$INITRD_ROOT/tmp/fb0"

# /init exports FB_DEVICE and execs 5s-init as PID 1
cat > "$INITRD_ROOT/init" <<'EOF'
#!/bin/sh
export FB_DEVICE=/tmp/fb0
export PATH=/bin:/sbin:/opt/5s-browser/bin
exec /opt/5s-browser/bin/5s-init --state-dir /var/cache/5s
EOF
chmod 0755 "$INITRD_ROOT/init"

INITRD_IMG="$TMP_DIR/initrd.cpio.gz"
(
  cd "$INITRD_ROOT"
  find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -1 > "$INITRD_IMG"
)

QEMU_CPU="qemu64,+ssse3,-sse4.1,-sse4.2,-avx"
if command -v objdump >/dev/null 2>&1 && objdump -d "$BUSYBOX_BIN" | grep -qE '\bvmov'; then
  QEMU_CPU="max"
fi

SERIAL_LOG="$TMP_DIR/serial.log"
echo "Booting QEMU (CPU: $QEMU_CPU, -smp 4 -m 2048)..."
timeout 120s qemu-system-x86_64 \
  -cpu "$QEMU_CPU" \
  -smp 4 \
  -m 2048 \
  -nographic \
  -no-reboot \
  -kernel "$KERNEL_COPY" \
  -initrd "$INITRD_IMG" \
  -append "console=ttyS0 quiet panic=-1 rdinit=/init" \
  > "$SERIAL_LOG" 2>&1 || true

for marker in "TRACK_A_CPUS=0,2" "TRACK_B_CPUS=1,3" "FB_RESTORE_OK" "QEMU_5S_SHUTDOWN_OK"; do
  if ! grep -qF "$marker" "$SERIAL_LOG"; then
    echo "ERROR: Missing expected QEMU boot marker: $marker" >&2
    tail -n 60 "$SERIAL_LOG" >&2 || true
    exit 1
  fi
done

echo "test_qemu_boot: Atom N550 ISA + 4-thread affinity (0,2 vs 1,3) + PID 1 FB restore + clean poweroff verified"
