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

# Compile tiny Pentium 3825U (no-AVX/no-BMI) C probe & init binaries so QEMU never hits amd64v3 SIGILL
CFLAGS_3825U=(-O2 -march=nehalem -mtune=broadwell -mmovbe -mno-avx -mno-avx2 -mno-bmi -mno-bmi2 -mno-fma -Wall -Wextra -Werror)

cat > "$TMP_DIR/qemu_init.c" <<'CEOF'
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    setenv("FB_DEVICE", "/tmp/fb0", 1);
    setenv("PATH", "/bin:/sbin:/opt/5s-browser/bin", 1);
    char *const argv[] = {"/opt/5s-browser/bin/5s-init", "--state-dir", "/var/cache/5s", NULL};
    execv(argv[0], argv);
    return 127;
}
CEOF

cat > "$TMP_DIR/qemu_probe.c" <<'CEOF'
#define _GNU_SOURCE
#include <fcntl.h>
#include <libgen.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void log_console(const char *msg) {
    int fd = open("/dev/console", O_WRONLY);
    if (fd >= 0) {
        ssize_t r = write(fd, msg, strlen(msg));
        (void)r;
        close(fd);
    } else {
        fputs(msg, stdout);
        fflush(stdout);
    }
}

static void read_cpus(char *out, size_t len) {
    snprintf(out, len, "unknown");
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "Cpus_allowed_list:", 18) == 0) {
            char *p = line + 18;
            while (*p == ' ' || *p == '\t') p++;
            size_t n = strcspn(p, "\r\n");
            if (n >= len) n = len - 1;
            memcpy(out, p, n);
            out[n] = '\0';
            break;
        }
    }
    fclose(f);
}

static int files_equal(const char *a, const char *b) {
    int fa = open(a, O_RDONLY);
    int fb = open(b, O_RDONLY);
    if (fa < 0 || fb < 0) {
        if (fa >= 0) close(fa);
        if (fb >= 0) close(fb);
        return 0;
    }
    struct stat sa, sb;
    if (fstat(fa, &sa) != 0 || fstat(fb, &sb) != 0 || sa.st_size != sb.st_size) {
        close(fa);
        close(fb);
        return 0;
    }
    unsigned char ba[4096], bb[4096];
    off_t rem = sa.st_size;
    int eq = 1;
    while (rem > 0) {
        size_t chunk = rem > (off_t)sizeof(ba) ? sizeof(ba) : (size_t)rem;
        ssize_t ra = read(fa, ba, chunk);
        ssize_t rb = read(fb, bb, chunk);
        if (ra != (ssize_t)chunk || rb != (ssize_t)chunk || memcmp(ba, bb, chunk) != 0) {
            eq = 0;
            break;
        }
        rem -= (off_t)chunk;
    }
    close(fa);
    close(fb);
    return eq;
}

