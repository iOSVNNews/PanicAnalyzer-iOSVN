//  PairingLogService.swift
//  Read-only access to Apple's CrashReporter AFC view over LocalDevVPN + RSD.

import Foundation
import PanicPairingFFI

final class PairingLogService {

    static let shared = PairingLogService()

    private let maxFiles = 100
    private let maxFileBytes = 12 * 1024 * 1024
    private let maxTotalBytes = 24 * 1024 * 1024
    private let maxEntries = 1_500
    private let operationLock = NSLock()

    enum PairingError: LocalizedError {
        case missingFile
        case notPaired
        case invalidFile(String)
        case bridge(String)

        var errorDescription: String? {
            switch self {
            case .missingFile:
                return "Thiết bị này chưa hỗ trợ tự ghép đôi. Hãy dùng Share Sheet hoặc nhập pairing file."
            case .notPaired:
                return "Chưa ghép đôi. Bấm \"Ghép đôi thiết bị này\", rồi vào Cài đặt > Quyền riêng tư & Bảo mật > "
                    + "Nhà phát triển, chọn \(PairableHostService.hostName) và nhập mã PIN app hiển thị."
            case .invalidFile(let detail):
                return "Remote Pairing file không hợp lệ: \(detail)"
            case .bridge(let detail):
                return detail
            }
        }
    }

