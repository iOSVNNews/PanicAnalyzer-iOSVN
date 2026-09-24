use std::{net::SocketAddr, time::Duration};
use idevice::{remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket,
    connect_tls_psk_tunnel_native}, rsd::RsdHandshake, tcp::handle::AdapterHandle};

// Cancelling this future drops its sockets. A UI-only timer cannot do that and
// leaves the Swift operation lock held forever when the peer stops responding.
pub async fn connect(address: SocketAddr, record: &mut RpPairingFile, timeout: Duration)
    -> Result<(AdapterHandle, RsdHandshake), String>
{
    tokio::time::timeout(timeout, async {
        let stream = tokio::net::TcpStream::connect(address).await
            .map_err(|e| format!("connect: {e}"))?;
        let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "PanicAnalyzer");
        rpc.attempt_pair_verify().await.map_err(|e| format!("RP handshake: {e}"))?;
        // Imported credentials must be verified, never silently replaced by a
        // new pair-setup when iOS rejects them. The user can re-export in iLoader.
        rpc.validate_pairing(record).await.map_err(|e| format!(
            "RP verify: {e}. Export a fresh pairing file for this iPhone in iLoader."
        ))?;
        let port = rpc.create_tcp_listener().await.map_err(|e| format!("RP listener: {e}"))?;
        let stream = tokio::net::TcpStream::connect(SocketAddr::new(address.ip(), port)).await
            .map_err(|e| format!("Tunnel TCP {port}: {e}"))?;
        let tunnel = connect_tls_psk_tunnel_native(stream, rpc.encryption_key()).await
            .map_err(|e| format!("Tunnel TLS: {e}"))?;
        let client_ip = tunnel.info.client_address.parse::<std::net::IpAddr>()
            .map_err(|e| format!("Tunnel client address: {e}"))?;
        let server_ip = tunnel.info.server_address.parse::<std::net::IpAddr>()
            .map_err(|e| format!("Tunnel server address: {e}"))?;
        let mtu = tunnel.info.mtu as usize;
        let rsd_port = tunnel.info.server_rsd_port;
        let mut adapter = idevice::tcp::adapter::Adapter::new(
            Box::new(tunnel.into_inner()), client_ip, server_ip);
        adapter.set_mss(mtu.saturating_sub(60));
        let mut adapter = adapter.to_async_handle();
        let stream = adapter.connect(rsd_port).await.map_err(|e| format!("RSD TCP: {e}"))?;
        let handshake = RsdHandshake::new(stream).await.map_err(|e| format!("RSD handshake: {e}"))?;
        Ok((adapter, handshake))
    }).await.map_err(|_| format!("Remote Pairing timed out ({}s)", timeout.as_secs()))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    #[test]
    fn silent_peer_is_cancelled_and_imported_keys_are_preserved() {
        idevice_ffi::run_sync_local(async {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let peer = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                // Read until the timeout closes the client connection.
                socket.read_to_end(&mut request).await.unwrap();
                assert!(!request.is_empty());
            });
            let mut record = RpPairingFile::generate("test-only");
            let before = record.to_bytes();
            let error = match connect(address, &mut record, Duration::from_millis(200)).await {
                Err(error) => error,
                Ok(_) => panic!("A silent peer cannot complete pairing"),
            };
            assert!(error.contains("timed out"));
            assert_eq!(record.to_bytes(), before);
            tokio::time::timeout(Duration::from_secs(2), peer).await.unwrap().unwrap();
        });
    }
}
