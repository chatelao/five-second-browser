#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <net/if.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <stdarg.h>
#include <time.h>

static volatile sig_atomic_t g_shutdown_requested = 0;
static char g_init_log_path[PATH_MAX + 64] = "";
static struct timespec g_boot_ts = {0, 0};

static void on_signal(int sig) {
    (void)sig;
    g_shutdown_requested = 1;
}

static void log_boot(const char *fmt, ...) {
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    fprintf(stderr, "%s\n", msg);
    fflush(stderr);

    int kfd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (kfd >= 0) {
        dprintf(kfd, "<6>%s\n", msg);
        close(kfd);
    }

    if (g_init_log_path[0] != '\0') {
        struct timespec now = {0, 0};
        clock_gettime(CLOCK_MONOTONIC, &now);
        long ms = (now.tv_sec - g_boot_ts.tv_sec) * 1000L +
                  (now.tv_nsec - g_boot_ts.tv_nsec) / 1000000L;
        if (ms < 0) ms = 0;
        int lfd = open(g_init_log_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (lfd >= 0) {
            dprintf(lfd, "[+%ld.%03lds] [init] %s\n", ms / 1000L, ms % 1000L, msg);
            close(lfd);
        }
    }
}

static void pin_cpus(int cpu_a, int cpu_b) {
    if (cpu_a < 0 || cpu_b < 0) return;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu_a, &set);
    CPU_SET(cpu_b, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        /* Fallback for CI runners with fewer than 4 logical CPUs */
        CPU_ZERO(&set);
        CPU_SET(0, &set);
        (void)sched_setaffinity(0, sizeof(set), &set);
    }
}

static void resolve_bin_dir(const char *argv0, char *out, size_t out_len) {
    const char *env_bin = getenv("BIN_DIR");
    if (env_bin && env_bin[0] != '\0') {
        snprintf(out, out_len, "%s", env_bin);
        return;
    }
    char exe_buf[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", exe_buf, sizeof(exe_buf) - 1);
    if (n > 0) {
        exe_buf[n] = '\0';
        char *dir = dirname(exe_buf);
        snprintf(out, out_len, "%s", dir);
        return;
    }
    char arg_buf[PATH_MAX];
    snprintf(arg_buf, sizeof(arg_buf), "%s", argv0);
    snprintf(out, out_len, "%s", dirname(arg_buf));
}

static int run_sync_cmd(const char *path, char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        execv(path, argv);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static pid_t spawn_pinned(int cpu_a, int cpu_b, int niceness, const char *path, char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        pin_cpus(cpu_a, cpu_b);
        if (niceness != 0) {
            errno = 0;
            if (nice(niceness) == -1 && errno != 0) {
                /* Best-effort priority adjustment */
            }
        }
        execv(path, argv);
        log_boot("5s-init: execv(%s) failed: %s", path, strerror(errno));
        _exit(127);
    }
    return pid;
}

static int is_submount(const char *path, const char *parent) {
    struct stat st_path, st_parent;
    if (stat(path, &st_path) != 0 || stat(parent, &st_parent) != 0) {
        return 0;
    }
    return st_path.st_dev != st_parent.st_dev;
}

static void bring_up_loopback(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "lo");
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) == 0) {
        ifr.ifr_flags |= IFF_UP;
        (void)ioctl(fd, SIOCSIFFLAGS, &ifr);
    }
    close(fd);
}

static void attach_tty1_console(void) {
    int fd = open("/dev/tty1", O_RDWR | O_NOCTTY);
    if (fd < 0) {
        fd = open("/dev/console", O_RDWR | O_NOCTTY);
    }
    if (fd >= 0) {
        (void)setsid();
        (void)ioctl(fd, TIOCSCTTY, 1);
        (void)dup2(fd, STDIN_FILENO);
        (void)dup2(fd, STDOUT_FILENO);
        (void)dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO) {
            close(fd);
        }
    }
}

