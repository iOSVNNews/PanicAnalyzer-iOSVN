import Foundation
import Network
import Darwin

// Run on macOS CI with the same Network.framework transport used by the app.
@main
struct LocalVPNConnectionTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func run() throws {
        for (input, expected) in [
            ("10.7.0.1", "10.7.0.1"),
            (" 10.7.0.1/32\n", "10.7.0.1"),
            ("10.7.1.2/24", "10.7.1.2"),
            ("192.168.4.9", "192.168.4.9")
        ] {
            let actual = try LocalVPNConnection.normalizedAddress(input)
            expect(actual == expected, "CIDR/address normalization: \(input)")
        }
        for input in ["", "10.7.0", "10.7.0.999", "10.7.0.1/33", "10.7.0.1/",
                      "10.7.0.1/32/32", "10.7.0.1:49152", "localhost", "::1",
                      "127.0.0.1", "0.0.0.0", "255.255.255.255", "224.0.0.1",
                      "10.7.0.-1", "10.7.0.+1"] {
            do {
                _ = try LocalVPNConnection.normalizedAddress(input)
                preconditionFailure("Accepted invalid endpoint: \(input)")
            } catch is LocalVPNConnection.ConnectionError {}
        }

        var attempts = 0
        try LocalVPNConnection.waitUntilReachable(address: "10.7.1.2") { address, port, timeout in
            attempts += 1
            expect(address == "10.7.1.2" && port == 49152, "Probe must use the configured Device IP")
            expect(timeout == 10, "First attempt must allow time for network permission")
        }
        expect(attempts == 1, "Reachable endpoint should not be retried")

        attempts = 0
        try LocalVPNConnection.waitUntilReachable(address: "10.7.0.1") { _, _, timeout in
            attempts += 1
            if attempts == 1 { throw LocalVPNConnection.ConnectionError(message: "route starting") }
            expect(timeout == 4, "Retry must be bounded")
        }
        expect(attempts == 2, "VPN startup failure should retry once")

        attempts = 0
        do {
            try LocalVPNConnection.waitUntilReachable(address: "10.7.0.1") { _, _, _ in
                attempts += 1
                throw LocalVPNConnection.ConnectionError(message: "offline")
            }
            preconditionFailure("An offline endpoint must not proceed to pairing")
        } catch {
            expect(error.localizedDescription == "offline", "Keep the final connection error")
            expect(attempts == 2, "An offline VPN must not cause infinite retries")
        }

        // A refused port is a definite answer: no blind retry on the same port.
        attempts = 0
        do {
            try LocalVPNConnection.waitUntilReachable(address: "10.7.0.1") { _, _, _ in
                attempts += 1
                throw LocalVPNConnection.ConnectionError(message: "refused", refused: true)
            }
            preconditionFailure("A refused port must not proceed")
        } catch {
            expect(attempts == 1, "Refused port must not be retried")
        }

        for (input, expected) in [("", nil), ("  ", nil), ("49152", UInt16(49152)), (" 62078 ", UInt16(62078))] as [(String, UInt16?)] {
            let actual = try LocalVPNConnection.normalizedPort(input)
            expect(actual == expected, "Port parsing: \(input)")
        }
        for input in ["0", "65536", "-1", "49a", "49152.0", "+49152"] {
            do {
                _ = try LocalVPNConnection.normalizedPort(input)
                preconditionFailure("Accepted invalid port: \(input)")
            } catch is LocalVPNConnection.ConnectionError {}
        }

        // Stale 49152 (refused) -> Bonjour port is probed and used.
        var probed: [UInt16] = []
        var discoveries = 0
        let found = try LocalVPNConnection.resolvePort(
            address: "10.7.0.1", manualPort: nil, cachedPort: nil,
            probe: { _, port, _ in
                probed.append(port)
                if port != 49155 { throw LocalVPNConnection.ConnectionError(message: "closed", refused: true) }
            },
            discover: { _ in discoveries += 1; return [49152, 50001, 49155] }
        )
        expect(found == 49155, "Must use the discovered port that accepts TCP")
        expect(probed == [49152, 50001, 49155], "Must skip already-tried ports and probe candidates in order: \(probed)")
        expect(discoveries == 1, "Discovery must run once")

