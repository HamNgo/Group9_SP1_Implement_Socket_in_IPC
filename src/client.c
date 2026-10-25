#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "protocol.h"
#include "utils.h"

static int send_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        p += w; n -= (size_t)w;
    }
    return 0;
}

static int recv_all(int fd, void *buf, size_t n) {
    char *p = buf;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        p += r; n -= (size_t)r;
    }
    return 0;
}

static const char *status_name(uint32_t s) {
    switch (s) {
        case STATUS_OK:           return "OK";
        case STATUS_ERR_PROTO:    return "ERR_PROTOCOL";
        case STATUS_ERR_TOO_BIG:  return "ERR_TOO_BIG";
        case STATUS_ERR_BUSY:     return "ERR_BUSY";
        case STATUS_ERR_IO:       return "ERR_IO";
        case STATUS_ERR_CHECKSUM: return "ERR_CHECKSUM";
        default:                  return "UNKNOWN";
    }
}

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void usage(const char *p) {
    fprintf(stderr,
        "Usage: %s [-m stats|upper|reverse] <input_file>\n"
        "       %s --ping\n"
        "Test flags: --bad-checksum  --bad-magic\n", p, p);
}

int main(int argc, char **argv) {
    uint32_t mode = PROC_STATS;
    int ping = 0, bad_sum = 0, bad_magic = 0;
    const char *path = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--ping")) ping = 1;
        else if (!strcmp(argv[i], "--bad-checksum")) bad_sum = 1;
        else if (!strcmp(argv[i], "--bad-magic")) bad_magic = 1;
        else if (!strcmp(argv[i], "-m") && i + 1 < argc) {
            const char *m = argv[++i];
            if (!strcmp(m, "stats")) mode = PROC_STATS;
            else if (!strcmp(m, "upper")) mode = PROC_UPPER;
            else if (!strcmp(m, "reverse")) mode = PROC_REVERSE;
            else { fprintf(stderr, "Unknown mode '%s'\n", m); usage(argv[0]); return 2; }
        }
        else if (argv[i][0] != '-' && !path) path = argv[i];
        else { usage(argv[0]); return 2; }
    }
    if (!ping && !path) { usage(argv[0]); return 2; }
    signal(SIGPIPE, SIG_IGN);

    msg_header_t h;
    memset(&h, 0, sizeof(h));
    h.magic = bad_magic ? 0xDEADBEEFu : PROTO_MAGIC;
    h.client_pid = (uint32_t)getpid();

    char *data = NULL;
    size_t len = 0;

    if (ping) {
        h.type = MSG_PING;
        printf("[CLIENT] PID %d -> sending PING\n", getpid());
    } else {
        data = read_whole_file(path, &len);
        if (!data) { fprintf(stderr, "[CLIENT] Cannot read '%s': %s\n", path, strerror(errno)); return 1; }
        if (len > MAX_FILE_SIZE) { fprintf(stderr, "[CLIENT] File too large (>10MB)\n"); free(data); return 1; }
        const char *base = strrchr(path, '/');
        snprintf(h.filename, sizeof(h.filename), "%s", base ? base + 1 : path);
        h.type = MSG_SEND_FILE;
        h.data_len = (uint32_t)len;
        h.mode = mode;
        h.checksum = fnv1a32(data, len);
        if (bad_sum) h.checksum ^= 0xFFFFFFFFu;     /* simulate corruption */
        printf("[CLIENT] PID %d read '%s': %zu bytes\n", getpid(), path, len);
        printf("[CLIENT] mode=%s  checksum=0x%08x%s\n", proc_mode_name(mode), h.checksum,
               bad_sum ? "  (deliberately corrupted)" : "");
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); free(data); return 1; }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", SOCKET_PATH);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[CLIENT] Cannot connect to %s: %s\n[CLIENT] Is the server running?\n",
                SOCKET_PATH, strerror(errno));
        close(fd); free(data); return 1;
    }
    printf("[CLIENT] Connected to %s\n", SOCKET_PATH);

    double t0 = now_ms();
    fflush(stdout);
    /* If the server rejects us early it may close before we finish sending;
     * that is not fatal: we still try to read its explanation below. */
    int send_failed = (send_all(fd, &h, sizeof(h)) < 0 || (len && send_all(fd, data, len) < 0));
    free(data);

    reply_t r;
    if (recv_all(fd, &r, sizeof(r)) < 0 || r.magic != PROTO_MAGIC) {
        fprintf(stderr, "[CLIENT] %s\n", send_failed ? "Send failed and no reply from server"
                                                   : "Invalid or missing reply from server");
        close(fd); return 1;
    }
    double rtt = now_ms() - t0;
    r.message[MAX_REPLY_LEN - 1] = '\0';

    printf("[CLIENT] Reply in %.3f ms\n", rtt);
    printf("         status : %s\n", status_name(r.status));
    printf("         message: %s\n", r.message);
    close(fd);
    return r.status == STATUS_OK ? 0 : 1;
}
