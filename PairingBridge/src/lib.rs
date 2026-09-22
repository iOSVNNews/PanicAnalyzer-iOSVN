use std::alloc::{dealloc, Layout};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::net::Ipv4Addr;
use std::ptr::null_mut;

use idevice_ffi::core_device_proxy::{adapter_free, AdapterHandle};
use idevice_ffi::crashreportcopymobile::{
    crash_report_client_connect_rsd, crash_report_client_free, crash_report_client_ls,
    CrashReportCopyMobileHandle,
};
use idevice_ffi::rp_pairing_file::{
    rp_pairing_file_free, rp_pairing_file_generate, rp_pairing_file_read,
    rp_pairing_file_write, RpPairingFileHandle,
};
use idevice_ffi::rsd::{rsd_handshake_free, RsdHandshakeHandle};
use idevice_ffi::tunnel_provider::tunnel_create_rppairing;
use idevice_ffi::util::idevice_sockaddr;
use idevice_ffi::{idevice_data_free, idevice_error_free, IdeviceFfiError};

/// Owns the complete read-only crash-report connection. Swift serializes use.
#[repr(C)]
pub struct PaLogSession {
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    client: *mut CrashReportCopyMobileHandle,
}
fn owned_message(message: impl AsRef<str>) -> *mut c_char {
    let cleaned = message.as_ref().replace('\0', " ");
    CString::new(cleaned)
        .unwrap_or_else(|_| CString::new("Unknown pairing error").unwrap())
        .into_raw()
}

unsafe fn consume_idevice_error(
    error: *mut IdeviceFfiError,
    context: &str,
) -> *mut c_char {
    if error.is_null() {
        return null_mut();
    }
    let detail = if (*error).message.is_null() {
        "unknown error".to_string()
    } else {
        CStr::from_ptr((*error).message).to_string_lossy().into_owned()
    };
    let text = format!(
        "{context} (code={}, sub={}): {detail}",
        (*error).code,
        (*error).sub_code
    );
    idevice_error_free(error);
    owned_message(text)
}

unsafe fn c_string<'a>(value: *const c_char, name: &str) -> Result<&'a CStr, *mut c_char> {
    if value.is_null() {
        return Err(owned_message(format!("{name} is null")));
    }
    Ok(CStr::from_ptr(value))
}

unsafe fn close_parts(
    client: *mut CrashReportCopyMobileHandle,
    handshake: *mut RsdHandshakeHandle,
    adapter: *mut AdapterHandle,
) {
    if !client.is_null() {
        crash_report_client_free(client);
    }
    if !handshake.is_null() {
        rsd_handshake_free(handshake);
    }
    if !adapter.is_null() {
        adapter_free(adapter);
    }
}

