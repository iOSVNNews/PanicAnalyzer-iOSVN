use std::alloc::{dealloc, Layout};
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};
use std::net::Ipv4Addr;
use std::ptr::null_mut;

use idevice_ffi::core_device_proxy::{adapter_free, AdapterHandle};
use idevice_ffi::crashreportcopymobile::{
    crash_report_client_connect_rsd, crash_report_client_free, crash_report_client_ls,
    CrashReportCopyMobileHandle,
};
use idevice_ffi::rp_pairing_file::{
    rp_pairing_file_free, rp_pairing_file_read, rp_pairing_file_write, RpPairingFileHandle,
};
use idevice_ffi::rsd::{rsd_handshake_free, RsdHandshakeHandle};
use idevice_ffi::tunnel_provider::tunnel_create_rppairing;
use idevice_ffi::util::idevice_sockaddr;
use idevice_ffi::pairing_host::{
    pairable_host_accept_fd, pairable_host_free, pairable_host_prepare, PairableHostHandle,
};
use idevice_ffi::{idevice_data_free, idevice_error_free, idevice_string_free, IdeviceFfiError};

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
        // iOS 27 pairs device-initiated (Settings > Privacy & Security >
        // Developer) through pa_host_*; never start a host-initiated
        // pair-setup the iPhone would reject.
        return consume_idevice_error(
            read_error,
            "Chưa có pairing record. Bấm Ghép đôi thiết bị này rồi chọn PanicAnalyzer trong Cài đặt > Quyền riêng tư & Bảo mật > Nhà phát triển",
        );
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
            "Không hoàn tất ghép đôi hoặc mở RSD tunnel. Kiểm tra LocalDevVPN còn kết nối, mở khóa iPhone và chấp nhận yêu cầu ghép đôi. Có thể nhập Remote Pairing file trong Cấu hình LocalDevVPN",
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

    open_crash_reports(adapter, handshake, out_session)
}

