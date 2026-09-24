#ifndef PANIC_PAIRING_FFI_H
#define PANIC_PAIRING_FFI_H

#include <stdbool.h>
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

/*
 * CoreDeviceProxy route: a classic lockdown pair record (from a computer, or
 * minted on-device with pa_lockdown_mint on 62078) opens the RSD tunnel
 * through LocalDevVPN without the RPPairing tunnel listener.
 */
char *pa_lockdown_validate(const char *record_path);

char *pa_lockdown_mint(
    const char *device_ip,
    const char *host_id,
    const char *system_buid,
    const char *out_path
);

char *pa_session_connect_lockdown(
    const char *record_path,
    const char *device_ip,
    PaLogSession **out_session
);

/*
 * Direct route: lockdown session on 62078, then StartService
 * com.apple.crashreportcopymobile (no tunnel, no RSD). Same record as above.
 */
char *pa_session_connect_lockdown_direct(
    const char *record_path,
    const char *device_ip,
    PaLogSession **out_session
);

/*
 * Every network step has a deadline. After a timeout or socket error the
 * session is marked broken and later list/pull calls fail at once.
 */
bool pa_session_is_broken(const PaLogSession *session);

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

/*
 * iOS 27 device-initiated pairing. Publish `_remotepairing-pairable-host._tcp`
 * with the returned service id and TXT plist (XML dictionary), accept the TCP
 * connection iOS opens, then call pa_host_accept on that socket. The PIN
 * callback receives the 6-digit code the user types in Settings.
 */
typedef struct PaPairingHost PaPairingHost;
typedef void (*pa_pin_callback)(const char *pin, void *context);

char *pa_host_prepare(
    const char *name,
    PaPairingHost **out_host,
    char **out_service_id,
    uint8_t **out_txt_plist,
    size_t *out_txt_length
);

char *pa_host_accept(
    PaPairingHost *host,
    int32_t socket_fd,
    pa_pin_callback pin_callback,
    void *pin_context,
    const char *pairing_path
);

void pa_host_free(PaPairingHost *host);

void pa_session_free(PaLogSession *session);
void pa_string_array_free(char **entries, size_t count);
void pa_bytes_free(uint8_t *data, size_t length);
void pa_error_free(char *message);

#ifdef __cplusplus
}
#endif

#endif
