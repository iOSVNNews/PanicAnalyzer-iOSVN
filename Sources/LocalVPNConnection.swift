import Foundation
import Network

/// Checks the actual device endpoint before creating or replacing pairing keys.
/// Call the blocking network methods from a worker queue, never the main queue.
enum LocalVPNConnection {
    static let defaultAddress = "10.7.0.1"
    static let defaultPort: UInt16 = 49152
    private static let addressKey = "localVPNDeviceAddress"

    struct ConnectionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var deviceAddress: String {
        (try? normalizedAddress(UserDefaults.standard.string(forKey: addressKey) ?? defaultAddress))
            ?? defaultAddress
    }

    static func saveDeviceAddress(_ input: String) throws {
        UserDefaults.standard.set(try normalizedAddress(input), forKey: addressKey)
    }

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

    static func waitUntilReachable(address: String, port: UInt16 = defaultPort,
                                   probe: (String, UInt16, TimeInterval) throws -> Void = LocalVPNConnection.probe) throws {
        // The first attempt also gives iOS time to show the Local Network prompt.
        // Retry only TCP readiness; never repeat a failed pairing/consent exchange.
        do {
            try probe(address, port, 10)
        } catch {
            Thread.sleep(forTimeInterval: 0.5)
            try probe(address, port, 4)
        }
    }

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
        var detail = "Kết nối quá thời gian."
        func finish(_ success: Bool) {
            guard !finished else { return }
            finished = true
            succeeded = success
            connection.stateUpdateHandler = nil
            connection.cancel()
            done.signal()
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .waiting(let error):
                detail = error.localizedDescription
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    detail = "Bật quyền Mạng cục bộ cho PanicAnalyzer trong Cài đặt iOS."
                }
                // Stay alive while permission is granted or the VPN route comes up.
            case .failed(let error):
                detail = error.localizedDescription
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
        let result = queue.sync { (succeeded, detail) }
        guard result.0 else {
            throw ConnectionError(message: "Không kết nối được LocalDevVPN tại \(address):\(port). "
                + "Bật hoặc kết nối lại LocalDevVPN, kiểm tra quyền Mạng cục bộ và vào Cấu hình LocalDevVPN "
                + "để nhập đúng Device IP (không phải Tunnel IP). \(result.1)")
        }
    }
}
