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

    static var deviceAddress: String {
        (try? normalizedAddress(UserDefaults.standard.string(forKey: addressKey) ?? defaultAddress))
            ?? defaultAddress
    }

    static func saveDeviceAddress(_ input: String) throws {
        UserDefaults.standard.set(try normalizedAddress(input), forKey: addressKey)
    }

    /// Port typed by the user in "Cấu hình LocalDevVPN"; nil means auto-detect.
    static var portOverride: UInt16? {
        storedPort(forKey: portOverrideKey)
    }

    /// Port that worked last time (found by Bonjour or the default).
    static var lastWorkingPort: UInt16? {
        storedPort(forKey: lastPortKey)
    }

    static func savePortOverride(_ input: String) throws {
        if let port = try normalizedPort(input) {
            UserDefaults.standard.set(Int(port), forKey: portOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: portOverrideKey)
        }
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
            throw ConnectionError(message: "Device IP không hợp lệ. Ví dụ: 10.7.0.1 hoặc 10.7.0.1/32.")
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" }
                  && UInt8($0) != nil }),
              let first = UInt8(octets[0]), first > 0, first < 224,
              first != 127 else {
            throw ConnectionError(message: "Hãy nhập IPv4 ở mục Device IP của LocalDevVPN, không phải Tunnel IP.")
        }
        return octets.map { String(UInt8($0)!) }.joined(separator: ".")
    }

    /// Empty input means "auto-detect" and returns nil.
    static func normalizedPort(_ input: String) throws -> UInt16? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(trimmed), (1...65535).contains(value) else {
            throw ConnectionError(message: "Cổng RemotePairing không hợp lệ. Để trống để app tự dò, hoặc nhập số như 49152.")
        }
        return UInt16(value)
    }

    // MARK: - Endpoint resolution

    /// Finds a RemotePairing port that accepts TCP at `address`, using the saved
    /// override, then the last working port, then Bonjour discovery.
    static func remotePairingPort(address: String) throws -> UInt16 {
        let port = try resolvePort(
            address: address,
            manualPort: portOverride,
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
            message: "LocalDevVPN đã chạy nhưng dịch vụ RemotePairing của iOS không mở tại \(address) "
                + "(đã thử cổng \(triedPorts)) và không dò được cổng qua Bonjour \(remotePairingServiceType). "
                + "Hãy tắt rồi bật lại LocalDevVPN, bật Wi-Fi, cho phép quyền Mạng cục bộ, rồi thử lại. "
                + "Nếu biết cổng, nhập nó trong Cấu hình LocalDevVPN."
                + (lastError.map { " (\($0.localizedDescription))" } ?? ""),
            refused: true
        )
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
            throw ConnectionError(message: "Cổng LocalDevVPN không hợp lệ.")
        }
        let queue = DispatchQueue(label: "com.iosvn.panicanalyzer.vpn-probe")
        let done = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        // All result state is confined to queue; read it with queue.sync below.
        var finished = false
        var succeeded = false
        var refused = false
        var detail = "Kết nối quá thời gian."
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
                    detail = "Bật quyền Mạng cục bộ cho PanicAnalyzer trong Cài đặt iOS."
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
                    message: "LocalDevVPN đã chạy nhưng cổng RemotePairing \(address):\(port) đang đóng. \(result.1)",
                    refused: true
                )
            }
            throw ConnectionError(message: "Không kết nối được LocalDevVPN tại \(address):\(port). "
                + "Bật hoặc kết nối lại LocalDevVPN, kiểm tra quyền Mạng cục bộ và vào Cấu hình LocalDevVPN "
                + "để nhập đúng Device IP (không phải Tunnel IP). \(result.1)")
        }
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