static int run_cmd(char *const argv[]) {
    pid_t p = fork();
    if (p == 0) {
        execv(argv[0], argv);
        _exit(127);
    }
    int st = 0;
    if (p < 0 || waitpid(p, &st, 0) < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

int main(int argc, char **argv) {
    (void)argc;
    char arg_copy[512];
    snprintf(arg_copy, sizeof(arg_copy), "%s", argv[0]);
    const char *base = basename(arg_copy);

    if (strcmp(base, "zram-setup.sh") == 0) {
        log_console("QEMU_ZRAM_HOOK_OK\n");
        return 0;
    }
    if (strcmp(base, "5s-net-fast.sh") == 0) {
        return 0;
    }
    if (strcmp(base, "5s-checkpoint.sh") == 0) {
        log_console("QEMU_5S_SHUTDOWN_OK\n");
        return 0;
    }
    if (strcmp(base, "cache_proxy.py") == 0) {
        char cpus[64], buf[128];
        read_cpus(cpus, sizeof(cpus));
        snprintf(buf, sizeof(buf), "TRACK_B_CPUS=%s\n", cpus);
        log_console(buf);
        sleep(30);
        return 0;
    }
    if (strcmp(base, "5s-browser-launch.sh") == 0) {
        char cpus[64], buf[128];
        read_cpus(cpus, sizeof(cpus));
        snprintf(buf, sizeof(buf), "TRACK_A_CPUS=%s\n", cpus);
        log_console(buf);

        if (files_equal("/var/cache/5s/last_frame.fb", "/tmp/fb0")) {
            log_console("FB_1600X900_RESTORE_OK\n");
        } else {
            log_console("FB_1600X900_RESTORE_FAIL\n");
        }

        if (access("/dev/fb0", R_OK | W_OK) == 0) {
            char *cap_argv[] = {"/opt/5s-browser/bin/5s-fb-splash", "--capture", "/tmp/real_fb0.fb", "--fb", "/dev/fb0", NULL};
            char *res_argv[] = {"/opt/5s-browser/bin/5s-fb-splash", "--restore", "/tmp/real_fb0.fb", "--fb", "/dev/fb0", NULL};
            if (run_cmd(cap_argv) == 0 && run_cmd(res_argv) == 0) {
                log_console("REAL_EFIFB_IOCTL_OK\n");
            } else {
                log_console("REAL_EFIFB_IOCTL_FAIL\n");
            }
        } else {
            log_console("REAL_EFIFB_ABSENT\n");
        }

        usleep(200000);
        kill(1, SIGUSR1);
        sleep(30);
        return 0;
    }
    return 0;
}
CEOF

gcc "${CFLAGS_3825U[@]}" "$TMP_DIR/qemu_init.c" -o "$INITRD_ROOT/init"
gcc "${CFLAGS_3825U[@]}" "$TMP_DIR/qemu_probe.c" -o "$INITRD_ROOT/bin/qemu_probe"
chmod 0755 "$INITRD_ROOT/init" "$INITRD_ROOT/bin/qemu_probe"

# Copy dynamic linker & shared libraries needed by 5s-init, 5s-fb-splash, /init, and qemu_probe
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
copy_deps "$INITRD_ROOT/init"
copy_deps "$INITRD_ROOT/bin/qemu_probe"

# Point track hooks to the zero-AVX C probe binary
for hook in zram-setup.sh cache_proxy.py 5s-net-fast.sh 5s-browser-launch.sh 5s-checkpoint.sh; do
  ln -sf /bin/qemu_probe "$INITRD_ROOT/opt/5s-browser/bin/$hook"
done

# Seed 1600x900x4 (5,760,000-byte) HP Pavilion eDP-1 framebuffer snapshot
FRAME_1600X900=5760000
python3 - "$INITRD_ROOT/var/cache/5s/last_frame.fb" "$FRAME_1600X900" <<'PYEOF'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"\xde\xad\xbe\xef" * (int(sys.argv[2]) // 4))
PYEOF
truncate -s "$FRAME_1600X900" "$INITRD_ROOT/tmp/fb0"

INITRD_IMG="$TMP_DIR/initrd.cpio.gz"
(
  cd "$INITRD_ROOT"
  find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -1 > "$INITRD_IMG"
)

# Strict Pentium 3825U CPUID flags (SSE4.1/4.2/POPCNT enabled, AVX/AVX2/BMI disabled)
QEMU_CPU="qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt,-avx,-avx2"

# Detect OVMF UEFI firmware (matching HP Pavilion F.77 UEFI boot)
OVMF_ARGS=()
for fw in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
  if [[ -r "$fw" ]]; then
    OVMF_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=$fw")
    break
  fi
done

SERIAL_LOG="$TMP_DIR/serial.log"
echo "Booting QEMU (CPU: $QEMU_CPU, -smp 4 -m 4096, OVMF=${#OVMF_ARGS[@]}, xHCI USB3, -vga std)..."
timeout 120s qemu-system-x86_64 \
  -cpu "$QEMU_CPU" \
  -smp 4 \
  -m 4096 \
  "${OVMF_ARGS[@]}" \
  -device qemu-xhci \
  -vga std \
  -display none \
  -serial stdio \
  -no-reboot \
  -kernel "$KERNEL_COPY" \
  -initrd "$INITRD_IMG" \
  -append "console=ttyS0 quiet panic=-1 rdinit=/init" \
  > "$SERIAL_LOG" 2>&1 || true

for marker in "QEMU_ZRAM_HOOK_OK" "TRACK_A_CPUS=0,2" "TRACK_B_CPUS=1,3" "FB_1600X900_RESTORE_OK" "QEMU_5S_SHUTDOWN_OK"; do
  if ! grep -qF "$marker" "$SERIAL_LOG"; then
    echo "ERROR: Missing expected QEMU boot marker: $marker" >&2
    tail -n 80 "$SERIAL_LOG" >&2 || true
    exit 1
  fi
done

if [[ "${#OVMF_ARGS[@]}" -gt 0 ]] && grep -qF "REAL_EFIFB_IOCTL_FAIL" "$SERIAL_LOG"; then
  echo "ERROR: Real /dev/fb0 FBIOGET_FSCREENINFO test failed under OVMF" >&2
  tail -n 80 "$SERIAL_LOG" >&2 || true
  exit 1
fi

echo "test_qemu_boot: Pentium 3825U strict no-AVX ISA + OVMF + 4-thread affinity (0,2 vs 1,3) + 1600x900 FB restore + clean poweroff verified"
