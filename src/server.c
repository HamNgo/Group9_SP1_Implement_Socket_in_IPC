#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <syslog.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <pthread.h>
#include <fcntl.h>
#include "protocol.h"
#include "utils.h"
#include <limits.h>

/* ================= Biến toàn cục ================= */

// Cờ báo dừng hệ thống: Signal handler gán = 1, vòng lặp chính kiểm tra
static volatile sig_atomic_t g_stop = 0;

// Đồng bộ bộ đếm số luồng đang hoạt động để phục vụ Graceful Shutdown
static pthread_mutex_t g_cnt_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_cnt_cv   = PTHREAD_COND_INITIALIZER;
static int g_active = 0;

/* ================= Hàm tiện ích ================= */

// Tạo PID File giúp script demo dễ dàng tìm PID để gửi tín hiệu dừng
void create_pid_file(void) {
    FILE* fp = fopen(PID_FILE, "w");
    if (fp) {
        fprintf(fp, "%d\n", getpid());
        fclose(fp);
    }
}

// Đảm bảo đọc đủ n bytes từ socket (xử lý trường hợp read() trả về ít hơn yêu cầu)
static int recv_all(int fd, void* buf, size_t n) {
    char* p = (char*)buf;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return -1; // Client đóng kết nối sớm
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

// Hàm gửi phản hồi chuẩn hóa tới Client
static void send_reply(int fd, reply_t* reply, status_t st, uint32_t bytes,
                       const char* fmt, ...) __attribute__((format(printf, 5, 6)));
static void send_reply(int fd, reply_t* reply, status_t st, uint32_t bytes,
                       const char* fmt, ...) {
    va_list ap;
    reply->status = st;
    reply->bytes_written = bytes;
    va_start(ap, fmt);
    vsnprintf(reply->message, MAX_REPLY_LEN, fmt, ap);
    va_end(ap);
    ssize_t w = write(fd, reply, sizeof(reply_t));
    (void)w;
}

/* ================= Thread xử lý Client ================= */

typedef struct {
    int client_fd;
} thread_arg_t;

void* client_handler(void* arg) {
    thread_arg_t* targ = (thread_arg_t*)arg;
    int client_fd = targ->client_fd;
    free(targ);
    pthread_detach(pthread_self());

    // Thiết lập timeout 5 giây cho thao tác đọc/ghi để giải phóng thread nếu Client ngắt kết nối không sạch
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    msg_header_t header;
    reply_t reply;
    char* buffer = NULL;
    memset(&reply, 0, sizeof(reply));
    reply.magic = PROTO_MAGIC;

    // 1. Đọc Header của gói tin
    if (recv_all(client_fd, &header, sizeof(msg_header_t)) < 0) {
        send_reply(client_fd, &reply, STATUS_ERR_PROTO, 0, "Loi: Header khong hop le.");
        goto done;
    }

    // 2. Kiểm tra Magic Number
    if (header.magic != PROTO_MAGIC) {
        send_reply(client_fd, &reply, STATUS_ERR_PROTO, 0, "Loi: Sai Magic Number.");
        goto done;
    }

    // Chuẩn hóa tên file (chống lỗi kết thúc chuỗi và ký tự điều khiển)
    header.filename[MAX_NAME_LEN - 1] = '\0';
    for (char* p = header.filename; *p; p++) {
        if ((unsigned char)*p < 0x20) *p = '?';
    }

    // 3. Xử lý nghiệp vụ theo loại gói tin
    if (header.type == MSG_PING) {
        send_reply(client_fd, &reply, STATUS_OK, 0, "Server PONG: Active");
    }
    else if (header.type == MSG_SEND_FILE) {
        if (header.data_len > MAX_FILE_SIZE) {
            send_reply(client_fd, &reply, STATUS_ERR_TOO_BIG, 0, "Loi: File vuot qua 10MB.");
            goto done;
        }

        buffer = malloc((size_t)header.data_len + 1);
        if (!buffer) {
            send_reply(client_fd, &reply, STATUS_ERR_BUSY, 0, "Loi: Khong cap phat duoc bo nho.");
            goto done;
        }

        if (recv_all(client_fd, buffer, header.data_len) < 0) {
            send_reply(client_fd, &reply, STATUS_ERR_IO, 0, "Loi: Nhan thieu du lieu.");
            goto done;
        }
        buffer[header.data_len] = '\0';

        // Validate processing mode and verify data integrity (checksum)
        if (header.mode >= PROC_COUNT) {
            send_reply(client_fd, &reply, STATUS_ERR_PROTO, 0, "Error: unknown processing mode %u.", header.mode);
            goto done;
        }
        uint32_t calc = fnv1a32(buffer, header.data_len);
        if (calc != header.checksum) {
            syslog(LOG_WARNING, "Checksum mismatch for '%s': got 0x%08x, expected 0x%08x",
                   header.filename, calc, header.checksum);
            send_reply(client_fd, &reply, STATUS_ERR_CHECKSUM, 0,
                       "Error: checksum mismatch (client 0x%08x, server 0x%08x). Data rejected.",
                       header.checksum, calc);
            goto done;
        }

        // Ghi nhật ký vào hệ thống via Syslog (thay cho stdout)
        syslog(LOG_INFO, "Received '%s' (%u bytes, mode=%s) from client PID %u",
               header.filename, header.data_len, proc_mode_name(header.mode), header.client_pid);

        char summary[160];
        if (process_and_store(header.client_pid, header.filename, header.mode, header.checksum,
                              buffer, header.data_len, summary, sizeof(summary)) < 0) {
            send_reply(client_fd, &reply, STATUS_ERR_IO, 0, "Error: could not write output file.");
            goto done;
        }

        send_reply(client_fd, &reply, STATUS_OK, header.data_len,
                   "Processed '%.40s' (%u bytes) -> %s", header.filename, header.data_len, summary);
    }
    else {
        send_reply(client_fd, &reply, STATUS_ERR_PROTO, 0, "Loi: Loai tin nhan khong ho tro.");
    }

done:
    // Giải phóng tài nguyên, đóng socket và cập nhật số luồng active
    free(buffer);
    close(client_fd);
    
    pthread_mutex_lock(&g_cnt_lock);
    g_active--;
    pthread_cond_broadcast(&g_cnt_cv);
    pthread_mutex_unlock(&g_cnt_lock);
    return NULL;
}

/* ================= Daemon hóa ================= */

static int daemonize(void) {
    int pfd[2];
    if (pipe(pfd) < 0) return -1;

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid > 0) {
        // Tiến trình cha chờ nhận kết quả khởi tạo từ Daemon
        char buf[256];
        close(pfd[1]);
        ssize_t n = read(pfd[0], buf, sizeof(buf) - 1);
        if (n <= 0) { 
            fprintf(stderr, "Daemon khoi dong that bai\n"); 
            _exit(1); 
        }
        buf[n] = '\0';
        if (strncmp(buf, "OK", 2) == 0) { 
            fputs(buf, stdout); 
            exit(0); 
        }
        fputs(buf, stderr);
        exit(1);
    }

    close(pfd[0]);
    if (setsid() < 0) _exit(1);

    pid = fork(); // Fork lần 2 để ngăn tiến trình chiếm lại Terminal
    if (pid < 0) _exit(1);
    if (pid > 0) _exit(0);

    umask(022);
    if (chdir("/") < 0) _exit(1);

    // Chuyển hướng các luồng chuẩn (stdin, stdout, stderr) sang /dev/null
    int fd = open("/dev/null", O_RDWR);
    if (fd >= 0) {
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO) close(fd);
    }
    return pfd[1];
}

