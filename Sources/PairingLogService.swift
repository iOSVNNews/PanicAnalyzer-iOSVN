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
                return Loc.s("Thiết bị này chưa hỗ trợ tự ghép đôi. Hãy dùng Share Sheet hoặc nhập pairing file trong Cài đặt của app.",
                             "This device can't pair itself. Use the Share Sheet or import a pairing file in the app's Settings.",
                             "此设备不支持自行配对。请使用共享或在应用设置中导入配对文件。")
            case .notPaired:
                return Loc.s(
                    "Chưa ghép đôi. Bấm \"Ghép đôi thiết bị này\", rồi vào Cài đặt > Quyền riêng tư & Bảo mật > "
                        + "Nhà phát triển, chọn \(PairableHostService.hostName) và nhập mã PIN app hiển thị.",
                    "Not paired yet. Tap \"Pair this device\", then go to Settings > Privacy & Security > "
                        + "Developer, pick \(PairableHostService.hostName) and enter the PIN the app shows.",
                    "尚未配对。点「配对本机」，然后前往 设置 > 隐私与安全性 > 开发者，"
                        + "选择 \(PairableHostService.hostName) 并输入应用显示的 PIN 码。")
            case .invalidFile(let detail):
                return Loc.s("Pairing file không hợp lệ: \(detail)", "Invalid pairing file: \(detail)", "配对文件无效：\(detail)")
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

    /// What an import stored. iLoader (iOS 17.4+) exports ONE plist holding both
    /// the lockdown record (HostID, certificates…) and the RPPairing keys
    /// (public_key, private_key, identifier), so both halves are kept.
    struct ImportResult {
        var remote = false
        var lockdown = false

        var summary: String {
            switch (remote, lockdown) {
            case (true, true):
                return Loc.s("lockdown + Remote Pairing", "lockdown + Remote Pairing", "lockdown + Remote Pairing")
            case (false, true):
                return Loc.s("lockdown", "lockdown", "lockdown")
            default:
                return Loc.s("Remote Pairing", "Remote Pairing", "Remote Pairing")
            }
        }
    }

    private static let remoteKeys: Set<String> = ["public_key", "private_key", "identifier", "alt_irk"]
    private static let lockdownMarkers = ["HostID", "HostCertificate", "DeviceCertificate", "RootCertificate", "HostPrivateKey"]

    /// Cheap content check used to route files that arrive through the Share
    /// Sheet, "Open in…" or the app's Documents folder.
    static func looksLikePairingFile(_ data: Data) -> Bool {
        guard data.count <= 1024 * 1024,
              let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any] else { return false }
        return dict["public_key"] is Data || lockdownMarkers.filter { dict[$0] != nil }.count >= 2
    }

    /// Copies only the credential bytes into Application Support. The file is
    /// excluded from backup and protected while the device is locked.
    @discardableResult
    func importPairingFile(from source: URL) throws -> ImportResult {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        return try importPairingData(data)
    }

    @discardableResult
    func importPairingData(_ data: Data) throws -> ImportResult {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard data.count <= 1024 * 1024 else {
            throw PairingError.invalidFile(Loc.s("file lớn hơn 1 MB", "file is larger than 1 MB", "文件大于 1 MB"))
        }
        guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any] else {
            throw PairingError.invalidFile(Loc.s("không phải file plist", "not a plist file", "不是 plist 文件"))
        }
        guard let directory = pairingDirectory,
              let remoteURL = pairingFileURL,
              let lockdownURL = lockdownRecordURL else {
            throw PairingError.invalidFile(Loc.s("không mở được Application Support", "cannot open Application Support", "无法打开 Application Support"))
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        var result = ImportResult()
        var problems: [String] = []

        // Half 1: RPPairing. Ghi NGUYÊN file (như StikDebug) thay vì tách 4 khoá:
        // rp_pairing_file_read chỉ đọc các khoá RP và bỏ qua phần lockdown thừa,
        // nên tránh mọi khác biệt do tách/ghi lại dữ liệu.
        if Self.isRemotePairingDictionary(root) {
            do {
                try install(root, to: remoteURL, in: directory, validate: pa_pairing_validate)
                result.remote = true
            } catch {
                problems.append("Remote Pairing: \(error.localizedDescription)")
            }
        }

        // Half 2: the classic lockdown record (everything else).
        if Self.lockdownMarkers.contains(where: { root[$0] != nil }) {
            var lockdown = root.filter { !Self.remoteKeys.contains($0.key) }
            // idevice requires WiFiMACAddress; some exporters omit it and the
            // CoreDeviceProxy route never uses it.
            if lockdown["WiFiMACAddress"] == nil { lockdown["WiFiMACAddress"] = "00:00:00:00:00:00" }
            do {
                try install(lockdown, to: lockdownURL, in: directory, validate: pa_lockdown_validate)
                result.lockdown = true
            } catch {
                problems.append("lockdown: \(error.localizedDescription)")
            }
        }

        guard result.remote || result.lockdown else {
            let detail = problems.isEmpty
                ? Loc.s("không phải Remote Pairing record (public_key/private_key/identifier) "
                            + "cũng không phải lockdown pairing file (HostID, certificates…)",
                        "neither a Remote Pairing record (public_key/private_key/identifier) "
                            + "nor a lockdown pairing file (HostID, certificates…)",
                        "既不是 Remote Pairing 记录（public_key/private_key/identifier），"
                            + "也不是 lockdown 配对文件（HostID、证书…）")
                : problems.joined(separator: "; ")
            throw PairingError.invalidFile(detail)
        }
        // A freshly imported record may target a restarted remotepairingd.
        if result.remote { LocalVPNConnection.forgetWorkingPort() }
        return result
    }

    /// Writes one half as XML, lets the Rust bridge parse it, then swaps it in.
    /// The previous record is only replaced when the new one is valid.
    private func install(_ dictionary: [String: Any], to destination: URL, in directory: URL,
                         validate: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?) throws {
        let bytes = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        let staging = directory.appendingPathComponent(".pairing-import-\(UUID().uuidString).plist")
        try bytes.write(to: staging, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            try staging.path.withCString { try check(validate($0)) }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        try protect(destination)
    }

    private static func isRemotePairingDictionary(_ dictionary: [String: Any]) -> Bool {
        guard let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            return false
        }
        return true
    }

    /// Pairing files dropped into the app's Documents folder: by iLoader's
    /// "Place" button (it writes Documents/pairingFile.plist once PanicAnalyzer
    /// is on its list), by the Files app, or by Finder file sharing. They are
    /// imported and then deleted, because Documents is visible to the user and
    /// to any computer the phone trusts.
    func importFromDocuments() -> (result: ImportResult?, error: String?, file: String?) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return (nil, nil, nil) }
        var candidates: [URL] = []
        for sub in ["", "pairing file", "Pairing", "SideStore/Documents"] {
            let dir = sub.isEmpty ? docs : docs.appendingPathComponent(sub, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                let lower = name.lowercased()
                guard lower.hasSuffix(".plist") || lower.hasSuffix(".mobiledevicepairing")
                        || lower.hasSuffix(".pairing") else { continue }
                candidates.append(dir.appendingPathComponent(name))
            }
        }
        let failedKey = "pairingDocumentsFailed"
        var failed = Set(UserDefaults.standard.stringArray(forKey: failedKey) ?? [])
        defer { UserDefaults.standard.set(Array(failed), forKey: failedKey) }

        for url in candidates {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int, size > 0, size <= 1024 * 1024,
                  let data = try? Data(contentsOf: url),
                  Self.looksLikePairingFile(data) else { continue }
            let stamp = "\(url.lastPathComponent)|\(size)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            do {
                let result = try importPairingData(data)
                try? fm.removeItem(at: url)
                failed.remove(stamp)
                return (result, nil, url.lastPathComponent)
            } catch {
                // Report a broken file once, not on every launch.
                if failed.insert(stamp).inserted {
                    return (nil, error.localizedDescription, url.lastPathComponent)
                }
            }
        }
        return (nil, nil, nil)
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
            throw PairingError.invalidFile(Loc.s("không mở được Application Support", "cannot open Application Support", "无法打开 Application Support"))
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
            throw PairingError.invalidFile(Loc.s("iOS trả về pairing record không đọc được",
                                                 "iOS returned an unreadable pairing record",
                                                 "iOS 返回的配对记录无法读取"))
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

    /// Connecting stops trying further routes after this long, so the UI always
    /// gets an answer (each route also has its own deadlines in the bridge).
    private let connectBudget: TimeInterval = 70
    /// Reading stops after this long and returns what was already read.
    private let readBudget: TimeInterval = 45

    /// The remote service exposes CrashReporter as a virtual AFC root. It does
    /// not grant arbitrary access to /var or even all of Library/Logs.
    /// `progress` receives short status lines while routes are tried.
    func scanLogs(progress: @escaping (String) -> Void = { _ in }) throws -> [[String: String]] {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard isConfigured else {
            throw supportsOnDevicePairing ? PairingError.notPaired : PairingError.missingFile
        }
        let deviceIP = LocalVPNConnection.deviceAddress

        let started = Date()
        var session: OpaquePointer?
        var failures: [String] = []

        // 0. Every route needs LocalDevVPN: one bounded check of lockdownd first
        //    instead of three routes each timing out on a dead VPN. If only
        //    62078 is silent, a Remote Pairing record still gets its own try.
        progress(Loc.s("Đang kiểm tra LocalDevVPN (\(deviceIP))…",
                       "Checking LocalDevVPN (\(deviceIP))…",
                       "正在检查 LocalDevVPN（\(deviceIP)）…"))
        var lockdownReachable = true
        do {
            try LocalVPNConnection.checkDeviceReachable(address: deviceIP)
        } catch {
            guard hasRemotePairingRecord else { throw error }
            lockdownReachable = false
            failures.append(error.localizedDescription)
        }

        typealias Route = (name: String, connect: () throws -> OpaquePointer)
        var routes: [Route] = []
        let lockdownURL = hasLockdownRecord && lockdownReachable ? lockdownRecordURL : nil
        // Lockdown direct (SideStore-style): a lockdown session on 62078, then
        // StartService crashreportcopymobile. No tunnel, so nothing for iOS to
        // close; tried first whenever a lockdown record exists (iLoader, computer).
        if let recordURL = lockdownURL {
            routes.append(("Lockdown", { try self.connectLockdownDirect(recordURL: recordURL, deviceIP: deviceIP) }))
        }
        var remote: Route?
        if hasRemotePairingRecord {
            remote = ("Remote Pairing", { try self.openRemotePairingSession(deviceIP: deviceIP) })
        }
        var proxy: Route?
        if let recordURL = lockdownURL {
            proxy = ("CoreDeviceProxy", { try self.connectLockdown(recordURL: recordURL, deviceIP: deviceIP) })
        }
        // iOS < 27: Remote Pairing at 49152 exactly like StikDebug, then
        // CoreDeviceProxy. iOS 27: CoreDeviceProxy before the RPPairing tunnel,
        // whose on-device listener iOS may close.
        let ordered: [Route?] = supportsOnDevicePairing ? [proxy, remote] : [remote, proxy]
        routes += ordered.compactMap { $0 }

        for (index, route) in routes.enumerated() where session == nil {
            if Date().timeIntervalSince(started) > connectBudget {
                failures.append(Loc.s("\(route.name): bỏ qua vì đã quá \(Int(connectBudget)) giây",
                                      "\(route.name): skipped after \(Int(connectBudget)) s",
                                      "\(route.name)：超过 \(Int(connectBudget)) 秒，已跳过"))
                continue
            }
            progress(Loc.s("Đang kết nối (\(index + 1)/\(routes.count)): \(route.name)…",
                           "Connecting (\(index + 1)/\(routes.count)): \(route.name)…",
                           "正在连接（\(index + 1)/\(routes.count)）：\(route.name)…"))
            do {
                session = try route.connect()
            } catch {
                failures.append("\(route.name): " + error.localizedDescription)
            }
        }

        // Ask lockdownd for a new record (iOS shows "Tin cậy máy tính này?").
        // Only when no lockdown record exists yet: with an imported record this
        // step only adds a sandbox error (127.0.0.1:62078) that hides the real one.
        if session == nil, !hasLockdownRecord, lockdownReachable {
            progress(Loc.s("Đang xin iPhone tạo lockdown record mới…",
                           "Asking the iPhone for a new lockdown record…",
                           "正在请求 iPhone 创建新的 lockdown 记录…"))
            do {
                session = try openLockdownSession(deviceIP: deviceIP, reuseStored: false)
            } catch {
                guard !failures.isEmpty else { throw error }
                failures.append(Loc.s("Tạo record mới: ", "New record: ", "新建记录：") + error.localizedDescription)
            }
        }
        if session == nil, !failures.isEmpty {
            throw PairingError.bridge(failures.joined(separator: "\n\n"))
        }
        guard let session else {
            throw PairingError.bridge(Loc.s("RSD tunnel không trả về phiên làm việc hợp lệ.", "The RSD tunnel returned no valid session.", "RSD 隧道未返回有效会话。"))
        }
        defer { pa_session_free(session) }
        progress(Loc.s("Đã kết nối, đang đọc CrashReporter…",
                       "Connected, reading CrashReporter…",
                       "已连接，正在读取 CrashReporter…"))

        struct PendingDirectory {
            let path: String
            let depth: Int
        }

        let readStarted = Date()
        var pending = [PendingDirectory(path: "", depth: 0)]
        var visited = Set<String>()
        var results: [[String: String]] = []
        var totalBytes = 0
        var entryCount = 0

        scan: while !pending.isEmpty,
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
                // A dead connection fails every later call too: keep what we have.
                if pa_session_is_broken(session) { break scan }
                continue
            }
            entryCount += entries.count

            for entry in entries {
                guard entry != ".", entry != "..", !entry.contains("/") else { continue }
                // Deadline for reading: return the logs already read.
                if Date().timeIntervalSince(readStarted) > readBudget { break scan }
                let path = directory.path.isEmpty ? entry : "\(directory.path)/\(entry)"
                if isLogFile(entry) {
                    guard results.count < maxFiles, totalBytes < maxTotalBytes else { break }
                    let data: Data
                    do {
                        data = try pull(session: session, path: path)
                    } catch {
                        if pa_session_is_broken(session) { break scan }
                        continue
                    }
                    guard !data.isEmpty,
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

    /// Direct lockdown route: lockdown session + StartService, no tunnel.
    private func connectLockdownDirect(recordURL: URL, deviceIP: String) throws -> OpaquePointer {
        var opened: OpaquePointer?
        try recordURL.path.withCString { path in
            try deviceIP.withCString { ip in
                try check(pa_session_connect_lockdown_direct(path, ip, &opened))
            }
        }
        guard let opened else {
            throw PairingError.bridge(Loc.s("Lockdown không trả về phiên làm việc hợp lệ.", "Lockdown returned no valid session.", "Lockdown 未返回有效会话。"))
        }
        return opened
    }

    /// Route 1 (iOS 27 record from Settings > Developer): RPPairing tunnel.
    private func openRemotePairingSession(deviceIP: String) throws -> OpaquePointer {
        // iOS < 27: đi y hệt StikDebug — cổng RemotePairing cố định 49152, không dò
        // Bonjour, không dùng cổng đã nhớ (có thể là cổng của thiết bị Apple khác
        // trên Wi-Fi, nói nhầm dịch vụ nên iPhone reset kết nối).
        if !supportsOnDevicePairing {
            LocalVPNConnection.forgetWorkingPort()
            let fixedPort = LocalVPNConnection.defaultPort
            let pairingURL = try prepareWorkingPairingFile()
            defer { try? FileManager.default.removeItem(at: pairingURL) }
            var session: OpaquePointer?
            do {
                try connect(pairingURL: pairingURL, deviceIP: deviceIP, port: fixedPort, session: &session)
            } catch {
                if FileManager.default.fileExists(atPath: pairingURL.path),
                   nativePairingFileIsValid(pairingURL) {
                    try? promoteWorkingPairingFile(pairingURL)
                }
                throw PairingError.bridge("[\(deviceIP):\(fixedPort)] " + error.localizedDescription)
            }
            guard let session else {
                throw PairingError.bridge(Loc.s("RSD tunnel không trả về phiên làm việc hợp lệ.", "The RSD tunnel returned no valid session.", "RSD 隧道未返回有效会话。"))
            }
            try? promoteWorkingPairingFile(pairingURL)
            return session
        }

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
            throw PairingError.bridge(Loc.s("RSD tunnel không trả về phiên làm việc hợp lệ.", "The RSD tunnel returned no valid session.", "RSD 隧道未返回有效会话。"))
        }
        try? promoteWorkingPairingFile(pairingURL)
        return session
    }

    /// Route 2 (learned from SideInstaller): CoreDeviceProxy over a lockdown
    /// session on 62078. Needs no inbound tunnel listener, which on-device
    /// RPPairing lacks. Uses the stored/imported classic record, otherwise asks
    /// lockdownd for one (iOS shows "Tin cậy máy tính này?").
    private func openLockdownSession(deviceIP: String, reuseStored: Bool = true) throws -> OpaquePointer {
        guard let directory = pairingDirectory, let recordURL = lockdownRecordURL else {
            throw PairingError.invalidFile(Loc.s("không mở được Application Support", "cannot open Application Support", "无法打开 Application Support"))
        }
        var lastError: Error?
        if reuseStored, hasLockdownRecord {
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
            throw lastError ?? PairingError.bridge(Loc.s("Không tạo được lockdown pair record.",
                                                         "Could not create a lockdown pair record.",
                                                         "无法创建 lockdown 配对记录。"))
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
            throw PairingError.bridge(Loc.s("CoreDeviceProxy không trả về phiên làm việc hợp lệ.", "CoreDeviceProxy returned no valid session.", "CoreDeviceProxy 未返回有效会话。"))
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
            throw PairingError.invalidFile(Loc.s("không mở được Application Support", "cannot open Application Support", "无法打开 Application Support"))
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
            throw PairingError.invalidFile(Loc.s("pairing record chưa được tạo", "the pairing record was not created", "配对记录尚未创建"))
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
        let message = String(validatingUTF8: error)
            ?? Loc.s("Lỗi pairing không xác định", "Unknown pairing error", "未知配对错误")
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
