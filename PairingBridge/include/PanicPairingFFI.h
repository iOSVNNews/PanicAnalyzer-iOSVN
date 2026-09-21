#ifndef PANIC_PAIRING_FFI_H
#define PANIC_PAIRING_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct PaLogSession PaLogSession;

/*
 * Every function returns NULL on success or an owned UTF-8 error string.
 * Release errors with pa_error_free(). This API is intentionally read-only.
 */
char *pa_pairing_validate(const char *pairing_path);

char *pa_session_connect(
    const char *pairing_path,
    const char *device_ip,
    uint16_t rsd_port,
    PaLogSession **out_session
);

char *pa_session_list(
    PaLogSession *session,
    const char *directory,
    char ***out_entries,
    size_t *out_count
);

char *pa_session_pull(
    PaLogSession *session,
    const char *relative_path,
    uint8_t **out_data,
    size_t *out_length
);

void pa_session_free(PaLogSession *session);
void pa_string_array_free(char **entries, size_t count);
void pa_bytes_free(uint8_t *data, size_t length);
void pa_error_free(char *message);

#ifdef __cplusplus
}
#endif

#endif
