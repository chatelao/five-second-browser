#define _GNU_SOURCE
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t g_shutdown_requested = 0;

static void on_signal(int sig) {
    (void)sig;
    g_shutdown_requested = 1;
}

static void pin_cpus(int cpu_a, int cpu_b) {
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
            (void)nice(niceness);
        }
        execv(path, argv);
        _exit(127);
    }
    return pid;
}

static void setup_pid1_mounts(const char *bin_dir) {
    mkdir("/proc", 0755);
    mkdir("/sys", 0755);
    mkdir("/dev", 0755);
    mkdir("/run", 0755);
    (void)mount("proc", "/proc", "proc", 0, NULL);
    (void)mount("sysfs", "/sys", "sysfs", 0, NULL);
    (void)mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    (void)mount("tmpfs", "/run", "tmpfs", 0, "mode=0755");
    (void)mount(NULL, "/", NULL, MS_REMOUNT | MS_NOATIME, NULL);

    char zram_path[PATH_MAX + 64];
    snprintf(zram_path, sizeof(zram_path), "%s/zram-setup.sh", bin_dir);
    if (access(zram_path, X_OK) == 0) {
        char *zram_argv[] = {zram_path, NULL};
        (void)run_sync_cmd(zram_path, zram_argv);
    }
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

    if (getpid() == 1 && !test_mode) {
        setup_pid1_mounts(bin_dir);
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
    snprintf(proxy_bin, sizeof(proxy_bin), "%s/cache_proxy.py", bin_dir);
    snprintf(net_bin, sizeof(net_bin), "%s/5s-net-fast.sh", bin_dir);

    char state_arg[PATH_MAX];
    snprintf(state_arg, sizeof(state_arg), "%s", state_dir);

    pid_t proxy_pid = -1;
    if (access(proxy_bin, X_OK) == 0) {
        char *proxy_argv[] = {proxy_bin, "--state-dir", state_arg, "--port", "8555", NULL};
        proxy_pid = spawn_pinned(1, 3, 0, proxy_bin, proxy_argv);
    }

    pid_t net_pid = -1;
    if (access(net_bin, X_OK) == 0) {
        char *net_argv[] = {net_bin, "--boot", "--state-dir", state_arg, NULL};
        net_pid = spawn_pinned(1, 3, 10, net_bin, net_argv);
    }

    /* Step 3: Track A on Physical Core 0 (CPUs 0, 2) */
    char browser_bin[PATH_MAX + 64];
    snprintf(browser_bin, sizeof(browser_bin), "%s/5s-browser-launch.sh", bin_dir);

    pid_t browser_pid = -1;
    if (access(browser_bin, X_OK) == 0) {
        char *browser_argv[] = {browser_bin, "--state-dir", state_arg, NULL};
        browser_pid = spawn_pinned(0, 2, -10, browser_bin, browser_argv);
    }

    /* Supervisor loop until shutdown signal */
    while (!g_shutdown_requested) {
        int status = 0;
        pid_t exited = waitpid(-1, &status, WNOHANG);
        if (exited > 0) {
            if (exited == browser_pid) {
                browser_pid = -1;
                if (!test_mode) {
                    g_shutdown_requested = 1;
                }
            } else if (exited == proxy_pid) {
                proxy_pid = -1;
            } else if (exited == net_pid) {
                net_pid = -1;
            }
        }
        usleep(20000);
    }

    /* Step 4: Graceful Shutdown Checkpoint */
    char ckpt_bin[PATH_MAX + 64];
    snprintf(ckpt_bin, sizeof(ckpt_bin), "%s/5s-checkpoint.sh", bin_dir);
    if (access(ckpt_bin, X_OK) == 0) {
        char *ckpt_argv[] = {ckpt_bin, "--shutdown", "--state-dir", state_arg, NULL};
        (void)run_sync_cmd(ckpt_bin, ckpt_argv);
    }

    if (browser_pid > 0) kill(browser_pid, SIGTERM);
    if (net_pid > 0) kill(net_pid, SIGTERM);
    if (proxy_pid > 0) kill(proxy_pid, SIGTERM);

    usleep(50000);
    while (waitpid(-1, NULL, WNOHANG) > 0) {}

    sync();
    if (getpid() == 1 && !test_mode) {
        reboot(RB_POWER_OFF);
    }
    return 0;
}
