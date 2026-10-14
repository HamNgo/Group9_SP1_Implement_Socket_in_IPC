/**
 * Project: Topic 25 - Sockets in IPC
 * Class: SP(1).en2026 - Group 9 VKU
 * Author: Vo Thanh Long - 23IT147 (Team Leader)
 * File: common/protocol.h
 */

#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pthread.h>

#define STREAM_SOCKET_PATH "/tmp/ipc_group9_stream.sock"
#define DGRAM_SOCKET_PATH   "/tmp/ipc_group9_dgram.sock"
#define FD_SOCKET_PATH      "/tmp/ipc_group9_fd.sock"

#define MAX_CLIENTS 16
#define BUFFER_SIZE 512
#define USERNAME_LEN 32

// Định nghĩa các loại thông điệp IPC
typedef enum {
    CMD_JOIN = 1,          // Đăng ký tham gia hệ thống
    CMD_PUBLIC_CHAT,       // Chat nhóm (Broadcast)
    CMD_PRIVATE_CHAT,      // Chat riêng (@username)
    CMD_FILE_NOTIFY,       // Thông báo gửi tệp input.txt
    CMD_TASK_RESULT,       // Kết quả xử lý ghi ra output.txt
    CMD_LEAVE              // Thoát phiên làm việc
} MessageType;

// Cấu trúc gói tin chuẩn trao đổi qua UNIX Domain Socket
typedef struct {
    MessageType type;
    char sender[USERNAME_LEN];
    char receiver[USERNAME_LEN];
    char payload[BUFFER_SIZE];
    size_t data_len;
} MessagePacket;

// Quản lý thông tin Client đang hoạt động trên Server Daemon
typedef struct {
    int socket_fd;
    char username[USERNAME_LEN];
    pthread_t thread_id;
    int is_active;
} ClientNode;

#endif // PROTOCOL_H