static void setup_pid1_mounts(void) {
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 0);
    mkdir("/proc", 0755);
    mkdir("/sys", 0755);
    mkdir("/dev", 0755);
    mkdir("/run", 0755);
    if (!is_submount("/proc", "/")) (void)mount("proc", "/proc", "proc", 0, NULL);
    if (!is_submount("/sys", "/")) (void)mount("sysfs", "/sys", "sysfs", 0, NULL);
    if (!is_submount("/dev", "/")) (void)mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mkdir("/dev/pts", 0755);
    mkdir("/dev/shm", 01777);
    if (!is_submount("/dev/pts", "/dev")) (void)mount("devpts", "/dev/pts", "devpts", 0, NULL);
    if (!is_submount("/dev/shm", "/dev")) (void)mount("tmpfs", "/dev/shm", "tmpfs", 0, "mode=1777");
    mkdir("/tmp", 01777);
    if (access("/tmp/fb0", F_OK) != 0 && !is_submount("/tmp", "/")) {
        (void)mount("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");
    }
    (void)chmod("/tmp", 01777);
    if (!is_submount("/run", "/")) (void)mount("tmpfs", "/run", "tmpfs", 0, "mode=0755");
    (void)mount(NULL, "/", NULL, MS_REMOUNT | MS_NOATIME, NULL);
    {
        char hbuf[128] = "5s-browser";
        int hfd = open("/etc/hostname", O_RDONLY | O_CLOEXEC);
        if (hfd >= 0) {
            ssize_t hn = read(hfd, hbuf, sizeof(hbuf) - 1);
            close(hfd);
            if (hn > 0) {
                hbuf[hn] = '\0';
                for (ssize_t k = 0; k < hn; k++) {
                    if (hbuf[k] == '\n' || hbuf[k] == '\r' || hbuf[k] == ' ') {
                        hbuf[k] = '\0';
                        break;
                    }
                }
            }
        }
        if (hbuf[0] != '\0') {
            if (sethostname(hbuf, strlen(hbuf)) != 0) {
                /* Best-effort hostname setup */
            }
        }
    }
    attach_tty1_console();
    bring_up_loopback();

    if (access("/lib/systemd/systemd-udevd", X_OK) == 0) {
        char *udevd_argv[] = {"/lib/systemd/systemd-udevd", "--daemon", NULL};
        (void)run_sync_cmd("/lib/systemd/systemd-udevd", udevd_argv);
    }

    if (access("/usr/bin/dbus-daemon", X_OK) == 0 &&
        access("/run/dbus/system_bus_socket", F_OK) != 0) {
        mkdir("/run/dbus", 0755);
        mkdir("/var/lib/dbus", 0755);
        if (access("/usr/bin/dbus-uuidgen", X_OK) == 0) {
            char *uuid_argv[] = {"/usr/bin/dbus-uuidgen", "--ensure", NULL};
            (void)run_sync_cmd("/usr/bin/dbus-uuidgen", uuid_argv);
        }
        char *dbus_argv[] = {"/usr/bin/dbus-daemon", "--system", "--fork", "--nopidfile", NULL};
        (void)run_sync_cmd("/usr/bin/dbus-daemon", dbus_argv);
    }
}

static pid_t spawn_udev_trigger_async(void) {
    if (access("/usr/bin/udevadm", X_OK) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        pin_cpus(1, 3);
        errno = 0;
        if (nice(10) == -1 && errno != 0) {
            /* Best-effort priority adjustment */
        }
        char *trig_sub_argv[] = {"/usr/bin/udevadm", "trigger", "--type=subsystems", "--action=add", NULL};
        char *trig_dev_argv[] = {"/usr/bin/udevadm", "trigger", "--type=devices", "--action=add", NULL};
        (void)run_sync_cmd("/usr/bin/udevadm", trig_sub_argv);
        (void)run_sync_cmd("/usr/bin/udevadm", trig_dev_argv);
        _exit(0);
    }
    return pid;
}

static pid_t spawn_debug_tty2(void) {
    if (access("/dev/tty2", R_OK | W_OK) != 0 || access("/bin/bash", X_OK) != 0) {
        return -1;
    }
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int fd = open("/dev/tty2", O_RDWR | O_NOCTTY);
        if (fd >= 0) {
            (void)setsid();
            (void)ioctl(fd, TIOCSCTTY, 1);
            (void)dup2(fd, STDIN_FILENO);
            (void)dup2(fd, STDOUT_FILENO);
            (void)dup2(fd, STDERR_FILENO);
            if (fd > STDERR_FILENO) close(fd);
        }
        setenv("TERM", "linux", 1);
        char *sh_argv[] = {"/bin/bash", "-i", NULL};
        execv("/bin/bash", sh_argv);
        _exit(127);
    }
    return pid;
}