    private var pairingDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Pairing", isDirectory: true)
    }

    private var pairingFileURL: URL? {
        pairingDirectory?.appendingPathComponent("rp_pairing_file.plist")
    }

    private var workingPairingFileURL: URL? {
        pairingDirectory?.appendingPathComponent(".rp_pairing_working.plist")
    }

    /// Classic lockdown pair record for the CoreDeviceProxy route: imported
    /// from a computer-made pairing file or minted on-device.
    private var lockdownRecordURL: URL? {
        pairingDirectory?.appendingPathComponent("lockdown_pair_record.plist")
    }

    private var hasRemotePairingRecord: Bool {
        pairingFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private var hasLockdownRecord: Bool {
        lockdownRecordURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Stable lockdown host identity, so a minted record keeps matching.
    private static func storedIdentifier(_ key: String) -> String {
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty { return value }
        let value = UUID().uuidString.uppercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    /// iOS 27 can complete Remote Pairing on-device through LocalDevVPN.
    var supportsOnDevicePairing: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    var isConfigured: Bool {
        hasRemotePairingRecord || hasLockdownRecord
    }

    /// Copies only the credential bytes into Application Support. The file is
    /// excluded from backup and protected while the device is locked.
    func importPairingFile(from source: URL) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= 1024 * 1024 else {
            throw PairingError.invalidFile("file lớn hơn 1 MB")
        }
        guard let directory = pairingDirectory,
              let destination = isRemotePairingPlist(data) ? pairingFileURL : lockdownRecordURL else {
            throw PairingError.invalidFile("không mở được Application Support")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let staging = directory.appendingPathComponent(".pairing-import-\(UUID().uuidString).plist")
        try data.write(to: staging, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            try staging.path.withCString { path in
                if destination == pairingFileURL {
                    try check(pa_pairing_validate(path))
                } else {
                    do {
                        try check(pa_lockdown_validate(path))
                    } catch {
                        throw PairingError.invalidFile(
                            "không phải Remote Pairing record (public_key/private_key/identifier) "
                                + "cũng không phải lockdown pairing file (HostID, certificates…)"
                        )
                    }
                }
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try mutableDestination.setResourceValues(values)

    }

    private var activeHost: PairableHostService?

    /// iOS 27: advertise this app as a pairable host and wait until the user
    /// pairs it from Settings > Privacy & Security > Developer. Blocks; call
    /// from a worker queue. The previous record stays until the new one is saved.
    func pairOnDevice(timeout: TimeInterval = 300,
                      onAdvertising: @escaping () -> Void,
                      onPin: @escaping (String) -> Void) throws {
        guard supportsOnDevicePairing else { throw PairingError.missingFile }
        guard let directory = pairingDirectory, let working = workingPairingFileURL else {
            throw PairingError.invalidFile("không mở được Application Support")
        }
        let host = PairableHostService()
        operationLock.lock()
        activeHost = host
        defer {
            activeHost = nil
            operationLock.unlock()
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try? FileManager.default.removeItem(at: working)
        defer { try? FileManager.default.removeItem(at: working) }
        try host.pair(pairingPath: working, timeout: timeout, onAdvertising: onAdvertising, onPin: onPin)
        guard nativePairingFileIsValid(working) else {
            throw PairingError.invalidFile("iOS trả về pairing record không đọc được")
        }
        try promoteWorkingPairingFile(working)
        // A new pairing may come with a restarted remotepairingd: rediscover.
        LocalVPNConnection.forgetWorkingPort()
    }

    /// Stops a pairing wait started by pairOnDevice (e.g. the user tapped Huỷ).
    func cancelPairing() {
        activeHost?.cancel()
    }

    func removePairingFile() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        for url in [pairingFileURL, workingPairingFileURL, lockdownRecordURL].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// The remote service exposes CrashReporter as a virtual AFC root. It does
    /// not grant arbitrary access to /var or even all of Library/Logs.
    func scanLogs() throws -> [[String: String]] {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard isConfigured else {
            throw supportsOnDevicePairing ? PairingError.notPaired : PairingError.missingFile
        }
        let deviceIP = LocalVPNConnection.deviceAddress

        var session: OpaquePointer?
        var remoteError: Error?
        if hasRemotePairingRecord {
            do {
                session = try openRemotePairingSession(deviceIP: deviceIP)
            } catch {
                remoteError = error
                // The VPN itself is down: the lockdown route needs it as well.
                if let vpn = error as? LocalVPNConnection.ConnectionError, !vpn.refused { throw error }
            }
        }
        if session == nil {
            do {
                session = try openLockdownSession(deviceIP: deviceIP)
            } catch {
                guard let remoteError else { throw error }
                throw PairingError.bridge(remoteError.localizedDescription
                    + "\n\nĐường dự phòng CoreDeviceProxy cũng lỗi: " + error.localizedDescription)
            }
        }
        guard let session else {
            throw PairingError.bridge("RSD tunnel không trả về phiên làm việc hợp lệ.")
        }
        defer { pa_session_free(session) }

        struct PendingDirectory {
            let path: String
            let depth: Int
        }

        var pending = [PendingDirectory(path: "", depth: 0)]
        var visited = Set<String>()
        var results: [[String: String]] = []
        var totalBytes = 0
        var entryCount = 0

        while !pending.isEmpty,
              results.count < maxFiles,
              totalBytes < maxTotalBytes,
              entryCount < maxEntries {
            let directory = pending.removeFirst()
            guard visited.insert(directory.path).inserted else { continue }

            let entries: [String]
            do {
                entries = try list(session: session, directory: directory.path)
            } catch {
                if directory.depth == 0 { throw error }
                continue
            }
            entryCount += entries.count

            for entry in entries {
                guard entry != ".", entry != "..", !entry.contains("/") else { continue }
                let path = directory.path.isEmpty ? entry : "\(directory.path)/\(entry)"
                if isLogFile(entry) {
                    guard results.count < maxFiles, totalBytes < maxTotalBytes else { break }
                    guard let data = try? pull(session: session, path: path),
                          !data.isEmpty,
                          data.count <= maxFileBytes,
                          totalBytes + data.count <= maxTotalBytes else { continue }
                    totalBytes += data.count
                    results.append([
                        "name": path,
                        "content": String(decoding: data, as: UTF8.self)
                    ])
                } else if directory.depth < 3 {
                    pending.append(PendingDirectory(path: path, depth: directory.depth + 1))
                }
            }
        }
        return results
    }

    /// Route 1 (iOS 27 record from Settings > Developer): RPPairing tunnel.
    private func openRemotePairingSession(deviceIP: String) throws -> OpaquePointer {
        var port = try LocalVPNConnection.remotePairingPort(address: deviceIP)
        let pairingURL = try prepareWorkingPairingFile()
        defer { try? FileManager.default.removeItem(at: pairingURL) }

        var session: OpaquePointer?
        do {
            do {
                try connect(pairingURL: pairingURL, deviceIP: deviceIP, port: port, session: &session)
            } catch let error as PairingError where Self.isRefusedBeforePairing(error) {
                // remotepairingd moved between the probe and the real connection
                // (daemon restart). Nothing was sent yet, so one retry on a freshly
                // discovered port cannot repeat a consent prompt.
                LocalVPNConnection.forgetWorkingPort()
                guard LocalVPNConnection.portOverride == nil else { throw error }
                port = try LocalVPNConnection.resolvePort(
                    address: deviceIP, manualPort: nil, cachedPort: nil, excluding: [port]
                )
                LocalVPNConnection.rememberWorkingPort(port)
                try connect(pairingURL: pairingURL, deviceIP: deviceIP, port: port, session: &session)
            }
        } catch {
            // Pair-verify may have refreshed the record before a later step
            // failed. Preserve only a record the native bridge can parse.
            if FileManager.default.fileExists(atPath: pairingURL.path),
               nativePairingFileIsValid(pairingURL) {
                try? promoteWorkingPairingFile(pairingURL)
            }
            throw error
        }
        guard let session else {
            throw PairingError.bridge("RSD tunnel không trả về phiên làm việc hợp lệ.")
        }
        try? promoteWorkingPairingFile(pairingURL)
        return session
    }

    /// Route 2 (learned from SideInstaller): CoreDeviceProxy over a lockdown
    /// session on 62078. Needs no inbound tunnel listener, which on-device
    /// RPPairing lacks. Uses the stored/imported classic record, otherwise asks
    /// lockdownd for one (iOS shows "Tin cậy máy tính này?").
    private func openLockdownSession(deviceIP: String) throws -> OpaquePointer {
        guard let directory = pairingDirectory, let recordURL = lockdownRecordURL else {
            throw PairingError.invalidFile("không mở được Application Support")
        }
        var lastError: Error?
        if hasLockdownRecord {
            do {
                return try connectLockdown(recordURL: recordURL, deviceIP: deviceIP)
            } catch {
                lastError = error
            }
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let staging = directory.appendingPathComponent(".lockdown-mint.plist")
        defer { try? FileManager.default.removeItem(at: staging) }
        let hostID = Self.storedIdentifier("lockdownHostID")
        let systemBUID = Self.storedIdentifier("lockdownSystemBUID")
        var minted = false
        for host in [deviceIP, "127.0.0.1"] where !minted {
            do {
                try host.withCString { ip in
                    try hostID.withCString { h in
                        try systemBUID.withCString { b in
                            try staging.path.withCString { out in
                                try check(pa_lockdown_mint(ip, h, b, out))
                            }
                        }
                    }
                }
                minted = true
            } catch {
                lastError = error
            }
        }
        guard minted else {
            throw lastError ?? PairingError.bridge("Không tạo được lockdown pair record.")
        }
        if FileManager.default.fileExists(atPath: recordURL.path) {
            _ = try FileManager.default.replaceItemAt(recordURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: recordURL)
        }
        try protect(recordURL)
        return try connectLockdown(recordURL: recordURL, deviceIP: deviceIP)
    }

    private func connectLockdown(recordURL: URL, deviceIP: String) throws -> OpaquePointer {
        var opened: OpaquePointer?
        try recordURL.path.withCString { path in
            try deviceIP.withCString { ip in
                try check(pa_session_connect_lockdown(path, ip, &opened))
            }
        }
        guard let opened else {
            throw PairingError.bridge("CoreDeviceProxy không trả về phiên làm việc hợp lệ.")
        }
        return opened
    }

    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }

    private func connect(pairingURL: URL, deviceIP: String, port: UInt16,
                         session: inout OpaquePointer?) throws {
        var opened: OpaquePointer?
        try pairingURL.path.withCString { pairingPath in
            try deviceIP.withCString { ip in
                try check(pa_session_connect(pairingPath, ip, port, &opened))
            }
        }
        session = opened
    }

    /// The Rust bridge reports the initial TCP connect as "connect: …". A refusal
    /// there happens before any pairing message is exchanged.
    static func isRefusedBeforePairing(_ error: PairingError) -> Bool {
        guard case .bridge(let message) = error else { return false }
        let lower = message.lowercased()
        return lower.contains("connect:")
            && (lower.contains("connection refused") || lower.contains("os error 61"))
    }

    /// Uses a staging file so an interrupted first pairing never replaces the
    /// last working credential. The Rust bridge creates the record itself when
    /// the staging path does not exist.
    private func prepareWorkingPairingFile() throws -> URL {
        guard let directory = pairingDirectory,
              let destination = pairingFileURL,
              let working = workingPairingFileURL else {
            throw PairingError.invalidFile("không mở được Application Support")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try? FileManager.default.removeItem(at: working)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: destination, to: working)
        }
        return working
    }

    private func promoteWorkingPairingFile(_ working: URL) throws {
        guard let destination = pairingFileURL,
              FileManager.default.fileExists(atPath: working.path) else {
            throw PairingError.invalidFile("pairing record chưa được tạo")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: working)
        } else {
            try FileManager.default.moveItem(at: working, to: destination)
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try mutableDestination.setResourceValues(values)
    }

    private func nativePairingFileIsValid(_ url: URL) -> Bool {
        let error = url.path.withCString { pa_pairing_validate($0) }
        guard let error else { return true }
        pa_error_free(error)
        return false
    }

    private func isRemotePairingPlist(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            return false
        }
        return true
    }

    private func list(session: OpaquePointer, directory: String) throws -> [String] {
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        let error: UnsafeMutablePointer<CChar>?
        if directory.isEmpty {
            error = pa_session_list(session, nil, &entries, &count)
        } else {
            error = ("/" + directory).withCString {
                pa_session_list(session, $0, &entries, &count)
            }
        }
        try check(error)
        guard let entries else { return [] }
        defer { pa_string_array_free(entries, count) }
        return (0..<count).compactMap { index in
            entries[index].flatMap { String(validatingUTF8: $0) }
        }
    }

    private func pull(session: OpaquePointer, path: String) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        try path.withCString {
            try check(pa_session_pull(session, $0, &bytes, &length))
        }
        guard let bytes, length > 0 else { return Data() }
        defer { pa_bytes_free(bytes, length) }
        return Data(bytes: bytes, count: length)
    }

    private func check(_ error: UnsafeMutablePointer<CChar>?) throws {
        guard let error else { return }
        let message = String(validatingUTF8: error) ?? "Lỗi pairing không xác định"
        pa_error_free(error)
        throw PairingError.bridge(message)
    }

    private func isLogFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".ips") || lower.hasSuffix(".crash")
            || lower.hasSuffix(".panic") || lower.hasSuffix(".synced")
            || lower.contains("panic-full") || lower.contains("watchdog")
    }
}