        // Working cached port: no discovery.
        discoveries = 0
        let cached = try LocalVPNConnection.resolvePort(
            address: "10.7.0.1", manualPort: nil, cachedPort: 49160,
            probe: { _, port, _ in expect(port == 49160, "Cached port first") },
            discover: { _ in discoveries += 1; return [] }
        )
        expect(cached == 49160 && discoveries == 0, "Cached port must avoid Bonjour")

        // VPN down (timeout, not refused): fail fast, no discovery.
        discoveries = 0
        do {
            _ = try LocalVPNConnection.resolvePort(
                address: "10.7.0.1", manualPort: nil, cachedPort: nil,
                probe: { _, _, _ in throw LocalVPNConnection.ConnectionError(message: "timeout Device IP") },
                discover: { _ in discoveries += 1; return [49153] }
            )
            preconditionFailure("Offline VPN must fail")
        } catch {
            expect(discoveries == 0, "Discovery cannot help an offline VPN")
            expect(error.localizedDescription.contains("Device IP"), "Offline error keeps VPN instructions")
        }

        // Manual port is authoritative.
        let manual = try LocalVPNConnection.resolvePort(
            address: "10.7.0.1", manualPort: 50123, cachedPort: 49152,
            probe: { _, port, _ in expect(port == 50123, "Manual port only") },
            discover: { _ -> [UInt16] in preconditionFailure("Manual port must not trigger discovery") }
        )
        expect(manual == 50123, "Manual port returned")

        // Refused everywhere: clear message naming the tried ports.
        do {
            _ = try LocalVPNConnection.resolvePort(
                address: "10.7.0.1", manualPort: nil, cachedPort: nil,
                probe: { _, _, _ in throw LocalVPNConnection.ConnectionError(message: "closed", refused: true) },
                discover: { _ in [] }
            )
            preconditionFailure("No open port must fail")
        } catch let error as LocalVPNConnection.ConnectionError {
            expect(error.refused, "Keep refused classification")
            expect(error.message.contains("49152") && error.message.contains("_remotepairing._tcp"),
                   "Message must name tried port and service")
        }

        // Retry path excludes the port that just refused.
        let retry = try LocalVPNConnection.resolvePort(
            address: "10.7.0.1", manualPort: nil, cachedPort: nil, excluding: [49152],
            probe: { _, port, _ in expect(port == 49153, "Excluded port must not be probed") },
            discover: { _ in [49152, 49153] }
        )
        expect(retry == 49153, "Retry must pick a new port")

        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        let listenerQueue = DispatchQueue(label: "vpn-test-listener")
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: listenerQueue)
        defer { listener.cancel() }
        expect(ready.wait(timeout: .now() + 5) == .success, "TCP test listener did not start")
        let port = listenerQueue.sync { listener.port!.rawValue }
        try LocalVPNConnection.probe(address: "127.0.0.1", port: port, timeout: 2)

        // Reserve a local port without listening: deterministic refusal, no VPN/device needed.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        expect(fd >= 0, "Could not allocate refused-port fixture")
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        expect(bound == 0, "Could not bind refused-port fixture")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        expect(named == 0, "Could not find fixture port")
        let refusedPort = UInt16(bigEndian: address.sin_port)
        let start = Date()
        do {
            try LocalVPNConnection.probe(address: "127.0.0.1", port: refusedPort, timeout: 3)
            preconditionFailure("A closed port must not count as connected")
        } catch {
            expect(error.localizedDescription.contains("127.0.0.1:\(refusedPort)"), "Error must identify failed endpoint")
            expect((error as? LocalVPNConnection.ConnectionError)?.refused == true,
                   "A closed port must be classified as refused, not as VPN offline")
            expect(Date().timeIntervalSince(start) < 2, "A refused port must fail immediately, not wait for the deadline")
        }
        print("LocalVPNConnection: endpoint validation, port discovery, retry, TCP readiness and failure tests passed")
    }

    static func main() {
        DispatchQueue.global().async {
            do {
                try run()
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }
}
