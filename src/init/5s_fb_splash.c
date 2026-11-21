#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define FRAME_BYTES (1024 * 600 * 2) /* 1,228,800 bytes (1024x600 RGB565) */

static int write_all(int fd, const void *buf, size_t len) {
    const unsigned char *p = (const unsigned char *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, p + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t len) {
    unsigned char *p = (unsigned char *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = read(fd, p + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) break;
        off += (size_t)n;
    }
    return (off == len) ? 0 : -1;
}

static int capture_frame(const char *fb_dev, const char *out_path) {
    int fb_fd = open(fb_dev, O_RDONLY);
    if (fb_fd < 0) {
        perror("5s-fb-splash: open fb for capture");
        return 1;
    }

    unsigned char *buf = malloc(FRAME_BYTES);
    if (!buf) {
        close(fb_fd);
        fprintf(stderr, "5s-fb-splash: out of memory\n");
        return 1;
    }

    void *mapped = mmap(NULL, FRAME_BYTES, PROT_READ, MAP_SHARED, fb_fd, 0);
    if (mapped != MAP_FAILED) {
        memcpy(buf, mapped, FRAME_BYTES);
        munmap(mapped, FRAME_BYTES);
    } else {
        if (read_all(fb_fd, buf, FRAME_BYTES) != 0) {
            perror("5s-fb-splash: read fb");
            free(buf);
            close(fb_fd);
            return 1;
        }
    }
    close(fb_fd);

    size_t tmp_len = strlen(out_path) + 5;
    char *tmp_path = malloc(tmp_len);
    if (!tmp_path) {
        free(buf);
        return 1;
    }
    snprintf(tmp_path, tmp_len, "%s.tmp", out_path);

    int out_fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        perror("5s-fb-splash: open snapshot tmp");
        free(tmp_path);
        free(buf);
        return 1;
    }

    if (write_all(out_fd, buf, FRAME_BYTES) != 0) {
        perror("5s-fb-splash: write snapshot");
        close(out_fd);
        unlink(tmp_path);
        free(tmp_path);
        free(buf);
        return 1;
    }

    fsync(out_fd);
    close(out_fd);
    free(buf);

    if (rename(tmp_path, out_path) != 0) {
        perror("5s-fb-splash: rename snapshot");
        unlink(tmp_path);
        free(tmp_path);
        return 1;
    }

    free(tmp_path);
    return 0;
}

static int restore_frame(const char *fb_dev, const char *in_path) {
    int in_fd = open(in_path, O_RDONLY);
    if (in_fd < 0) {
        perror("5s-fb-splash: open snapshot");
        return 1;
    }

    unsigned char *buf = malloc(FRAME_BYTES);
    if (!buf) {
        close(in_fd);
        return 1;
    }

    void *in_map = mmap(NULL, FRAME_BYTES, PROT_READ, MAP_PRIVATE, in_fd, 0);
    if (in_map != MAP_FAILED) {
        memcpy(buf, in_map, FRAME_BYTES);
        munmap(in_map, FRAME_BYTES);
    } else {
        if (read_all(in_fd, buf, FRAME_BYTES) != 0) {
            perror("5s-fb-splash: read snapshot");
            free(buf);
            close(in_fd);
            return 1;
        }
    }
    close(in_fd);

    int fb_fd = open(fb_dev, O_RDWR);
    if (fb_fd < 0) {
        perror("5s-fb-splash: open fb for restore");
        free(buf);
        return 1;
    }

    void *fb_map = mmap(NULL, FRAME_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fb_map != MAP_FAILED) {
        memcpy(fb_map, buf, FRAME_BYTES);
        munmap(fb_map, FRAME_BYTES);
    } else {
        if (lseek(fb_fd, 0, SEEK_SET) < 0 || write_all(fb_fd, buf, FRAME_BYTES) != 0) {
            perror("5s-fb-splash: write fb");
            free(buf);
            close(fb_fd);
            return 1;
        }
    }

    free(buf);
    close(fb_fd);
    return 0;
}

static void usage(void) {
    fprintf(stderr, "Usage:\n"
                    "  5s-fb-splash --capture <snapshot_path> [--fb <fb_dev>]\n"
                    "  5s-fb-splash --restore <snapshot_path> [--fb <fb_dev>]\n");
}

int main(int argc, char **argv) {
    const char *mode = NULL;
    const char *path = NULL;
    const char *fb_dev = getenv("FB_DEVICE");
    if (!fb_dev || fb_dev[0] == '\0') {
        fb_dev = "/dev/fb0";
    }

    for (int i = 1; i < argc; i++) {
        if ((strcmp(argv[i], "--capture") == 0 || strcmp(argv[i], "--restore") == 0) && i + 1 < argc) {
            mode = argv[i];
            path = argv[++i];
        } else if (strcmp(argv[i], "--fb") == 0 && i + 1 < argc) {
            fb_dev = argv[++i];
        } else {
            usage();
            return 2;
        }
    }

    if (!mode || !path) {
        usage();
        return 2;
    }

    if (strcmp(mode, "--capture") == 0) {
        return capture_frame(fb_dev, path);
    }
    return restore_frame(fb_dev, path);
}
