//  PairableHostService.swift
//  iOS 27 device-initiated Remote Pairing, entirely on the iPhone.
//
//  The app advertises itself as a "pairable host" (`_remotepairing-pairable-host._tcp`).
//  The user opens Settings > Privacy & Security > Developer, picks PanicAnalyzer and
//  types the 6-digit PIN the app shows. iOS then connects to our listening socket and
//  runs pair-setup; the resulting record later opens the RSD tunnel over LocalDevVPN.

import Foundation
import Darwin
import PanicPairingFFI

/// Carries the Swift PIN handler through the C callback's context pointer.
private final class PinBox {
    let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
}

final class PairableHostService: NSObject {

    static let serviceType = "_remotepairing-pairable-host._tcp."
    static let hostName = "PanicAnalyzer"

    struct HostError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let stateLock = NSLock()
    private var cancelled = false
    private var netService: NetService?

    func cancel() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    /// Blocks the calling (worker) thread until iOS pairs, the user cancels or the
    /// timeout expires. The pairing record is written to `pairingPath`.
    func pair(pairingPath: URL,
              timeout: TimeInterval,
              onAdvertising: @escaping () -> Void,
              onPin: @escaping (String) -> Void) throws {
        precondition(!Thread.isMainThread, "Pairing must not block the UI")

        var host: OpaquePointer?
        var serviceC: UnsafeMutablePointer<CChar>?
        var txtBytes: UnsafeMutablePointer<UInt8>?
        var txtLength = 0
        try Self.hostName.withCString { name in
            try check(pa_host_prepare(name, &host, &serviceC, &txtBytes, &txtLength))
        }
        guard let host, let serviceC else {
            throw HostError(message: "Không tạo được danh tính máy chủ ghép đôi.")
        }
        defer { pa_host_free(host) }
        let serviceID = String(cString: serviceC)
        pa_error_free(serviceC)

        var txt: [String: Data] = [:]
        if let txtBytes, txtLength > 0 {
            let data = Data(bytes: txtBytes, count: txtLength)
            pa_bytes_free(txtBytes, txtLength)
            if let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] {
                for (key, value) in dict { txt[key] = Data(value.utf8) }
            }
        }
        guard !txt.isEmpty else { throw HostError(message: "Thiếu thông tin Bonjour của máy chủ ghép đôi.") }

        let listener = try Self.listen()
        defer { close(listener.fd) }

        DispatchQueue.main.sync { self.publish(serviceID: serviceID, port: listener.port, txt: txt) }
        defer { DispatchQueue.main.sync { self.unpublish() } }
        onAdvertising()

        let client = try waitForConnection(listener.fd, timeout: timeout)
        defer { close(client) }

        let box = Unmanaged.passRetained(PinBox(onPin))
        defer { box.release() }

        try pairingPath.path.withCString { path in
            try check(pa_host_accept(host, client, { pin, context in
                guard let pin, let context else { return }
                Unmanaged<PinBox>.fromOpaque(context).takeUnretainedValue().handler(String(cString: pin))
            }, box.toOpaque(), path))
        }
    }

    // MARK: - Bonjour (system mDNSResponder; apps may not send raw multicast)

    private func publish(serviceID: String, port: UInt16, txt: [String: Data]) {
        unpublish()
        let service = NetService(domain: "local.", type: Self.serviceType, name: serviceID, port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
    }

    private func unpublish() {
        netService?.stop()
        netService = nil
    }

    // MARK: - Sockets

    private static func listen() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        address.sin_len = UInt8(length)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 }
        }
        guard bound, Darwin.listen(fd, 4) == 0 else {
            let error = posixError("bind/listen")
            close(fd)
            throw error
        }
        var named = length
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &named) == 0 }
        }
        guard ok else {
            let error = posixError("getsockname")
            close(fd)
            throw error
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private func waitForConnection(_ listener: Int32, timeout: TimeInterval) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCancelled { throw HostError(message: "Đã huỷ ghép đôi.") }
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 500)
            if ready < 0 && errno != EINTR { throw Self.posixError("poll") }
            guard ready > 0 else { continue }
            let client = accept(listener, nil, nil)
            if client >= 0 { return client }
            if errno != EINTR && errno != EAGAIN { throw Self.posixError("accept") }
        }
        throw HostError(message: "Hết thời gian chờ. Trong Cài đặt > Quyền riêng tư & Bảo mật > Nhà phát triển "
            + "chưa có ai chọn \(Self.hostName). Bật Chế độ nhà phát triển và LocalDevVPN rồi thử lại.")
    }

    private static func posixError(_ call: String) -> HostError {
        HostError(message: "\(call) lỗi: \(String(cString: strerror(errno)))")
    }

    private func check(_ error: UnsafeMutablePointer<CChar>?) throws {
        guard let error else { return }
        let message = String(validatingUTF8: error) ?? "Lỗi ghép đôi không xác định"
        pa_error_free(error)
        throw HostError(message: message)
    }
}