/// Opens CrashReportCopyMobile over an RSD tunnel and hands ownership of all
/// three handles to a new session.
unsafe fn open_crash_reports(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    out_session: *mut *mut PaLogSession,
) -> *mut c_char {
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

// MARK: - CoreDeviceProxy route (classic lockdown pair record)
//
// On-device, the RPPairing tunnel can fail after pair-verify: the tunnel
// listener iOS opens binds to Wi-Fi only and the device closes a tunnel to
// itself (close_notify). CoreDeviceProxy needs no inbound listener: it rides a
// lockdown session on 62078 through LocalDevVPN (the StikDebug recipe). Its
// classic pair record comes from an imported pairing file or is minted here.

const LOCKDOWN_PORT: u16 = 62078;

fn parse_ipv4(value: *const c_char) -> Result<Ipv4Addr, *mut c_char> {
    unsafe { c_string(value, "device_ip") }.and_then(|s| {
        s.to_str().ok().and_then(|s| s.parse::<Ipv4Addr>().ok())
            .ok_or_else(|| owned_message("Địa chỉ VPN không hợp lệ"))
    })
}

fn read_lockdown_record(path: *const c_char) -> Result<idevice::pairing_file::PairingFile, *mut c_char> {
    let path = unsafe { c_string(path, "record_path") }?;
    let bytes = std::fs::read(path.to_string_lossy().as_ref())
        .map_err(|e| owned_message(format!("Không đọc được lockdown pair record: {e}")))?;
    idevice::pairing_file::PairingFile::from_bytes(&bytes)
        .map_err(|e| owned_message(format!("Lockdown pair record không hợp lệ: {e}")))
}

/// Accepts classic lockdown records (.mobiledevicepairing / .plist from a
/// computer, iLoader, jitterbugpair…).
#[no_mangle]
pub unsafe extern "C" fn pa_lockdown_validate(record_path: *const c_char) -> *mut c_char {
    match read_lockdown_record(record_path) {
        Ok(_) => null_mut(),
        Err(error) => error,
    }
}

/// Runs lockdown Pair on `device_ip:62078` (blocks while iOS shows Trust) and
/// writes the classic record to `out_path`.
#[no_mangle]
pub unsafe extern "C" fn pa_lockdown_mint(
    device_ip: *const c_char,
    host_id: *const c_char,
    system_buid: *const c_char,
    out_path: *const c_char,
) -> *mut c_char {
    let ip = match parse_ipv4(device_ip) {
        Ok(ip) => ip,
        Err(error) => return error,
    };
    let (host_id, system_buid, out_path) = match (
        c_string(host_id, "host_id"),
        c_string(system_buid, "system_buid"),
        c_string(out_path, "out_path"),
    ) {
        (Ok(a), Ok(b), Ok(c)) => (
            a.to_string_lossy().into_owned(),
            b.to_string_lossy().into_owned(),
            c.to_string_lossy().into_owned(),
        ),
        (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => return e,
    };
    let result = idevice_ffi::run_sync_local(async move {
        let stream = tokio::time::timeout(
            std::time::Duration::from_secs(8),
            tokio::net::TcpStream::connect((ip, LOCKDOWN_PORT)),
        )
        .await
        .map_err(|_| format!("lockdownd {ip}:{LOCKDOWN_PORT} không phản hồi"))?
        .map_err(|e| format!("không kết nối được lockdownd {ip}:{LOCKDOWN_PORT}: {e}"))?;
        let device = idevice::Idevice::new(Box::new(stream), "PanicAnalyzer");
        let mut client = idevice::lockdown::LockdownClient::new(device);
        let record = tokio::time::timeout(
            std::time::Duration::from_secs(120),
            client.pair(host_id, system_buid, Some("PanicAnalyzer")),
        )
        .await
        .map_err(|_| "Hết thời gian chờ bấm Tin cậy".to_string())?
        .map_err(|e| format!("lockdownd từ chối ghép đôi: {e}"))?;
        let bytes = record.serialize().map_err(|e| e.to_string())?;
        std::fs::write(&out_path, bytes).map_err(|e| format!("không lưu được record: {e}"))
    });
    match result {
        Ok(()) => null_mut(),
        Err(error) => owned_message(error),
    }
}

/// Opens CoreDeviceProxy with a classic record over LocalDevVPN, then
/// CrashReportCopyMobile over the resulting RSD tunnel.
#[no_mangle]
pub unsafe extern "C" fn pa_session_connect_lockdown(
    record_path: *const c_char,
    device_ip: *const c_char,
    out_session: *mut *mut PaLogSession,
) -> *mut c_char {
    if out_session.is_null() {
        return owned_message("out_session is null");
    }
    *out_session = null_mut();
    let record = match read_lockdown_record(record_path) {
        Ok(record) => record,
        Err(error) => return error,
    };
    let ip = match parse_ipv4(device_ip) {
        Ok(ip) => ip,
        Err(error) => return error,
    };
    let provider = idevice::provider::TcpProvider {
        addr: std::net::IpAddr::V4(ip),
        scope_id: None,
        pairing_file: record,
        label: "PanicAnalyzer".to_string(),
    };
    let result = idevice_ffi::run_sync_local(async move {
        use idevice::IdeviceService;
        let proxy = tokio::time::timeout(
            std::time::Duration::from_secs(20),
            idevice::core_device_proxy::CoreDeviceProxy::connect(&provider),
        )
        .await
        .map_err(|_| "CoreDeviceProxy quá thời gian".to_string())?
        .map_err(|e| format!("CoreDeviceProxy lỗi: {e}"))?;
        let rsd_port = proxy.tunnel_info().server_rsd_port;
        let adapter = proxy.create_software_tunnel().map_err(|e| e.to_string())?;
        let mut adapter = adapter.to_async_handle();
        let stream = adapter.connect(rsd_port).await.map_err(|e| e.to_string())?;
        let handshake = idevice::rsd::RsdHandshake::new(stream).await.map_err(|e| e.to_string())?;
        Ok::<_, String>((adapter, handshake))
    });
    match result {
        Ok((adapter, handshake)) => {
            let adapter = Box::into_raw(Box::new(AdapterHandle(adapter)));
            let handshake = Box::into_raw(Box::new(RsdHandshakeHandle(handshake)));
            open_crash_reports(adapter, handshake, out_session)
        }
        Err(error) => owned_message(format!(
            "Không mở được tunnel CoreDeviceProxy qua LocalDevVPN ({error})"
        )),
    }
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
            pa_host_free(null_mut());
            let error = pa_host_accept(null_mut(), -1, None, null_mut(), null_mut());
            assert!(!error.is_null());
            pa_error_free(error);
        }
    }

    #[test]
    fn lockdown_route_reports_errors_instead_of_crashing() {
        unsafe {
            let missing = CString::new("/nonexistent/lockdown.plist").unwrap();
            let error = pa_lockdown_validate(missing.as_ptr());
            assert!(!error.is_null());
            pa_error_free(error);

            let bad_ip = CString::new("not-an-ip").unwrap();
            let id = CString::new("ID").unwrap();
            let error = pa_lockdown_mint(bad_ip.as_ptr(), id.as_ptr(), id.as_ptr(), missing.as_ptr());
            assert!(!error.is_null());
            pa_error_free(error);

            let mut session = null_mut();
            let error = pa_session_connect_lockdown(missing.as_ptr(), bad_ip.as_ptr(), &mut session);
            assert!(!error.is_null() && session.is_null());
            pa_error_free(error);
        }
    }

    #[test]
    fn host_prepare_returns_identity_and_txt_records() {
        unsafe {
            let name = CString::new("PanicAnalyzer").unwrap();
            let mut host = null_mut();
            let mut service = null_mut();
            let mut txt = null_mut();
            let mut length = 0usize;
            let error = pa_host_prepare(name.as_ptr(), &mut host, &mut service, &mut txt, &mut length);
            assert!(error.is_null());
            assert!(!host.is_null() && !service.is_null() && !txt.is_null() && length > 0);
            let plist = std::str::from_utf8(std::slice::from_raw_parts(txt, length)).unwrap();
            for key in ["authTag", "identifier", "model", "name"] {
                assert!(plist.contains(key), "{key}");
            }
            assert!(plist.contains("PanicAnalyzer"));
            pa_bytes_free(txt, length);
            pa_error_free(service);
            pa_host_free(host);
        }
    }
}