static void notify_parent(int ready_fd, int ok, const char* detail) {
    char msg[300];
    if (ready_fd < 0) return;
    if (ok) {
        snprintf(msg, sizeof(msg), "OK Server daemon da chay, PID=%d, socket=%s\n",
                 (int)getpid(), SOCKET_PATH);
    } else {
        snprintf(msg, sizeof(msg), "ERR %s\n", detail);
    }
    ssize_t w = write(ready_fd, msg, strlen(msg));
    (void)w;
    close(ready_fd);
}

/* ================= Xử lý Signal ================= */

static void on_signal(int signo) {
    (void)signo;
    g_stop = 1; // Đánh dấu cờ dừng an toàn trong signal handler
}

static void setup_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);

    // Bỏ qua SIGPIPE để tránh crash server khi ghi vào socket đã bị ngắt phía Client
    signal(SIGPIPE, SIG_IGN);
}

/* ================= Khởi tạo Socket ================= */

static int create_listen_socket(void) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    // Kiểm tra xem đã có Server nào đang chạy tại đường dẫn này chưa
    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe >= 0) {
        if (connect(probe, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
            close(probe);
            errno = EADDRINUSE;
            return -1;
        }
        close(probe);
    }
    unlink(SOCKET_PATH); // Xóa file socket rác còn sót lại

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0 ||
        chmod(SOCKET_PATH, 0666) < 0 ||
        listen(fd, 64) < 0) {
        int e = errno;
        close(fd);
        unlink(SOCKET_PATH);
        errno = e;
        return -1;
    }
    return fd;
}

