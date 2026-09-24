use std::alloc::{alloc, dealloc, Layout};
use std::ffi::{CStr, CString};
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::os::raw::{c_char, c_void};
use std::ptr::null_mut;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use idevice::crashreportcopymobile::{flush_reports, CrashReportCopyMobileClient};
use idevice::remote_pairing::{connect_tls_psk_tunnel_native, RemotePairingClient, RpPairingSocket};
use idevice::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle as TunnelAdapter;
use idevice::heartbeat::HeartbeatClient;
use idevice::lockdown::LockdownClient;
use idevice::provider::IdeviceProvider;
use idevice::{IdeviceError, IdeviceService, RsdService};
use idevice_ffi::core_device_proxy::{adapter_free, AdapterHandle};
use idevice_ffi::crashreportcopymobile::{crash_report_client_free, CrashReportCopyMobileHandle};
use idevice_ffi::rp_pairing_file::{
    rp_pairing_file_free, rp_pairing_file_read, rp_pairing_file_write, RpPairingFileHandle,
};
use idevice_ffi::rsd::{rsd_handshake_free, RsdHandshakeHandle};
use idevice_ffi::pairing_host::{
    pairable_host_accept_fd, pairable_host_free, pairable_host_prepare, PairableHostHandle,
};
use idevice_ffi::{idevice_data_free, idevice_error_free, idevice_string_free, IdeviceFfiError};

/// Owns the complete read-only crash-report connection. Swift serializes use.
/// `adapter`/`handshake` are null for the direct lockdown route (no tunnel).
pub struct PaLogSession {
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    client: *mut CrashReportCopyMobileHandle,
    /// Direct route only: the lockdown session that started the service is
    /// kept open for the life of the service connection (held, never read;
    /// dropped after the client in pa_session_free).
    #[allow(dead_code)]
    lockdown: Option<LockdownClient>,
    /// Lockdown routes: Marco/Polo heartbeat kept alive while the session
    /// lives; aborted when the session is freed.
    #[allow(dead_code)]
    heartbeat: Option<HeartbeatGuard>,
    /// Set after a timeout or socket error: every later call fails at once
    /// instead of waiting on a dead connection again.
    broken: bool,
}

// MARK: - Deadlines
//
// Every network step has its own deadline. Without them a device that accepts
// TCP but never answers (VPN half up, remotepairingd busy, a consent prompt
// nobody sees) kept the call blocked forever: the UI gave up after 45 s but the
// native scan still held its lock, so every later scan queued behind it.

const CONNECT_SECS: u64 = 6;
const PAIR_VERIFY_SECS: u64 = 15;
const STEP_SECS: u64 = 10;
const SERVICE_SECS: u64 = 15;
const PROXY_SECS: u64 = 15;
const FLUSH_SECS: u64 = 8;
const LIST_SECS: u64 = 15;
const PULL_SECS: u64 = 15;

/// Milliseconds per deadline "second". Tests shrink it to run fast.
static MILLIS_PER_SECOND: AtomicU64 = AtomicU64::new(1000);

fn deadline(secs: u64) -> Duration {
    Duration::from_millis(secs.saturating_mul(MILLIS_PER_SECOND.load(Ordering::Relaxed)))
}

/// Runs `fut` with a deadline; a timeout becomes a readable step error.
async fn within<T, F>(secs: u64, step: &str, fut: F) -> Result<T, String>
where
    F: Future<Output = Result<T, String>>,
{
    match tokio::time::timeout(deadline(secs), fut).await {
        Ok(result) => result,
        Err(_) => Err(format!("{step}: quá {secs} giây không phản hồi")),
    }
}

fn is_connection_error(error: &IdeviceError) -> bool {
    matches!(error, IdeviceError::Socket(_) | IdeviceError::Timeout)
}