/// Device-initiated pairing host (iOS 27): identity + Bonjour TXT data. The
/// caller publishes `_remotepairing-pairable-host._tcp` with the platform
/// Bonjour API (apps cannot send raw multicast) and hands accepted sockets to
/// `pa_host_accept`.
pub struct PaPairingHost {
    handle: *mut PairableHostHandle,
}

pub type PaPinCallback = Option<extern "C" fn(pin: *const c_char, context: *mut c_void)>;

#[no_mangle]
pub unsafe extern "C" fn pa_host_prepare(
    name: *const c_char,
    out_host: *mut *mut PaPairingHost,
    out_service_id: *mut *mut c_char,
    out_txt_plist: *mut *mut u8,
    out_txt_length: *mut usize,
) -> *mut c_char {
    if out_host.is_null() || out_service_id.is_null() || out_txt_plist.is_null() || out_txt_length.is_null() {
        return owned_message("Tham số máy chủ ghép đôi không hợp lệ");
    }
    *out_host = null_mut();
    *out_service_id = null_mut();
    *out_txt_plist = null_mut();
    *out_txt_length = 0;
    if let Err(error) = c_string(name, "name") {
        return error;
    }

    let mut handle: *mut PairableHostHandle = null_mut();
    let mut service_id: *mut c_char = null_mut();
    let mut txt: *mut u8 = null_mut();
    let mut txt_length: usize = 0;
    let error = pairable_host_prepare(
        name,
        std::ptr::null(),
        false,
        &mut handle,
        &mut service_id,
        &mut txt,
        &mut txt_length,
        null_mut(),
    );
    if !error.is_null() {
        return consume_idevice_error(error, "Không tạo được danh tính máy chủ ghép đôi");
    }
    // Re-own both buffers so Swift frees them with this library's functions.
    let service = CStr::from_ptr(service_id).to_string_lossy().into_owned();
    idevice_string_free(service_id);
    let mut bytes = std::slice::from_raw_parts(txt, txt_length).to_vec().into_boxed_slice();
    idevice_data_free(txt, txt_length);

    *out_host = Box::into_raw(Box::new(PaPairingHost { handle }));
    *out_service_id = owned_message(service);
    *out_txt_length = bytes.len();
    *out_txt_plist = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    null_mut()
}

/// Runs pair-setup on a socket the device opened to our advertised port and
/// writes the resulting record to `pairing_path`. Blocks until done.
#[no_mangle]
pub unsafe extern "C" fn pa_host_accept(
    host: *mut PaPairingHost,
    socket_fd: i32,
    pin_callback: PaPinCallback,
    pin_context: *mut c_void,
    pairing_path: *const c_char,
) -> *mut c_char {
    if host.is_null() || (*host).handle.is_null() || socket_fd < 0 {
        return owned_message("Phiên ghép đôi không hợp lệ");
    }
    if let Err(error) = c_string(pairing_path, "pairing_path") {
        return error;
    }
    let mut pairing: *mut RpPairingFileHandle = null_mut();
    let error = pairable_host_accept_fd(
        (*host).handle,
        socket_fd,
        pin_callback,
        pin_context,
        null_mut(),
        &mut pairing,
    );
    if !error.is_null() {
        return consume_idevice_error(
            error,
            "Ghép đôi bị huỷ hoặc sai mã PIN. Hãy thử lại và nhập đúng mã app hiển thị",
        );
    }
    if pairing.is_null() {
        return owned_message("iOS không trả về pairing record");
    }
    let write_error = rp_pairing_file_write(pairing, pairing_path);
    rp_pairing_file_free(pairing);
    if !write_error.is_null() {
        return consume_idevice_error(write_error, "Đã ghép đôi nhưng không lưu được pairing record");
    }
    null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn pa_host_free(host: *mut PaPairingHost) {
    if host.is_null() {
        return;
    }
    let host = Box::from_raw(host);
    pairable_host_free(host.handle);
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
