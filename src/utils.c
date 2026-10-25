#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include "protocol.h"
#include "utils.h"

/* NOTE: no mutex yet (planned for the multi-client stage). Each entry is built
 * in memory and written with ONE write() on an O_APPEND descriptor, so the
 * kernel appends it at the end of the file in a single step. */
static char g_out_path[PATH_MAX] = DEFAULT_OUTPUT_FILE;

void utils_set_output_path(const char *path) {
    snprintf(g_out_path, sizeof(g_out_path), "%s", path);
}

uint32_t fnv1a32(const void *data, size_t len) {
    const unsigned char *p = data;
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < len; i++) { h ^= p[i]; h *= 16777619u; }
    return h;
}

const char *proc_mode_name(uint32_t mode) {
    switch (mode) {
        case PROC_STATS:   return "STATS";
        case PROC_UPPER:   return "UPPERCASE";
        case PROC_REVERSE: return "REVERSE-LINES";
        default:           return "UNKNOWN";
    }
}

static void timestamp(char *buf, size_t n) {
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(buf, n, "%Y-%m-%d %H:%M:%S", &tmv);
}

static int append_to_output(const char *buf, size_t n) {
    int fd = open(g_out_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return -1;
    ssize_t w = write(fd, buf, n);
    int rc = (w == (ssize_t)n) ? 0 : -1;
    close(fd);
    return rc;
}

/* ---------- text analysis ---------- */

#define WORD_MAX   64
#define TABLE_SIZE 1024

typedef struct { unsigned lines, words, longest_len, top_count;
                 char longest[WORD_MAX], top[WORD_MAX]; } stats_t;
typedef struct { char w[WORD_MAX]; unsigned n; } entry_t;

static int is_word_char(unsigned char c) {
    return isalnum(c) || c == '\'' || c >= 0x80;   /* >=0x80: UTF-8 bytes */
}

static void end_word(stats_t *st, entry_t *tab, unsigned *used,
                     char *cur, size_t full_len) {
    if (full_len == 0) return;
    st->words++;
    if (full_len > st->longest_len) {
        st->longest_len = (unsigned)full_len;
        snprintf(st->longest, sizeof(st->longest), "%s", cur);
    }
    unsigned i;
    for (i = 0; i < *used; i++)
        if (strcmp(tab[i].w, cur) == 0) break;
    if (i == *used) {
        if (*used >= TABLE_SIZE) return;           /* table full: ignore new words */
        snprintf(tab[i].w, WORD_MAX, "%s", cur);
        tab[i].n = 0;
        (*used)++;
    }
    if (++tab[i].n > st->top_count) {
        st->top_count = tab[i].n;
        snprintf(st->top, sizeof(st->top), "%s", tab[i].w);
    }
}

static void analyze(const char *d, uint32_t len, stats_t *st) {
    memset(st, 0, sizeof(*st));
    entry_t *tab = calloc(TABLE_SIZE, sizeof(entry_t));
    unsigned used = 0;
    char cur[WORD_MAX];
    size_t cl = 0, full = 0;

    for (uint32_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)d[i];
        if (c == '\n') st->lines++;
        if (is_word_char(c)) {
            if (cl < WORD_MAX - 1) cur[cl++] = (char)tolower(c);
            full++;
        } else if (full) {
            cur[cl] = '\0';
            if (tab) end_word(st, tab, &used, cur, full);
            cl = 0; full = 0;
        }
    }
    if (full) { cur[cl] = '\0'; if (tab) end_word(st, tab, &used, cur, full); }
    if (len > 0 && d[len - 1] != '\n') st->lines++;
    free(tab);
}

/* ---------- transforms ---------- */

static char *transform(uint32_t mode, const char *d, uint32_t len, size_t *out_len) {
    char *out = malloc((size_t)len + 2);
    if (!out) return NULL;
    size_t pos = 0;

    if (mode == PROC_UPPER) {
        for (uint32_t i = 0; i < len; i++) out[i] = (char)toupper((unsigned char)d[i]);
        pos = len;
    } else if (mode == PROC_REVERSE) {
        size_t end = len;
        while (end > 0) {
            size_t e = end;
            if (d[e - 1] == '\n') e--;
            size_t s = e;
            while (s > 0 && d[s - 1] != '\n') s--;
            memcpy(out + pos, d + s, e - s);
            pos += e - s;
            out[pos++] = '\n';
            end = s;
        }
    } else {
        memcpy(out, d, len);
        pos = len;
    }
    out[pos] = '\0';
    *out_len = pos;
    return out;
}

/* ---------- public API ---------- */

int process_and_store(uint32_t client_pid, const char *filename, uint32_t mode,
                      uint32_t checksum, const char *data, uint32_t len,
                      char *summary, size_t summary_cap) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    stats_t st;
    analyze(data, len, &st);
    size_t out_len = 0;
    char *out = transform(mode, data, len, &out_len);
    if (!out) return -1;

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;

    snprintf(summary, summary_cap,
             "mode=%s lines=%u words=%u longest=\"%.24s\" top=\"%.24s\"(x%u)",
             proc_mode_name(mode), st.lines, st.words, st.longest, st.top, st.top_count);

    char ts[32];
    timestamp(ts, sizeof(ts));

    size_t cap = out_len + 1024 + MAX_NAME_LEN;
    char *buf = malloc(cap);
    if (!buf) { free(out); return -1; }

    int n = snprintf(buf, cap,
        "============================================================\n"
        "[%s] Request from client PID=%u\n"
        "  File      : %s\n"
        "  Mode      : %s\n"
        "  Size      : %u bytes\n"
        "  Checksum  : 0x%08x (verified)\n"
        "  Result    : lines=%u words=%u longest=\"%s\" top=\"%s\"(x%u)\n"
        "  Proc time : %.3f ms\n"
        "--- processed content ---\n",
        ts, client_pid, filename, proc_mode_name(mode), len, checksum,
        st.lines, st.words, st.longest, st.top, st.top_count, ms);
    if (n < 0 || (size_t)n >= cap) { free(out); free(buf); return -1; }

    size_t pos = (size_t)n;
    memcpy(buf + pos, out, out_len);
    pos += out_len;
    if (out_len > 0 && out[out_len - 1] != '\n') buf[pos++] = '\n';
    const char *tail = "--- end ---\n\n";
    size_t tl = strlen(tail);
    if (pos + tl > cap) { free(out); free(buf); return -1; }
    memcpy(buf + pos, tail, tl);
    pos += tl;

    int rc = append_to_output(buf, pos);
    free(out);
    free(buf);
    return rc;
}

int write_system_log(const char *msg) {
    char ts[32], line[512];
    timestamp(ts, sizeof(ts));
    int n = snprintf(line, sizeof(line), "[%s] [SYSTEM] %s\n", ts, msg);
    if (n < 0) return -1;
    if ((size_t)n >= sizeof(line)) n = sizeof(line) - 1;
    return append_to_output(line, (size_t)n);
}

char *read_whole_file(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (!buf) { fclose(fp); return NULL; }
    size_t r;
    while ((r = fread(buf + len, 1, cap - len, fp)) > 0) {
        len += r;
        if (len == cap) {
            cap *= 2;
            char *nb = realloc(buf, cap);
            if (!nb) { free(buf); fclose(fp); return NULL; }
            buf = nb;
        }
    }
    if (ferror(fp)) { free(buf); fclose(fp); return NULL; }
    fclose(fp);
    *out_len = len;
    return buf;
}
