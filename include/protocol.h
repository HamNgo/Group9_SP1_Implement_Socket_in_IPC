/**
 * Project: Topic 25 - Sockets in IPC
 * Class: SP(1).en2026 - Group 9 VKU
 * File: include/protocol.h
 *
 * Client <-> Server protocol over a UNIX domain socket (SOCK_STREAM).
 *   Client sends : [msg_header_t][data_len bytes of file content]
 *   Server replies: [reply_t]
 */
#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

#define SOCKET_PATH   "/tmp/ipc_group9_stream.sock"
#define PID_FILE      "/tmp/ipc_group9_server.pid"
#define DEFAULT_OUTPUT_FILE "output.txt"

#define PROTO_MAGIC    0x49504339u          /* "IPC9" */
#define MAX_NAME_LEN   128
#define MAX_REPLY_LEN  256
#define MAX_FILE_SIZE  (10u * 1024u * 1024u) /* 10 MB */

typedef enum {
    MSG_PING = 1,
    MSG_SEND_FILE = 2
} msg_type_t;

/* What the server should do with the file (the "offloaded task") */
typedef enum {
    PROC_STATS = 0,     /* analyze only: lines, words, longest/top word */
    PROC_UPPER = 1,     /* analyze + convert text to UPPERCASE */
    PROC_REVERSE = 2,   /* analyze + reverse the order of lines */
    PROC_COUNT
} proc_mode_t;

typedef enum {
    STATUS_OK = 0,
    STATUS_ERR_PROTO,
    STATUS_ERR_TOO_BIG,
    STATUS_ERR_BUSY,
    STATUS_ERR_IO,
    STATUS_ERR_CHECKSUM
} status_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t type;                 /* msg_type_t */
    uint32_t client_pid;
    uint32_t data_len;             /* bytes of file content following the header */
    uint32_t mode;                 /* proc_mode_t */
    uint32_t checksum;             /* FNV-1a 32-bit of the content */
    char     filename[MAX_NAME_LEN];
} msg_header_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t status;               /* status_t */
    uint32_t bytes_written;
    char     message[MAX_REPLY_LEN];
} reply_t;

#endif /* PROTOCOL_H */
