use std::alloc::{dealloc, Layout};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr::{null, null_mut};

use idevice_ffi::core_device_proxy::{adapter_free, AdapterHandle};
use idevice_ffi::crashreportcopymobile::{
    crash_report_client_connect_rsd, crash_report_client_free, crash_report_client_ls,
    crash_report_client_pull, CrashReportCopyMobileHandle,
};
use idevice_ffi::rp_pairing_file::{
    rp_pairing_file_free, rp_pairing_file_read, RpPairingFileHandle,
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
        return consume_idevice_error(error, "Pairing file không hợp lệ");
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
    if let Err(error) = c_string(device_ip, "device_ip") {
        return error;
    }

    let mut pairing: *mut RpPairingFileHandle = null_mut();
    let read_error = rp_pairing_file_read(pairing_path, &mut pairing);
    if !read_error.is_null() {
        return consume_idevice_error(read_error, "Không đọc được Remote Pairing file");
    }

    let mut address: libc::sockaddr_in = std::mem::zeroed();
    address.sin_family = libc::AF_INET as libc::sa_family_t;
    address.sin_port = rsd_port.to_be();
    #[cfg(target_vendor = "apple")]
    {
        address.sin_len = std::mem::size_of::<libc::sockaddr_in>() as u8;
    }
    if libc::inet_pton(
        libc::AF_INET,
        device_ip,
        &mut address.sin_addr as *mut _ as *mut libc::c_void,
    ) != 1
    {
        rp_pairing_file_free(pairing);
        return owned_message("Địa chỉ LocalDevVPN không hợp lệ");
    }

    let hostname = CString::new("PanicAnalyzer").unwrap();
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
    rp_pairing_file_free(pairing);
    if !tunnel_error.is_null() {
        close_parts(null_mut(), handshake, adapter);
        return consume_idevice_error(
            tunnel_error,
            "Không mở được RSD tunnel; hãy bật LocalDevVPN rồi thử lại",
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
    let error = crash_report_client_pull((*session).client, relative_path, out_data, out_length);
    consume_idevice_error(error, "Không đọc được crash report")
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
