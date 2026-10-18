 /*

 * protocol.h - Giao thuc chung giua Client va Server (UNIX Domain Socket).

 * Moi yeu cau gom:  [msg_header_t] + [data_len byte du lieu]

 * Server tra loi:   [reply_t]

 */

#ifndef PROTOCOL_H

#define PROTOCOL_H


#include <stdint.h>


#define SOCKET_PATH     "/tmp/ipc_server.sock"   /* duong dan UNIX socket */

#define PID_FILE        "/tmp/ipc_server.pid"    /* de script demo tim PID */


#define PROTO_MAGIC     0x49504331u              /* "IPC1" - nhan dien goi tin */

#define MAX_NAME_LEN    128                      /* do dai toi da ten file */

#define MAX_FILE_SIZE   (10u * 1024u * 1024u)    /* gioi han 10 MB / file */

#define MAX_REPLY_LEN   160


typedef enum {

    MSG_SEND_FILE = 1,   /* gui noi dung file de server xu ly + ghi output */

    MSG_PING      = 2    /* kiem tra server con song */

} msg_type_t;


typedef enum {

    STATUS_OK          = 0,

    STATUS_ERR_PROTO   = 1,   /* goi tin sai dinh dang */

    STATUS_ERR_TOO_BIG = 2,   /* file vuot MAX_FILE_SIZE */

    STATUS_ERR_IO      = 3,   /* loi doc/ghi file o server */

    STATUS_ERR_BUSY    = 4    /* server khong cap duoc thread / bo nho */

} status_t;


/* Tieu de goi tin Client -> Server */

typedef struct __attribute__((packed)) {

    uint32_t magic;                   /* PROTO_MAGIC */

    uint32_t type;                    /* msg_type_t */

    int32_t  client_pid;              /* PID cua client (de ghi log) */

    uint32_t data_len;                /* so byte du lieu theo sau header */

    char     filename[MAX_NAME_LEN];  /* ten file goc (chi de hien thi) */

} msg_header_t;


/* Phan hoi Server -> Client */

typedef struct __attribute__((packed)) {

    uint32_t magic;

    uint32_t status;                  /* status_t */

    uint32_t bytes_written;           /* so byte du lieu da xu ly */

    char     message[MAX_REPLY_LEN];  /* thong bao doc duoc */

} reply_t;


#endif /* PROTOCOL_H */ 