// MARK: - Heartbeat
//
// iOS drops lockdown *service* connections from a network host (Wi-Fi sync,
// LocalDevVPN) that has no live com.apple.mobile.heartbeat: StartService
// answers, the TLS handshake completes, then the first read hits EOF
// ("peer closed connection without sending TLS close_notify"). Feather,
// Protokolle and SideStore all keep this Marco/Polo loop running for as long
// as they use services over the VPN.

/// Aborts the heartbeat task when dropped (a dropped JoinHandle would not).
pub struct HeartbeatGuard(tokio::task::JoinHandle<()>);

impl Drop for HeartbeatGuard {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn heartbeat_loop(mut client: HeartbeatClient) {
    let mut interval = 15u64;
    loop {
        match client.get_marco(interval).await {
            Ok(next) => interval = next.clamp(1, 60) + 5,
            // No Marco yet: keep the connection open and wait again.
            Err(IdeviceError::Heartbeat(idevice::HeartbeatError::Timeout)) => continue,
            Err(_) => return,
        }
        if client.send_polo().await.is_err() {
            return;
        }
    }
}

/// H1: starts the heartbeat on the runtime's worker threads. It keeps running
/// after the FFI call returns, until the guard is dropped.
async fn start_heartbeat(provider: &idevice::provider::TcpProvider) -> Result<HeartbeatGuard, String> {
    let client = within(STEP_SECS, "H1 heartbeat", async {
        HeartbeatClient::connect(provider)
            .await
            .map_err(|e| format!("H1 heartbeat: {}", describe(&e)))
    })
    .await?;
    Ok(HeartbeatGuard(tokio::spawn(heartbeat_loop(client))))
}

/// A later failure is easier to read with the reason the heartbeat did not start.
fn with_heartbeat_note(error: String, heartbeat_error: Option<String>) -> String {
    match heartbeat_error {
        Some(note) => format!("{error}; {note}"),
        None => error,
    }
}

/// "device socket io failed" alone hides why: add the OS error kind and text
/// (UnexpectedEof = the iPhone closed the connection, ConnectionReset, …).
fn describe(error: &IdeviceError) -> String {
    match error {
        IdeviceError::Socket(io) => format!("{error} ({:?}: {io})", io.kind()),
        _ => error.to_string(),
    }
}

const BROKEN_SESSION: &str =
    "Kết nối CrashReporter đã ngắt (VPN rớt hoặc thiết bị không phản hồi); hãy quét lại";

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

fn new_session(
    tunnel: Option<(TunnelAdapter, RsdHandshake)>,
    lockdown: Option<LockdownClient>,
    heartbeat: Option<HeartbeatGuard>,
    client: CrashReportCopyMobileClient,
) -> *mut PaLogSession {
    let (adapter, handshake) = match tunnel {
        Some((adapter, handshake)) => (
            Box::into_raw(Box::new(AdapterHandle(adapter))),
            Box::into_raw(Box::new(RsdHandshakeHandle(handshake))),
        ),
        None => (null_mut(), null_mut()),
    };
    Box::into_raw(Box::new(PaLogSession {
        adapter,
        handshake,
        client: Box::into_raw(Box::new(CrashReportCopyMobileHandle(client))),
        lockdown,
        heartbeat,
        broken: false,
    }))
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

// MARK: - Remote Pairing route (StikDebug: 10.7.0.1:49152)

/// Same steps as idevice-ffi's `tunnel_create_rppairing` (the call StikDebug
/// makes), but every step has a deadline and a step label (R1…R7) so a failure
/// says where it stopped.
async fn open_rppairing_tunnel(
    address: SocketAddr,
    pairing: &mut idevice::remote_pairing::RpPairingFile,
) -> Result<(TunnelAdapter, RsdHandshake), String> {
    // "connect:" + the OS error text is what Swift's isRefusedBeforePairing reads.
    let stream = within(CONNECT_SECS, "connect: R1 TCP", async {
        tokio::net::TcpStream::connect(address)
            .await
            .map_err(|e| format!("connect: {e}"))
    })
    .await?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "PanicAnalyzer");
    within(PAIR_VERIFY_SECS, "R2 pair-verify", async {
        rpc.connect(&mut *pairing, || async { "000000".to_string() })
            .await
            .map_err(|e| format!("R2 pair-verify: {}", describe(&e)))
    })
    .await?;
    let tunnel_port = within(STEP_SECS, "R3 xin cổng tunnel", async {
        rpc.create_tcp_listener()
            .await
            .map_err(|e| format!("R3 xin cổng tunnel: {}", describe(&e)))
    })
    .await?;
    let mut tunnel_address = address;
    tunnel_address.set_port(tunnel_port);
    let tunnel_stream = within(CONNECT_SECS, "R4 nối cổng tunnel", async {
        tokio::net::TcpStream::connect(tunnel_address)
            .await
            .map_err(|e| format!("R4 nối cổng tunnel {tunnel_port}: {e}"))
    })
    .await?;
    let key = rpc.encryption_key().to_vec();
    let tunnel = within(STEP_SECS, "R5 TLS-PSK", async {
        connect_tls_psk_tunnel_native(tunnel_stream, &key)
            .await
            .map_err(|e| format!("R5 TLS-PSK: {}", describe(&e)))
    })
    .await?;
    let client_ip: IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|e| format!("R5 địa chỉ tunnel: {e}"))?;
    let server_ip: IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|e| format!("R5 địa chỉ tunnel: {e}"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    let mut adapter =
        idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    rsd_over_adapter(adapter.to_async_handle(), rsd_port, "R6", "R7").await
}

/// Opens RSD inside a software tunnel (both routes that use a tunnel).
async fn rsd_over_adapter(
    mut adapter: TunnelAdapter,
    rsd_port: u16,
    connect_step: &str,
    handshake_step: &str,
) -> Result<(TunnelAdapter, RsdHandshake), String> {
    let stream = within(STEP_SECS, &format!("{connect_step} nối RSD cổng {rsd_port}"), async {
        adapter
            .connect(rsd_port)
            .await
            .map_err(|e| format!("{connect_step} nối RSD cổng {rsd_port}: {e}"))
    })
    .await?;
    let handshake = within(STEP_SECS, &format!("{handshake_step} bắt tay RSD"), async {
        RsdHandshake::new(stream)
            .await
            .map_err(|e| format!("{handshake_step} bắt tay RSD: {}", describe(&e)))
    })
    .await?;
    Ok((adapter, handshake))
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
    let ip = match parse_ipv4(device_ip) {
        Ok(ip) => ip,
        Err(error) => return error,
    };
    let address = SocketAddr::new(IpAddr::V4(ip), rsd_port);

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
    let tunnel = idevice_ffi::run_sync_local(open_rppairing_tunnel(address, &mut (*pairing).0));
    let (adapter, handshake) = match tunnel {
        Ok(parts) => parts,
        Err(error) => {
            rp_pairing_file_free(pairing);
            return owned_message(format!(
                "Không hoàn tất ghép đôi hoặc mở RSD tunnel. Kiểm tra LocalDevVPN còn kết nối, mở khóa iPhone và chấp nhận yêu cầu ghép đôi ({error})"
            ));
        }
    };

    // Pair-verify may have refreshed stale credentials after iOS approved
    // them. Persist only after the complete pairing+tunnel succeeded.
    let write_error = rp_pairing_file_write(pairing, pairing_path);
    rp_pairing_file_free(pairing);
    if !write_error.is_null() {
        idevice_ffi::run_sync_local(async move { drop((adapter, handshake)) });
        return consume_idevice_error(
            write_error,
            "Đã ghép đôi nhưng không lưu được pairing record",
        );
    }

    open_crash_reports(adapter, handshake, None, out_session)
}

/// Opens CrashReportCopyMobile over an RSD tunnel and hands ownership of the
/// tunnel and the client to a new session.
unsafe fn open_crash_reports(
    adapter: TunnelAdapter,
    handshake: RsdHandshake,
    heartbeat: Option<HeartbeatGuard>,
    out_session: *mut *mut PaLogSession,
) -> *mut c_char {
    let result = idevice_ffi::run_sync_local(async move {
        let (mut adapter, mut handshake) = (adapter, handshake);
        let client = within(SERVICE_SECS, "C1 crashreportcopymobile qua RSD", async {
            CrashReportCopyMobileClient::connect_rsd(&mut adapter, &mut handshake)
                .await
                .map_err(|e| format!("C1 crashreportcopymobile qua RSD: {}", describe(&e)))
        })
        .await?;
        Ok::<_, String>((adapter, handshake, client))
    });
    match result {
        Ok((adapter, handshake, client)) => {
            *out_session = new_session(Some((adapter, handshake)), None, heartbeat, client);
            null_mut()
        }
        Err(error) => owned_message(format!(
            "Không kết nối được dịch vụ crashreportcopymobile ({error})"
        )),
    }
}

// MARK: - Lockdown routes (classic pair record, lockdownd on 62078)
//
// On-device, the RPPairing tunnel can fail after pair-verify: the tunnel
// listener iOS opens binds to Wi-Fi only and the device closes a tunnel to
// itself (close_notify). Two routes need no inbound listener and ride a
// lockdown session on 62078 through LocalDevVPN instead:
//   * direct: StartService com.apple.crashreportcopymobile (what SideStore does
//     for its own services) — no tunnel at all;
//   * CoreDeviceProxy: a software tunnel, then RSD (the StikDebug 17.x recipe).
// The classic record comes from an imported pairing file or is minted here.

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

fn lockdown_provider(
    record: idevice::pairing_file::PairingFile,
    ip: Ipv4Addr,
) -> idevice::provider::TcpProvider {
    idevice::provider::TcpProvider {
        addr: IpAddr::V4(ip),
        scope_id: None,
        pairing_file: record,
        label: "PanicAnalyzer".to_string(),
    }
}

/// B1: can we reach lockdownd through the VPN at all? Separates "VPN not
/// routed / Local Network denied" from handshake errors further in.
async fn preflight_lockdownd(ip: Ipv4Addr) -> Result<(), String> {
    match tokio::time::timeout(
        deadline(CONNECT_SECS),
        tokio::net::TcpStream::connect((ip, LOCKDOWN_PORT)),
    )
    .await
    {
        Err(_) => Err(format!(
            "B1 socket lockdownd {ip}:{LOCKDOWN_PORT} quá thời gian — LocalDevVPN chưa định tuyến tới thiết bị. Bật/kết nối lại VPN rồi thử lại."
        )),
        Ok(Err(e)) => Err(format!(
            "B1 không mở được lockdownd {ip}:{LOCKDOWN_PORT}: {e} — kiểm tra LocalDevVPN và quyền Mạng cục bộ của PanicAnalyzer."
        )),
        Ok(Ok(_)) => Ok(()),
    }
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
            deadline(8),
            tokio::net::TcpStream::connect((ip, LOCKDOWN_PORT)),
        )
        .await
        .map_err(|_| format!("lockdownd {ip}:{LOCKDOWN_PORT} không phản hồi"))?
        .map_err(|e| format!("không kết nối được lockdownd {ip}:{LOCKDOWN_PORT}: {e}"))?;
        let device = idevice::Idevice::new(Box::new(stream), "PanicAnalyzer");
        let mut client = idevice::lockdown::LockdownClient::new(device);
        let record = tokio::time::timeout(
            deadline(120),
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

/// Direct route: lockdown session on 62078, then StartService
/// com.apple.crashreportcopymobile — the same way SideStore reaches
/// installation_proxy/AFC over LocalDevVPN. No tunnel, no RSD, no listener on
/// the device, so it is the least fragile route on iOS 17.4–18.
#[no_mangle]
pub unsafe extern "C" fn pa_session_connect_lockdown_direct(
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
    let provider = lockdown_provider(record, ip);
    let result = idevice_ffi::run_sync_local(async move {
        preflight_lockdownd(ip).await?;
        let (heartbeat, heartbeat_error) = match start_heartbeat(&provider).await {
            Ok(guard) => (Some(guard), None),
            Err(error) => (None, Some(error)),
        };
        // L1 (best effort): ask crashreportmover to move pending reports into
        // the CrashReporter view, as idevicecrashreport/Xcode do first.
        let _ = tokio::time::timeout(deadline(FLUSH_SECS), flush_reports(&provider)).await;
        within(SERVICE_SECS, "L2-L4 lockdown StartService crashreportcopymobile", async {
            let pairing = provider
                .get_pairing_file()
                .await
                .map_err(|e| format!("L2 pair record: {}", describe(&e)))?;
            let mut lockdown = LockdownClient::connect(&provider)
                .await
                .map_err(|e| format!("L2 nối lockdownd: {}", describe(&e)))?;
            let legacy = lockdown
                .start_session(&pairing)
                .await
                .map_err(|e| format!("L2 StartSession: {}", describe(&e)))?;
            let (port, ssl) = lockdown
                .start_service("com.apple.crashreportcopymobile")
                .await
                .map_err(|e| format!("L3 StartService com.apple.crashreportcopymobile: {}", describe(&e)))?;
            let mut device = provider
                .connect(port)
                .await
                .map_err(|e| format!("L4 nối cổng dịch vụ {port}: {}", describe(&e)))?;
            if ssl {
                device
                    .start_session(&pairing, legacy)
                    .await
                    .map_err(|e| format!("L4 TLS dịch vụ cổng {port}: {}", describe(&e)))?;
            }
            Ok((lockdown, CrashReportCopyMobileClient::new(device)))
        })
        .await
        .map(|(lockdown, client)| (heartbeat, lockdown, client))
        .map_err(|error| with_heartbeat_note(error, heartbeat_error))
    });
    match result {
        Ok((heartbeat, lockdown, client)) => {
            *out_session = new_session(None, Some(lockdown), heartbeat, client);
            null_mut()
        }
        Err(error) => owned_message(format!(
            "Không đọc được CrashReporter trực tiếp qua lockdown ({error})"
        )),
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
    let provider = lockdown_provider(record, ip);
    let result = idevice_ffi::run_sync_local(async move {
        preflight_lockdownd(ip).await?;
        let (heartbeat, heartbeat_error) = match start_heartbeat(&provider).await {
            Ok(guard) => (Some(guard), None),
            Err(error) => (None, Some(error)),
        };
        let tunnel = async {
            let proxy = within(PROXY_SECS, "B2 CoreDeviceProxy::connect (StartService tunnelservice)", async {
                idevice::core_device_proxy::CoreDeviceProxy::connect(&provider)
                    .await
                    .map_err(|e| format!(
                        "B2 CoreDeviceProxy::connect: {} — bắt tay lockdown / StartService untrusted.tunnelservice thất bại. Pairing file có thể thiếu phần Remote Pairing hoặc thiết bị chưa Tin cậy.",
                        describe(&e)
                    ))
            })
            .await?;
            let rsd_port = proxy.tunnel_info().server_rsd_port;
            let adapter = proxy
                .create_software_tunnel()
                .map_err(|e| format!("B3 tạo software tunnel: {e}"))?;
            rsd_over_adapter(adapter.to_async_handle(), rsd_port, "B4", "B5").await
        };
        tunnel
            .await
            .map(|(adapter, handshake)| (heartbeat, adapter, handshake))
            .map_err(|error| with_heartbeat_note(error, heartbeat_error))
    });
    match result {
        Ok((heartbeat, adapter, handshake)) => open_crash_reports(adapter, handshake, heartbeat, out_session),
        Err(error) => owned_message(format!(
            "Không mở được tunnel CoreDeviceProxy qua LocalDevVPN ({error})"
        )),
    }
}

// MARK: - Reading CrashReporter

/// True once a timeout or socket error killed the session: stop scanning.
#[no_mangle]
pub unsafe extern "C" fn pa_session_is_broken(session: *const PaLogSession) -> bool {
    session.is_null() || (*session).broken
}

/// Allocates a C string array that pa_string_array_free releases.
unsafe fn write_string_array(
    names: Vec<String>,
    out_entries: *mut *mut *mut c_char,
    out_count: *mut usize,
) -> Result<(), ()> {
    let layout = Layout::array::<*mut c_char>(names.len() + 1).map_err(|_| ())?;
    let array = alloc(layout) as *mut *mut c_char;
    if array.is_null() {
        return Err(());
    }
    for (index, name) in names.iter().enumerate() {
        *array.add(index) = owned_message(name);
    }
    *array.add(names.len()) = null_mut();
    *out_entries = array;
    *out_count = names.len();
    Ok(())
}

#[no_mangle]
pub unsafe extern "C" fn pa_session_list(
    session: *mut PaLogSession,
    directory: *const c_char,
    out_entries: *mut *mut *mut c_char,
    out_count: *mut usize,
) -> *mut c_char {
    if session.is_null() || (*session).client.is_null() || out_entries.is_null() || out_count.is_null() {
        return owned_message("Tham số liệt kê log không hợp lệ");
    }
    *out_entries = null_mut();
    *out_count = 0;
    let session = &mut *session;
    if session.broken {
        return owned_message(BROKEN_SESSION);
    }
    let directory = if directory.is_null() {
        None
    } else {
        match CStr::from_ptr(directory).to_str() {
            Ok(path) => Some(path.to_string()),
            Err(_) => return owned_message("Tên thư mục CrashReporter không hợp lệ"),
        }
    };
    let client = &mut (*session.client).0;
    let result = idevice_ffi::run_sync_local(async {
        tokio::time::timeout(deadline(LIST_SECS), client.ls(directory.as_deref())).await
    });
    match result {
        Err(_) => {
            session.broken = true;
            owned_message(format!("Liệt kê CrashReporter quá {LIST_SECS} giây. {BROKEN_SESSION}"))
        }
        Ok(Err(error)) => {
            if is_connection_error(&error) {
                session.broken = true;
            }
            owned_message(format!("Không liệt kê được thư mục CrashReporter: {}", describe(&error)))
        }
        Ok(Ok(names)) => match write_string_array(names, out_entries, out_count) {
            Ok(()) => null_mut(),
            Err(()) => owned_message("Không đủ bộ nhớ để liệt kê log"),
        },
    }
}

enum PullError {
    /// This file only (too big, vanished, changed while reading).
    Skip(String),
    /// The connection is gone: later calls would only wait again.
    Fatal(String),
}

fn pull_error(error: IdeviceError) -> PullError {
    if is_connection_error(&error) {
        PullError::Fatal(describe(&error))
    } else {
        PullError::Skip(describe(&error))
    }
}

#[no_mangle]
pub unsafe extern "C" fn pa_session_pull(
    session: *mut PaLogSession,
    relative_path: *const c_char,
    out_data: *mut *mut u8,
    out_length: *mut usize,
) -> *mut c_char {
    if session.is_null()
        || (*session).client.is_null()
        || relative_path.is_null()
        || out_data.is_null()
        || out_length.is_null()
    {
        return owned_message("Tham số tải log không hợp lệ");
    }
    *out_data = null_mut();
    *out_length = 0;
    let session = &mut *session;
    if session.broken {
        return owned_message(BROKEN_SESSION);
    }
    let path = match CStr::from_ptr(relative_path).to_str() {
        Ok(path) if valid_log_path(path) => path.to_string(),
        _ => return owned_message("Đường dẫn crash report không hợp lệ"),
    };
    let afc = &mut (*session.client).0.afc_client;
    let result = idevice_ffi::run_sync_local(async {
        tokio::time::timeout(deadline(PULL_SECS), async {
            let path = format!("/{path}");
            let info = afc.get_file_info_raw(&path).await.map_err(pull_error)?;
            let size = info
                .get("st_size")
                .and_then(|s| s.parse::<usize>().ok())
                .ok_or_else(|| PullError::Skip("Không xác định được kích thước log".into()))?;
            if info.get("st_ifmt").map(String::as_str) != Some("S_IFREG") || size > MAX_FILE_BYTES {
                return Err(PullError::Skip("Bỏ qua log quá 12 MB hoặc không phải tệp thường".into()));
            }
            let mut file = afc
                .open(path, idevice::afc::opcode::AfcFopenMode::RdOnly)
                .await
                .map_err(pull_error)?;
            let bytes = file.read_n(size).await;
            let close = file.close().await;
            let bytes = bytes.map_err(pull_error)?;
            close.map_err(pull_error)?;
            if bytes.len() != size {
                return Err(PullError::Skip("Log thay đổi trong lúc đọc; hãy quét lại".into()));
            }
            Ok(bytes)
        })
        .await
    });
    match result {
        Ok(Ok(bytes)) => {
            let mut bytes = bytes.into_boxed_slice();
            *out_length = bytes.len();
            *out_data = bytes.as_mut_ptr();
            std::mem::forget(bytes);
            null_mut()
        }
        Ok(Err(PullError::Skip(error))) => owned_message(error),
        Ok(Err(PullError::Fatal(error))) => {
            session.broken = true;
            owned_message(format!("{BROKEN_SESSION} ({error})"))
        }
        Err(_) => {
            session.broken = true;
            owned_message(format!("Đọc log quá {PULL_SECS} giây. {BROKEN_SESSION}"))
        }
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

    fn shrink_deadlines() {
        // 1 deadline "second" = 50 ms, so the silent-device tests finish fast.
        MILLIS_PER_SECOND.store(50, Ordering::Relaxed);
    }

    fn take_message(error: *mut c_char) -> String {
        assert!(!error.is_null());
        let text = unsafe { CStr::from_ptr(error) }.to_string_lossy().into_owned();
        unsafe { pa_error_free(error) };
        text
    }

    fn temp_rp_pairing_file(tag: &str) -> CString {
        let dir = std::env::temp_dir().join(format!("pa-test-{}-{tag}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rp_pairing_file.plist");
        let file = idevice::remote_pairing::RpPairingFile::generate("PanicAnalyzerTest");
        std::fs::write(&path, file.to_bytes()).unwrap();
        CString::new(path.to_str().unwrap()).unwrap()
    }

    #[test]
    fn deadline_turns_a_silent_step_into_an_error() {
        shrink_deadlines();
        let started = std::time::Instant::now();
        let result: Result<(), String> = idevice_ffi::run_sync_local(within(
            2,
            "X9 bước thử",
            std::future::pending::<Result<(), String>>(),
        ));
        let message = result.unwrap_err();
        assert!(message.contains("X9 bước thử") && message.contains("2 giây"), "{message}");
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn remote_pairing_gives_up_on_a_silent_device() {
        shrink_deadlines();
        // Accepts TCP (kernel backlog) but never answers, like a half-up VPN.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let pairing = temp_rp_pairing_file("silent");
        let ip = CString::new("127.0.0.1").unwrap();
        let started = std::time::Instant::now();
        let mut session = null_mut();
        let error = unsafe { pa_session_connect(pairing.as_ptr(), ip.as_ptr(), port, &mut session) };
        assert!(session.is_null());
        let message = take_message(error);
        assert!(message.contains("R2 pair-verify"), "{message}");
        assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
        drop(listener);
    }

    #[test]
    fn remote_pairing_reports_a_refused_port_before_pairing() {
        shrink_deadlines();
        let port = {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            listener.local_addr().unwrap().port()
        };
        let pairing = temp_rp_pairing_file("refused");
        let ip = CString::new("127.0.0.1").unwrap();
        let mut session = null_mut();
        let error = unsafe { pa_session_connect(pairing.as_ptr(), ip.as_ptr(), port, &mut session) };
        assert!(session.is_null());
        // Swift's isRefusedBeforePairing depends on this wording.
        let message = take_message(error).to_lowercase();
        assert!(message.contains("connect:") && message.contains("connection refused"), "{message}");
    }

    #[test]
    fn remote_pairing_gives_up_when_the_device_hangs_up() {
        shrink_deadlines();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let closer = std::thread::spawn(move || {
            if let Ok((stream, _)) = listener.accept() {
                drop(stream);
            }
        });
        let pairing = temp_rp_pairing_file("hangup");
        let ip = CString::new("127.0.0.1").unwrap();
        let started = std::time::Instant::now();
        let mut session = null_mut();
        let error = unsafe { pa_session_connect(pairing.as_ptr(), ip.as_ptr(), port, &mut session) };
        assert!(session.is_null());
        let message = take_message(error);
        assert!(message.contains("R2"), "{message}");
        assert!(started.elapsed() < Duration::from_secs(5));
        closer.join().unwrap();
    }

    #[test]
    fn direct_lockdown_route_reports_errors_instead_of_crashing() {
        unsafe {
            let missing = CString::new("/nonexistent/lockdown.plist").unwrap();
            let ip = CString::new("10.7.0.1").unwrap();
            let mut session = null_mut();
            let error = pa_session_connect_lockdown_direct(missing.as_ptr(), ip.as_ptr(), &mut session);
            assert!(session.is_null());
            assert!(take_message(error).contains("lockdown pair record"));
            let error = pa_session_connect_lockdown_direct(missing.as_ptr(), ip.as_ptr(), null_mut());
            assert!(!error.is_null());
            pa_error_free(error);
            assert!(pa_session_is_broken(std::ptr::null()));
            let mut entries = null_mut();
            let mut count = 0usize;
            let error = pa_session_list(null_mut(), null_mut(), &mut entries, &mut count);
            assert!(!error.is_null());
            pa_error_free(error);
        }
    }

    #[test]
    fn heartbeat_guard_stops_its_task_when_dropped() {
        use std::sync::atomic::AtomicBool;
        use std::sync::Arc;
        let finished = Arc::new(AtomicBool::new(false));
        let flag = finished.clone();
        let guard = idevice_ffi::run_sync_local(async move {
            HeartbeatGuard(tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(300)).await;
                flag.store(true, Ordering::SeqCst);
            }))
        });
        drop(guard);
        std::thread::sleep(Duration::from_millis(600));
        assert!(!finished.load(Ordering::SeqCst), "heartbeat task must stop with its session");
    }

    #[test]
    fn string_arrays_round_trip_through_the_free_function() {
        unsafe {
            let mut entries = null_mut();
            let mut count = 0usize;
            let names = vec!["Retired".to_string(), "panic-full-2026-09-24.ips".to_string()];
            assert!(write_string_array(names, &mut entries, &mut count).is_ok());
            assert_eq!(count, 2);
            assert_eq!(CStr::from_ptr(*entries.add(1)).to_str().unwrap(), "panic-full-2026-09-24.ips");
            assert!((*entries.add(2)).is_null());
            pa_string_array_free(entries, count);
            assert!(write_string_array(Vec::new(), &mut entries, &mut count).is_ok());
            assert_eq!(count, 0);
            pa_string_array_free(entries, count);
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
