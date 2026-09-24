import Foundation
import Network

/// Checks the actual device endpoint before creating or replacing pairing keys.
/// Call the blocking network methods from a worker queue, never the main queue.
///
/// iOS does not keep RemotePairing (`remotepairingd`) on a fixed port. 49152 is
/// only the usual first ephemeral port; after a reboot or daemon restart it can
/// move (49153, 49154…). A "connection refused" at 10.7.0.1 therefore means the
/// VPN route works but the port is stale, so the real port is looked up through
/// the device's own `_remotepairing._tcp` Bonjour advertisement.
enum LocalVPNConnection {
    static let defaultAddress = "10.7.0.1"
    static let defaultPort: UInt16 = 49152
    static let remotePairingServiceType = "_remotepairing._tcp"
    static let discoveryTimeout: TimeInterval = 5
    private static let addressKey = "localVPNDeviceAddress"
    private static let portOverrideKey = "remotePairingPortOverride"
    private static let lastPortKey = "remotePairingLastPort"

    struct ConnectionError: LocalizedError {
        let message: String
        /// True when a TCP stack answered with RST: the VPN route works, the port is closed.
        var refused = false
        var errorDescription: String? { message }
    }

    // MARK: - Saved settings

    /// LocalDevVPN's peer address. Fixed: the app no longer has a VPN settings
    /// screen (the port is found automatically), so old saved values are dropped.
    static var deviceAddress: String {
        clearLegacySettings()
        return defaultAddress
    }

    /// Removes the Device IP / port a previous build let the user type in.
    static func clearLegacySettings() {
        UserDefaults.standard.removeObject(forKey: addressKey)
        UserDefaults.standard.removeObject(forKey: portOverrideKey)
    }

    /// Port that worked last time (found by Bonjour or the default).
    static var lastWorkingPort: UInt16? {
        storedPort(forKey: lastPortKey)
    }

    static func rememberWorkingPort(_ port: UInt16) {
        UserDefaults.standard.set(Int(port), forKey: lastPortKey)
    }

    static func forgetWorkingPort() {
        UserDefaults.standard.removeObject(forKey: lastPortKey)
    }

    private static func storedPort(forKey key: String) -> UInt16? {
        let value = UserDefaults.standard.integer(forKey: key)
        return (1...65535).contains(value) ? UInt16(value) : nil
    }

    // MARK: - Input validation

