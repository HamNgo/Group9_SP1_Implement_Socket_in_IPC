#ifndef UTILS_H
#define UTILS_H
#include <stdint.h>
#include <stddef.h>

/* Output file path (should be absolute: the daemon does chdir("/")) */
void utils_set_output_path(const char *path);

/* FNV-1a 32-bit checksum, used to verify data integrity across the socket */
uint32_t fnv1a32(const void *data, size_t len);

const char *proc_mode_name(uint32_t mode);

/* Process the data according to `mode`, append a timestamped entry to the
 * output file, and put a one-line result into `summary`. Returns 0 / -1. */
int process_and_store(uint32_t client_pid, const char *filename, uint32_t mode,
                      uint32_t checksum, const char *data, uint32_t len,
                      char *summary, size_t summary_cap);

/* Append a timestamped [SYSTEM] line to the output file. */
int write_system_log(const char *msg);

/* Read a whole file into a malloc'd buffer. NULL on error. */
char *read_whole_file(const char *path, size_t *out_len);
#endif