#[no_mangle]
pub unsafe extern "C" fn pa_pairing_validate(pairing_path: *const c_char) -> *mut c_char {
    if let Err(error) = c_string(pairing_path, "pairing_path") {
        return error;
    }
    let mut pairing: *mut RpPairingFileHandle = null_mut();
    let error = rp_pairing_file_read(pairing_path, &mut pairing);
    if !error.is_null() {
        return consume_idevice_error(error, "Remote Pairing file không hợp lệ");
    }
    rp_pairing_file_free(pairing);
    null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn pa_session_connect(
    pairing_path: *const c_char,
    device_ip: *const c_char,
    rsd_port: u16,
    out_session: *mut *mut PaLogSession,
) -> *mut c_char {
    if out_session.is_null() {
        return owned_message("out_session is null");
    }
    *out_session = null_mut();
    if let Err(error) = c_string(pairing_path, "pairing_path") {
        return error;
    }
    let ip = match c_string(device_ip, "device_ip").and_then(|s| {
        s.to_str().ok().and_then(|s| s.parse::<Ipv4Addr>().ok())
            .ok_or_else(|| owned_message("Địa chỉ VPN không hợp lệ"))
    }) {
        Ok(ip) => ip,
        Err(error) => return error,
    };

    let mut address: libc::sockaddr_in = std::mem::zeroed();
    address.sin_family = libc::AF_INET as libc::sa_family_t;
    address.sin_port = rsd_port.to_be();
    #[cfg(target_vendor = "apple")]
    {
        address.sin_len = std::mem::size_of::<libc::sockaddr_in>() as u8;
    }
    // sockaddr stores network bytes in native memory; no platform-specific
    // inet_pton symbol is required (libc does not expose it for this iOS target).
    address.sin_addr.s_addr = u32::from_ne_bytes(ip.octets());

    let hostname = CString::new("PanicAnalyzer").unwrap();
    let mut pairing: *mut RpPairingFileHandle = null_mut();
    let read_error = rp_pairing_file_read(pairing_path, &mut pairing);
    if !read_error.is_null() {
        // No usable record yet: create the keys locally. iOS completes the
        // first pair-setup over LocalDevVPN and asks the user for consent.
        idevice_error_free(read_error);
        let generate_error = rp_pairing_file_generate(hostname.as_ptr(), &mut pairing);
        if !generate_error.is_null() {
            return consume_idevice_error(
                generate_error,
                "Không tạo được Remote Pairing record trên thiết bị",
            );
        }
    }
    let mut adapter: *mut AdapterHandle = null_mut();
    let mut handshake: *mut RsdHandshakeHandle = null_mut();
    let tunnel_error = tunnel_create_rppairing(
        &address as *const libc::sockaddr_in as *const idevice_sockaddr,
        std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
        hostname.as_ptr(),
        pairing,
        None,
        null_mut(),
        &mut adapter,
        &mut handshake,
    );
    if !tunnel_error.is_null() {
        rp_pairing_file_free(pairing);
        close_parts(null_mut(), handshake, adapter);
        return consume_idevice_error(
            tunnel_error,
            "Không mở được RSD tunnel; hãy bật LocalDevVPN rồi thử lại",
        );
    }

    // tunnel_create_rppairing updates new or stale credentials after iOS has
    // approved them. Persist only after the complete pairing+tunnel succeeds.
    let write_error = rp_pairing_file_write(pairing, pairing_path);
    rp_pairing_file_free(pairing);
    if !write_error.is_null() {
        close_parts(null_mut(), handshake, adapter);
        return consume_idevice_error(
            write_error,
            "Đã ghép đôi nhưng không lưu được pairing record",
        );
    }

    let mut client: *mut CrashReportCopyMobileHandle = null_mut();
    let client_error = crash_report_client_connect_rsd(adapter, handshake, &mut client);
    if !client_error.is_null() {
        close_parts(client, handshake, adapter);
        return consume_idevice_error(
            client_error,
            "Không kết nối được dịch vụ crashreportcopymobile",
        );
    }

    *out_session = Box::into_raw(Box::new(PaLogSession {
        adapter,
        handshake,
        client,
    }));
    null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn pa_session_list(
    session: *mut PaLogSession,
    directory: *const c_char,
    out_entries: *mut *mut *mut c_char,
    out_count: *mut usize,
) -> *mut c_char {
    if session.is_null() || out_entries.is_null() || out_count.is_null() {
        return owned_message("Tham số liệt kê log không hợp lệ");
    }
    *out_entries = null_mut();
    *out_count = 0;
    let error = crash_report_client_ls((*session).client, directory, out_entries, out_count);
    consume_idevice_error(error, "Không liệt kê được thư mục CrashReporter")
}

#[no_mangle]
pub unsafe extern "C" fn pa_session_pull(
    session: *mut PaLogSession,
    relative_path: *const c_char,
    out_data: *mut *mut u8,
    out_length: *mut usize,
) -> *mut c_char {
    if session.is_null()
        || relative_path.is_null()
        || out_data.is_null()
        || out_length.is_null()
    {
        return owned_message("Tham số tải log không hợp lệ");
    }
    *out_data = null_mut();
    *out_length = 0;
    let path = match CStr::from_ptr(relative_path).to_str() {
        Ok(path) if valid_log_path(path) => path.to_string(),
        _ => return owned_message("Đường dẫn crash report không hợp lệ"),
    };
    let result = idevice_ffi::run_sync_local(async {
        tokio::time::timeout(std::time::Duration::from_secs(15), async {
            let afc = &mut (*(*session).client).0.afc_client;
            let path = format!("/{path}");
            let info = afc.get_file_info_raw(&path).await.map_err(|e| e.to_string())?;
            let size = info.get("st_size").and_then(|s| s.parse::<usize>().ok())
                .ok_or("Không xác định được kích thước log")?;
            if info.get("st_ifmt").map(String::as_str) != Some("S_IFREG") || size > MAX_FILE_BYTES {
                return Err("Bỏ qua log quá 12 MB hoặc không phải tệp thường".to_string());
            }
            let mut file = afc.open(path, idevice::afc::opcode::AfcFopenMode::RdOnly)
                .await.map_err(|e| e.to_string())?;
            let bytes = file.read_n(size).await;
            let close = file.close().await;
            let bytes = bytes.map_err(|e| e.to_string())?;
            close.map_err(|e| e.to_string())?;
            if bytes.len() != size { return Err("Log thay đổi trong lúc đọc; hãy quét lại".into()); }
            Ok(bytes)
        }).await.map_err(|_| "Đọc log quá thời gian; hãy kiểm tra VPN".to_string())?
    });
    match result {
        Ok(bytes) => {
            let mut bytes = bytes.into_boxed_slice();
            *out_length = bytes.len();
            *out_data = bytes.as_mut_ptr();
            std::mem::forget(bytes);
            null_mut()
        }
        Err(error) => owned_message(error),
    }
}

const MAX_FILE_BYTES: usize = 12 * 1024 * 1024;

fn valid_log_path(path: &str) -> bool {
    !path.is_empty() && !path.starts_with('/') && !path.contains('\\')
        && path.split('/').all(|part| !part.is_empty() && part != "." && part != "..")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_address_has_correct_byte_order() {
        let ip: Ipv4Addr = "10.7.0.1".parse().unwrap();
        assert_eq!(u32::from_ne_bytes(ip.octets()).to_ne_bytes(), [10, 7, 0, 1]);
        assert!("10.7.0.999".parse::<Ipv4Addr>().is_err());
    }

    #[test]
    fn log_paths_stay_inside_crashreporter() {
        assert!(valid_log_path("Retired/panic-full-example.ips"));
        for path in ["", "/var/log/x", "../x", "a/../x", "a//x", "a\\x", "./x"] {
            assert!(!valid_log_path(path), "{path}");
        }
    }

    #[test]
    fn ffi_rejects_null_parameters_without_dereferencing() {
        unsafe {
            let error = pa_pairing_validate(null_mut());
            assert!(!error.is_null());
            pa_error_free(error);
            let error = pa_session_pull(null_mut(), null_mut(), null_mut(), null_mut());
            assert!(!error.is_null());
            pa_error_free(error);
            pa_session_free(null_mut());
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn pa_session_free(session: *mut PaLogSession) {
    if session.is_null() {
        return;
    }
    let session = Box::from_raw(session);
    close_parts(session.client, session.handshake, session.adapter);
}

#[no_mangle]
pub unsafe extern "C" fn pa_string_array_free(entries: *mut *mut c_char, count: usize) {
    if entries.is_null() {
        return;
    }
    for index in 0..count {
        let value = *entries.add(index);
        if !value.is_null() {
            let _ = CString::from_raw(value);
        }
    }
    if let Ok(layout) = Layout::array::<*mut c_char>(count + 1) {
        dealloc(entries as *mut u8, layout);
    }
}

#[no_mangle]
pub unsafe extern "C" fn pa_bytes_free(data: *mut u8, length: usize) {
    idevice_data_free(data, length);
}

#[no_mangle]
pub unsafe extern "C" fn pa_error_free(message: *mut c_char) {
    if !message.is_null() {
        let _ = CString::from_raw(message);
    }
}
