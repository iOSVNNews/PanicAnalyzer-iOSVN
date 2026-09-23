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
            try LocalVPNConnection.probe(address: "127.0.0.1", port: refusedPort, timeout: 0.2)
            preconditionFailure("A closed port must not count as connected")
        } catch {
            expect(error.localizedDescription.contains("127.0.0.1:\(refusedPort)"), "Error must identify failed endpoint")
            expect(error.localizedDescription.contains("Device IP"), "Error must include recovery instructions")
            expect(Date().timeIntervalSince(start) < 2, "TCP failure exceeded its deadline")
        }
        print("LocalVPNConnection: endpoint validation, retry, TCP readiness and failure tests passed")
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