int main(int argc, char **argv) {
    const char *state_dir = getenv("STATE_DIR");
    if (!state_dir || state_dir[0] == '\0') {
        state_dir = "/var/cache/5s";
    }
    int test_mode = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--state-dir") == 0 && i + 1 < argc) {
            state_dir = argv[++i];
        } else if (strcmp(argv[i], "--test-mode") == 0) {
            test_mode = 1;
        }
    }

    char bin_dir[PATH_MAX];
    resolve_bin_dir(argv[0], bin_dir, sizeof(bin_dir));

    clock_gettime(CLOCK_MONOTONIC, &g_boot_ts);

    if (getpid() == 1 && !test_mode) {
        setup_pid1_mounts();
    }

    struct timespec t_after_mounts = {0, 0};
    clock_gettime(CLOCK_MONOTONIC, &t_after_mounts);
    long pre_init_ms = g_boot_ts.tv_sec * 1000L + g_boot_ts.tv_nsec / 1000000L;
    long mounts_ms = (t_after_mounts.tv_sec - g_boot_ts.tv_sec) * 1000L +
                     (t_after_mounts.tv_nsec - g_boot_ts.tv_nsec) / 1000000L;
    if (mounts_ms < 0) mounts_ms = 0;

    if (!test_mode) {
        char logs_dir[PATH_MAX + 32];
        char cache_dir[PATH_MAX + 32];
        mkdir(state_dir, 0755);
        snprintf(logs_dir, sizeof(logs_dir), "%.4000s/logs", state_dir);
        snprintf(cache_dir, sizeof(cache_dir), "%.4000s/chromium_cache", state_dir);
        mkdir(logs_dir, 0755);
        mkdir(cache_dir, 0755);
        if (getpid() == 1) {
            if (!is_submount(logs_dir, state_dir)) {
                (void)mount("tmpfs", logs_dir, "tmpfs", 0, "size=64M,mode=0755");
            }
            if (!is_submount(cache_dir, state_dir)) {
                (void)mount("tmpfs", cache_dir, "tmpfs", 0, "size=256M,mode=0755");
            }
        }
        snprintf(g_init_log_path, sizeof(g_init_log_path), "%.4000s/logs/init.log", state_dir);
        log_boot("5s-init: starting (pid=%d, pre_init=%ld.%03lds, mounts=%ldms, state_dir=%s, bin_dir=%s)",
                 (int)getpid(), pre_init_ms / 1000L, pre_init_ms % 1000L, mounts_ms, state_dir, bin_dir);

        int mfd = open("/run/5s-boot-marks", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (mfd >= 0) {
            dprintf(mfd, "5s_init_entry_ms=%ld\n5s_init_mounts_ms=%ld\n", pre_init_ms, mounts_ms);
            close(mfd);
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGUSR1, &sa, NULL);

    /* Step 1: Immediate Visual Restore (t = 0 ms) */
    char splash_bin[PATH_MAX + 64];
    char frame_path[PATH_MAX + 64];
    snprintf(splash_bin, sizeof(splash_bin), "%s/5s-fb-splash", bin_dir);
    snprintf(frame_path, sizeof(frame_path), "%s/last_frame.fb", state_dir);

    if (access(frame_path, R_OK) == 0 && access(splash_bin, X_OK) == 0) {
        char *splash_argv[] = {splash_bin, "--restore", frame_path, NULL};
        (void)run_sync_cmd(splash_bin, splash_argv);
    }

    /* Step 2: Track B on Physical Core 1 (CPUs 1, 3) */
    char proxy_bin[PATH_MAX + 64];
    char net_bin[PATH_MAX + 64];
    char zram_bin[PATH_MAX + 64];
    char usb_log_bin[PATH_MAX + 64];
    snprintf(proxy_bin, sizeof(proxy_bin), "%s/cache_proxy.py", bin_dir);
    snprintf(net_bin, sizeof(net_bin), "%s/5s-net-fast.sh", bin_dir);
    snprintf(zram_bin, sizeof(zram_bin), "%s/zram-setup.sh", bin_dir);
    snprintf(usb_log_bin, sizeof(usb_log_bin), "%s/5s-usb-log.sh", bin_dir);

    char state_arg[PATH_MAX];
    snprintf(state_arg, sizeof(state_arg), "%s", state_dir);

    pid_t proxy_pid = -1;
    if (access(proxy_bin, X_OK) == 0) {
        char *proxy_argv[] = {proxy_bin, "--state-dir", state_arg, "--port", "8555", "--offline", NULL};
        proxy_pid = spawn_pinned(1, 3, 0, proxy_bin, proxy_argv);
        if (!test_mode) log_boot("5s-init: spawned cache_proxy.py --offline (pid=%d)", (int)proxy_pid);
    } else if (!test_mode) {
        log_boot("5s-init: ERROR cache_proxy.py not executable at %s", proxy_bin);
    }

    pid_t net_pid = -1;
    if (access(net_bin, X_OK) == 0) {
        char *net_argv[] = {net_bin, "--boot", "--state-dir", state_arg, NULL};
        net_pid = spawn_pinned(1, 3, 10, net_bin, net_argv);
        if (!test_mode) log_boot("5s-init: spawned 5s-net-fast.sh (pid=%d)", (int)net_pid);
    }

    pid_t zram_pid = -1;
    if (access(zram_bin, X_OK) == 0) {
        char *zram_argv[] = {zram_bin, NULL};
        zram_pid = spawn_pinned(1, 3, 5, zram_bin, zram_argv);
        if (!test_mode) log_boot("5s-init: spawned zram-setup.sh (pid=%d)", (int)zram_pid);
    }

    char audio_bin[PATH_MAX + 64];
    snprintf(audio_bin, sizeof(audio_bin), "%s/5s-audio-init.sh", bin_dir);
    pid_t audio_pid = -1;
    if (access(audio_bin, X_OK) == 0) {
        char *audio_argv[] = {audio_bin, NULL};
        audio_pid = spawn_pinned(1, 3, 10, audio_bin, audio_argv);
        if (!test_mode) log_boot("5s-init: spawned 5s-audio-init.sh (pid=%d)", (int)audio_pid);
    }

    char optical_bin[PATH_MAX + 64];
    snprintf(optical_bin, sizeof(optical_bin), "%s/5s-optical-init.sh", bin_dir);
    pid_t optical_pid = -1;
    if (access(optical_bin, X_OK) == 0) {
        char *optical_argv[] = {optical_bin, NULL};
        optical_pid = spawn_pinned(1, 3, 15, optical_bin, optical_argv);
        if (!test_mode) log_boot("5s-init: spawned 5s-optical-init.sh (pid=%d)", (int)optical_pid);
    }

    pid_t udev_pid = -1;
    pid_t tty2_pid = -1;
    if (getpid() == 1 && !test_mode) {
        udev_pid = spawn_udev_trigger_async();
        tty2_pid = spawn_debug_tty2();
    }

    /* Step 3: Track A on Physical Core 0 (CPUs 0, 2) */
    char browser_bin[PATH_MAX + 64];
    snprintf(browser_bin, sizeof(browser_bin), "%s/5s-browser-launch.sh", bin_dir);

    pid_t browser_pid = -1;
    if (access(browser_bin, X_OK) == 0) {
        char *browser_argv[] = {browser_bin, "--state-dir", state_arg, NULL};
        browser_pid = spawn_pinned(0, 2, -10, browser_bin, browser_argv);
        if (!test_mode) log_boot("5s-init: spawned 5s-browser-launch.sh (pid=%d)", (int)browser_pid);
    } else if (!test_mode) {
        log_boot("5s-init: ERROR 5s-browser-launch.sh not executable at %s", browser_bin);
    }

    /* Supervisor loop until shutdown signal */
    while (!g_shutdown_requested) {
        int status = 0;
        pid_t exited = waitpid(-1, &status, WNOHANG);
        if (exited > 0) {
            if (exited == browser_pid) {
                browser_pid = -1;
                if (!test_mode) {
                    if (WIFEXITED(status)) {
                        int rc = WEXITSTATUS(status);
                        log_boot("5s-init: browser exited with code %d", rc);
                        if (access(usb_log_bin, X_OK) == 0) {
                            char *sync_argv[] = {usb_log_bin, "--sync", NULL};
                            (void)run_sync_cmd(usb_log_bin, sync_argv);
                        }
                        if (rc == 0) {
                            sleep(15);
                            g_shutdown_requested = 1;
                        } else {
                            log_boot("5s-init: browser failed; press Alt+F2 for shell or power button to shut down.");
                        }
                    } else if (WIFSIGNALED(status)) {
                        log_boot("5s-init: browser killed by signal %d", WTERMSIG(status));
                        log_boot("5s-init: press Alt+F2 for shell or power button to shut down.");
                        if (access(usb_log_bin, X_OK) == 0) {
                            char *sync_argv[] = {usb_log_bin, "--sync", NULL};
                            (void)run_sync_cmd(usb_log_bin, sync_argv);
                        }
                    }
                }
            } else if (exited == proxy_pid) {
                proxy_pid = -1;
                if (!test_mode) {
                    log_boot("5s-init: cache_proxy.py exited (status=0x%x)", status);
                }
            } else if (exited == net_pid) {
                net_pid = -1;
                if (!test_mode) {
                    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
                    log_boot("5s-init: 5s-net-fast.sh exited (rc=%d)", rc);
                }
            } else if (exited == zram_pid) {
                zram_pid = -1;
                if (!test_mode) {
                    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
                    log_boot("5s-init: zram-setup.sh exited (rc=%d)", rc);
                }
            } else if (exited == audio_pid) {
                audio_pid = -1;
                if (!test_mode) {
                    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
                    log_boot("5s-init: 5s-audio-init.sh exited (rc=%d)", rc);
                }
            } else if (exited == optical_pid) {
                optical_pid = -1;
                if (!test_mode) {
                    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
                    log_boot("5s-init: 5s-optical-init.sh exited (rc=%d)", rc);
                }
            } else if (exited == udev_pid) {
                udev_pid = -1;
            } else if (exited == tty2_pid) {
                tty2_pid = -1;
            }
        }
        usleep(20000);
    }

    /* Step 4: Graceful Shutdown Checkpoint */
    if (!test_mode) log_boot("5s-init: shutdown requested, running checkpoint...");
    char ckpt_bin[PATH_MAX + 64];
    snprintf(ckpt_bin, sizeof(ckpt_bin), "%s/5s-checkpoint.sh", bin_dir);
    if (access(ckpt_bin, X_OK) == 0) {
        char *ckpt_argv[] = {ckpt_bin, "--shutdown", "--state-dir", state_arg, NULL};
        (void)run_sync_cmd(ckpt_bin, ckpt_argv);
    }

    if (browser_pid > 0) kill(browser_pid, SIGTERM);
    if (net_pid > 0) kill(net_pid, SIGTERM);
    if (audio_pid > 0) kill(audio_pid, SIGTERM);
    if (optical_pid > 0) kill(optical_pid, SIGTERM);
    if (proxy_pid > 0) kill(proxy_pid, SIGTERM);
    if (tty2_pid > 0) kill(tty2_pid, SIGTERM);

    usleep(50000);
    while (waitpid(-1, NULL, WNOHANG) > 0) {}

    if (!test_mode && access(usb_log_bin, X_OK) == 0) {
        char *sync_argv[] = {usb_log_bin, "--sync", NULL};
        (void)run_sync_cmd(usb_log_bin, sync_argv);
    }

    sync();
    if (getpid() == 1 && !test_mode) {
        (void)umount("/boot/efi");
        (void)mount(NULL, "/mnt/5s-backing", NULL, MS_REMOUNT | MS_RDONLY, NULL);
        (void)mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY, NULL);
        sync();
        reboot(RB_POWER_OFF);
    }
    return 0;
}