/* ================= Main Function ================= */

int main(int argc, char** argv) {
    // Truyền tham số -f khi chạy lệnh để debug foreground, mặc định chạy Daemon ngầm
    int foreground = 0;
    int ready_fd = -1;
    const char* out_arg = DEFAULT_OUTPUT_FILE;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-f") == 0) foreground = 1;
        else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) out_arg = argv[++i];
        else { fprintf(stderr, "Usage: %s [-f] [-o output_file]\n", argv[0]); return 2; }
    }

    // Daemon se chdir("/") nen phai doi duong dan output sang tuyet doi TRUOC khi daemonize
    char out_abs[PATH_MAX];
    if (out_arg[0] == '/') {
        snprintf(out_abs, sizeof(out_abs), "%s", out_arg);
    } else {
        char cwd[PATH_MAX - 256];
        if (!getcwd(cwd, sizeof(cwd))) { perror("getcwd"); return 1; }
        snprintf(out_abs, sizeof(out_abs), "%s/%s", cwd, out_arg);
    }
    utils_set_output_path(out_abs);

    if (!foreground) {
        ready_fd = daemonize();
        if (ready_fd < 0) { 
            perror("daemonize failed"); 
            exit(EXIT_FAILURE); 
        }
    }

    openlog("ipc_server", LOG_PID | (foreground ? LOG_PERROR : 0), LOG_DAEMON);
    setup_signals();

    // Khởi tạo UNIX Domain Socket
    int server_fd = create_listen_socket();
    if (server_fd < 0) {
        syslog(LOG_ERR, "Khong tao duoc socket %s: %s", SOCKET_PATH, strerror(errno));
        notify_parent(ready_fd, 0, errno == EADDRINUSE ? "Da co server khac dang chay"
                                                       : "Khong tao duoc UNIX socket");
        exit(EXIT_FAILURE);
    }

    create_pid_file();
    syslog(LOG_INFO, "Socket Daemon running at %s (PID: %d), output=%s", SOCKET_PATH, getpid(), out_abs);
    write_system_log("Server started");
    notify_parent(ready_fd, 1, NULL);
    
    if (foreground) {
        printf("[SERVER] Dang chay foreground (PID %d), output=%s. Nhan Ctrl+C de dung.\n", getpid(), out_abs);
    }

    // Vòng lặp chính chấp nhận kết nối và tạo Luồng
    struct pollfd pfd = { .fd = server_fd, .events = POLLIN };
    while (!g_stop) {
        int pr = poll(&pfd, 1, 500); // Thức dậy mỗi 500ms để kiểm tra cờ g_stop
        if (pr < 0) { 
            if (errno == EINTR) continue; 
            break; 
        }
        if (pr == 0) continue;

        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EMFILE || errno == ENFILE) sleep(1);
            continue;
        }

        thread_arg_t* targ = malloc(sizeof(thread_arg_t));
        if (!targ) { 
            close(client_fd); 
            continue; 
        }
        targ->client_fd = client_fd;

        pthread_mutex_lock(&g_cnt_lock);
        g_active++;
        pthread_mutex_unlock(&g_cnt_lock);

        pthread_t thread_id;
        if (pthread_create(&thread_id, NULL, client_handler, (void*)targ) != 0) {
            syslog(LOG_ERR, "Pthread create failed");
            close(client_fd);
            free(targ);
            
            pthread_mutex_lock(&g_cnt_lock);
            g_active--;
            pthread_mutex_unlock(&g_cnt_lock);
        }
    }

    // Trình tự Graceful Shutdown khi nhận được tín hiệu dừng
    syslog(LOG_INFO, "Nhan tin hieu dung - Dang thuc hien tat an toan...");
    close(server_fd);
    unlink(SOCKET_PATH);

    // Đợi tất cả các luồng đang xử lý hoàn tất (tối đa 30s)
    struct timespec dl;
    clock_gettime(CLOCK_REALTIME, &dl);
    dl.tv_sec += 30;
    
    pthread_mutex_lock(&g_cnt_lock);
    while (g_active > 0) {
        if (pthread_cond_timedwait(&g_cnt_cv, &g_cnt_lock, &dl) == ETIMEDOUT) break;
    }
    pthread_mutex_unlock(&g_cnt_lock);

    write_system_log("Shutdown gracefully");

    unlink(PID_FILE);
    syslog(LOG_INFO, "Server da dung an toan.");
    closelog();
    return 0;
}