    /// LocalDevVPN displays CIDR (e.g. 10.7.0.1/32); the connection needs only IPv4.
    static func normalizedAddress(_ input: String) throws -> String {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.count == 1 || (Int(parts[1]).map { (0...32).contains($0) } ?? false) else {
            throw ConnectionError(message: Loc.s("Device IP không hợp lệ. Ví dụ: 10.7.0.1 hoặc 10.7.0.1/32.",
                                                 "Invalid Device IP. Example: 10.7.0.1 or 10.7.0.1/32.",
                                                 "Device IP 无效。例如：10.7.0.1 或 10.7.0.1/32。"))
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" }
                  && UInt8($0) != nil }),
              let first = UInt8(octets[0]), first > 0, first < 224,
              first != 127 else {
            throw ConnectionError(message: Loc.s("Hãy nhập IPv4 ở mục Device IP của LocalDevVPN, không phải Tunnel IP.",
                                                 "Enter the IPv4 from LocalDevVPN's Device IP field, not the Tunnel IP.",
                                                 "请输入 LocalDevVPN 中 Device IP 的 IPv4，而不是 Tunnel IP。"))
        }
        return octets.map { String(UInt8($0)!) }.joined(separator: ".")
    }

    /// Empty input means "auto-detect" and returns nil.
    static func normalizedPort(_ input: String) throws -> UInt16? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(trimmed), (1...65535).contains(value) else {
            throw ConnectionError(message: Loc.s("Cổng RemotePairing không hợp lệ.",
                                                 "Invalid RemotePairing port.",
                                                 "RemotePairing 端口无效。"))
        }
        return UInt16(value)
    }

    // MARK: - Endpoint resolution

    /// Finds a RemotePairing port that accepts TCP at `address`: the last
    /// working port, then 49152, then Bonjour discovery.
    static func remotePairingPort(address: String) throws -> UInt16 {
        let port = try resolvePort(
            address: address,
            manualPort: nil,
            cachedPort: lastWorkingPort
        )
        rememberWorkingPort(port)
        return port
    }

    /// Pure resolution logic (settings are passed in) so it can be tested off-device.
    static func resolvePort(
        address: String,
        manualPort: UInt16?,
        cachedPort: UInt16?,
        excluding excluded: Set<UInt16> = [],
        probe: (String, UInt16, TimeInterval) throws -> Void = LocalVPNConnection.probe,
        discover: (TimeInterval) -> [UInt16] = LocalVPNConnection.discoverRemotePairingPorts
    ) throws -> UInt16 {
        if let manualPort {
            try waitUntilReachable(address: address, port: manualPort, probe: probe)
            return manualPort
        }

        var tried = excluded
        let first = [cachedPort, defaultPort].compactMap { $0 }.first { !tried.contains($0) }
        var lastError: Error?
        if let first {
            tried.insert(first)
            do {
                try waitUntilReachable(address: address, port: first, probe: probe)
                return first
            } catch {
                lastError = error
                // Timeout / no route / Local Network denied: the VPN itself is down.
                // Discovery cannot fix that, so fail fast with the VPN instructions.
                guard (error as? ConnectionError)?.refused == true else { throw error }
            }
        }

        let candidates = discover(discoveryTimeout).filter { tried.insert($0).inserted }
        for port in candidates {
            do {
                try probe(address, port, 4)
                return port
            } catch {
                lastError = error
            }
        }

        let triedPorts = tried.sorted().map(String.init).joined(separator: ", ")
        throw ConnectionError(
            message: Loc.s(
                "LocalDevVPN đã chạy nhưng dịch vụ RemotePairing của iOS không mở tại \(address) "
                    + "(đã thử cổng \(triedPorts)) và không dò được cổng qua Bonjour \(remotePairingServiceType). "
                    + "Hãy tắt rồi bật lại LocalDevVPN, bật Wi-Fi, cho phép quyền Mạng cục bộ, rồi thử lại.",
                "LocalDevVPN is running but iOS's RemotePairing service is not open at \(address) "
                    + "(tried ports \(triedPorts)) and no port was found via Bonjour \(remotePairingServiceType). "
                    + "Turn LocalDevVPN off and on, turn on Wi-Fi, allow Local Network, then try again.",
                "LocalDevVPN 已运行，但 iOS 的 RemotePairing 服务在 \(address) 未开放"
                    + "（已尝试端口 \(triedPorts)），且无法通过 Bonjour \(remotePairingServiceType) 找到端口。"
                    + "请关闭再打开 LocalDevVPN、打开 Wi-Fi、允许本地网络后重试。")
                + (lastError.map { " (\($0.localizedDescription))" } ?? ""),
            refused: true
        )
    }

    /// lockdownd listens on 62078 on every iOS version, whatever pairing route
    /// is used afterwards.
    static let lockdownPort: UInt16 = 62078

    /// One reachability check before any pairing route: every route needs
    /// LocalDevVPN to deliver TCP to the device. An answer on 62078, even a
    /// refusal, proves the VPN route works; silence means VPN off / not yet
    /// connected / Local Network denied, which no route can work around.
    static func checkDeviceReachable(
        address: String,
        probe: (String, UInt16, TimeInterval) throws -> Void = LocalVPNConnection.probe
    ) throws {
        do {
            try probe(address, lockdownPort, 8)
        } catch let error as ConnectionError where error.refused {
            return
        } catch {
            throw ConnectionError(message: Loc.s(
                "Không tới được iPhone qua LocalDevVPN (\(address):\(lockdownPort)). Mở LocalDevVPN, bấm Kết nối tới khi báo "
                    + "Connected, bật Wi-Fi, cho phép Mạng cục bộ cho PanicAnalyzer (Cài đặt > PanicAnalyzer), rồi quét lại. "
                    + "Chi tiết: \(error.localizedDescription)",
                "Cannot reach the iPhone through LocalDevVPN (\(address):\(lockdownPort)). Open LocalDevVPN, tap Connect until it "
                    + "says Connected, turn on Wi-Fi, allow Local Network for PanicAnalyzer (Settings > PanicAnalyzer), then scan again. "
                    + "Details: \(error.localizedDescription)",
                "无法通过 LocalDevVPN 连接 iPhone（\(address):\(lockdownPort)）。请打开 LocalDevVPN 并连接直到显示 Connected，"
                    + "打开 Wi-Fi，允许 PanicAnalyzer 使用本地网络（设置 > PanicAnalyzer），然后重新扫描。"
                    + "详情：\(error.localizedDescription)"))
        }
    }

    static func waitUntilReachable(address: String, port: UInt16 = defaultPort,
                                   probe: (String, UInt16, TimeInterval) throws -> Void = LocalVPNConnection.probe) throws {
        // The first attempt also gives iOS time to show the Local Network prompt.
        // Retry only TCP readiness; never repeat a failed pairing/consent exchange.
        do {
            try probe(address, port, 10)
        } catch {
            // A refusal is a definite answer from the device: retrying the same port is pointless.
            if (error as? ConnectionError)?.refused == true { throw error }
            Thread.sleep(forTimeInterval: 0.5)
            try probe(address, port, 4)
        }
    }

    // MARK: - TCP probe

    static func probe(address: String, port: UInt16, timeout: TimeInterval) throws {
        precondition(!Thread.isMainThread, "VPN checks must not block the UI")
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ConnectionError(message: Loc.s("Cổng LocalDevVPN không hợp lệ.", "Invalid LocalDevVPN port.", "LocalDevVPN 端口无效。"))
        }
        // Fast, deterministic answer first: a plain TCP connect reports RST as
        // ECONNREFUSED at once, while Network.framework may keep retrying a
        // refused endpoint in .waiting until the deadline.
        switch quickConnect(address: address, port: port, timeout: min(timeout, 2)) {
        case 0:
            return
        case ECONNREFUSED:
            throw ConnectionError(
                message: Loc.s("LocalDevVPN đã chạy nhưng cổng RemotePairing \(address):\(port) đang đóng (Connection refused).",
                               "LocalDevVPN is running but RemotePairing port \(address):\(port) is closed (Connection refused).",
                               "LocalDevVPN 已运行，但 RemotePairing 端口 \(address):\(port) 已关闭（Connection refused）。"),
                refused: true
            )
        default:
            break // No route yet / permission pending: let NWConnection wait for it.
        }
        let queue = DispatchQueue(label: "com.iosvn.panicanalyzer.vpn-probe")
        let done = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        // All result state is confined to queue; read it with queue.sync below.
        var finished = false
        var succeeded = false
        var refused = false
        var detail = Loc.s("Kết nối quá thời gian.", "Connection timed out.", "连接超时。")
        func finish(_ success: Bool) {
            guard !finished else { return }
            finished = true
            succeeded = success
            connection.stateUpdateHandler = nil
            connection.cancel()
            done.signal()
        }
        func isRefused(_ error: NWError) -> Bool {
            if case .posix(let code) = error, code == .ECONNREFUSED { return true }
            return false
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .waiting(let error):
                detail = error.localizedDescription
                if isRefused(error) {
                    // Network.framework parks refused connections in .waiting and
                    // would retry until the deadline; the answer is already final.
                    refused = true
                    finish(false)
                    return
                }
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    detail = Loc.s("Bật quyền Mạng cục bộ cho PanicAnalyzer trong Cài đặt iOS.",
                                   "Allow Local Network for PanicAnalyzer in iOS Settings.",
                                   "请在 iOS 设置中为 PanicAnalyzer 开启本地网络权限。")
                }
                // Stay alive while permission is granted or the VPN route comes up.
            case .failed(let error):
                detail = error.localizedDescription
                refused = isRefused(error)
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { finish(false) }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        done.wait()
        deadline.cancel()
        let result = queue.sync { (succeeded, detail, refused) }
        guard result.0 else {
            if result.2 {
                throw ConnectionError(
                    message: Loc.s("LocalDevVPN đã chạy nhưng cổng RemotePairing \(address):\(port) đang đóng. \(result.1)",
                                   "LocalDevVPN is running but RemotePairing port \(address):\(port) is closed. \(result.1)",
                                   "LocalDevVPN 已运行，但 RemotePairing 端口 \(address):\(port) 已关闭。\(result.1)"),
                    refused: true
                )
            }
            throw ConnectionError(message: Loc.s(
                "Không kết nối được LocalDevVPN tại \(address):\(port). "
                    + "Bật hoặc kết nối lại LocalDevVPN (Device IP mặc định 10.7.0.1) và kiểm tra quyền "
                    + "Mạng cục bộ của PanicAnalyzer. \(result.1)",
                "Cannot reach LocalDevVPN at \(address):\(port). "
                    + "Turn on or reconnect LocalDevVPN (default Device IP 10.7.0.1) and check PanicAnalyzer's "
                    + "Local Network permission. \(result.1)",
                "无法连接 \(address):\(port) 上的 LocalDevVPN。"
                    + "请打开或重新连接 LocalDevVPN（默认 Device IP 10.7.0.1），并检查 PanicAnalyzer 的"
                    + "本地网络权限。\(result.1)"))
        }
    }

    /// Non-blocking BSD connect with a deadline. Returns 0 on success or an errno.
    static func quickConnect(address: String, port: UInt16, timeout: TimeInterval) -> Int32 {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else { return EINVAL }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let result = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return 0 }
        guard errno == EINPROGRESS else { return errno }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&descriptor, 1, Int32(max(1, timeout * 1000)))
        guard ready > 0 else { return ETIMEDOUT }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return errno }
        return socketError
    }

    // MARK: - Bonjour discovery

    /// Browses `_remotepairing._tcp` and returns advertised ports, the device's
    /// own (loopback) advertisement first. Other iPhones on the same Wi-Fi may
    /// advertise too, so callers must probe each port against the VPN address.
    /// Requires `_remotepairing._tcp` in NSBonjourServices.
    static func discoverRemotePairingPorts(timeout: TimeInterval) -> [UInt16] {
        precondition(!Thread.isMainThread, "Bonjour discovery must not block the UI")
        let queue = DispatchQueue(label: "com.iosvn.panicanalyzer.rp-discovery")
        let done = DispatchSemaphore(value: 0)
        let browser = NWBrowser(
            for: .bonjour(type: remotePairingServiceType, domain: nil),
            using: .tcp
        )
        // All state below is confined to queue.
        var finished = false
        var loopbackPorts: [UInt16] = []
        var otherPorts: [UInt16] = []
        var resolvers: [NWEndpoint: NWConnection] = [:]

        func finish() {
            guard !finished else { return }
            finished = true
            browser.browseResultsChangedHandler = nil
            browser.stateUpdateHandler = nil
            browser.cancel()
            for connection in resolvers.values {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            done.signal()
        }
        func isLoopback(_ result: NWBrowser.Result) -> Bool {
            result.interfaces.contains { $0.type == .loopback || $0.name.hasPrefix("lo") }
        }
        func record(_ port: UInt16, loopback: Bool) {
            guard !finished, port > 0 else { return }
            if loopback {
                if !loopbackPorts.contains(port) { loopbackPorts.append(port) }
                finish() // Our own device's service: nothing better to wait for.
            } else if !otherPorts.contains(port) {
                otherPorts.append(port)
            }
        }
        func resolve(_ result: NWBrowser.Result) {
            guard !finished, resolvers[result.endpoint] == nil else { return }
            let loopback = isLoopback(result)
            // Resolving a service endpoint through NWConnection yields its host:port.
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            resolvers[result.endpoint] = connection
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .waiting:
                    if case .hostPort(_, let port)? = connection.currentPath?.remoteEndpoint {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        record(port.rawValue, loopback: loopback)
                    }
                case .failed:
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        browser.stateUpdateHandler = { state in
            // .failed covers missing NSBonjourServices entry or denied Local Network.
            if case .failed = state { finish() }
        }
        browser.browseResultsChangedHandler = { results, _ in
            let all = Array(results)
            let ordered = all.filter { isLoopback($0) } + all.filter { !isLoopback($0) }
            ordered.forEach(resolve)
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish() }
        done.wait()
        return queue.sync { loopbackPorts + otherPorts }
    }
}
