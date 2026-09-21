//  LogBridge.swift
//  Cầu nối JS <-> native: quét log, nhập file, chia sẻ báo cáo,
//  và tải bộ luật chẩn đoán mới nhất từ kho công khai.

import UIKit
import Darwin
import WebKit
import UniformTypeIdentifiers

final class LogBridge: NSObject {

    static let shared = LogBridge()
    weak var webView: WKWebView?

    private let dbNames = ["panic_rules", "i2c_rules", "sensor_database",
                           "model_database", "sample_logs"]

    private enum PickerMode {
        case logs
        case pairing
    }

    private var pickerMode: PickerMode = .logs

    /// Kho luật công khai — sửa file JSON trên GitHub là app nhận ngay lần mở sau.
    private let rulesBaseURL = "https://raw.githubusercontent.com/iOSVNNews/PanicAnalyzer-iOSVN/main/assets/"

    /// Kênh liên hệ khi gặp log không tra được.
    static let adminTelegram = "https://t.me/longdzqua"

    /// Nguồn bộ luật đang dùng: "remote" (vừa tải), "cache" (đã tải trước đó), "bundle".
    private(set) var rulesSource = "bundle"
    private(set) var rulesUpdatedAt: String = ""

    /// Thư mục log hệ thống — chỉ đọc được ở bản .tipa/TrollStore.
    /// Trên non-JB các lệnh này thất bại im lặng và trả về mảng rỗng.
    private let searchDirs = [
        "/var/mobile/Library/Logs/CrashReporter",
        "/var/mobile/Library/Logs/CrashReporter/Panics",
        "/var/mobile/Library/Logs/CrashReporter/DiagnosticLogs",
        "/var/mobile/Library/Logs/CrashReporter/Retired",
        "/var/mobile/Library/Logs/DiagnosticReports",
        "/private/var/mobile/Library/Logs/CrashReporter",
        "/private/var/mobile/Library/Logs/CrashReporter/Panics",
        "/private/var/mobile/Library/Logs/DiagnosticReports"
    ]

    /// Máy này có đọc được thư mục log hệ thống không (TrollStore/jailbreak thì có).
    var canReadSystemLogs: Bool {
        let fm = FileManager.default
        for dir in searchDirs {
            if let names = try? fm.contentsOfDirectory(atPath: dir), !names.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - Nhận diện thiết bị THẬT

    /// Mã máy lấy từ kernel, ví dụ "iPhone18,3". Không bao giờ lấy từ log.
    var deviceIdentifier: String {
        var info = utsname()
        uname(&info)
        return Mirror(reflecting: info.machine).children.reduce(into: "") { acc, el in
            if let v = el.value as? Int8, v != 0 {
                acc.append(Character(UnicodeScalar(UInt8(v))))
            }
        }
    }

    /// Phiên bản iOS đang chạy, ví dụ "26.2".
    var iosVersion: String { UIDevice.current.systemVersion }

    /// Phiên bản ứng dụng đang cài, ví dụ "2.5.0".
    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Bản mới nhất trên kho phát hành (điền sau khi kiểm tra).
    private(set) var latestVersion = ""
    private(set) var latestURL = ""

    // MARK: - Hộp thư App Group (Share Extension ghi vào đây)

    static let appGroupID = "group.com.iosvn.panicanalyzer"

    static func sharedInboxURL() -> URL? {
        guard let c = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let inbox = c.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Đọc log do Share Extension gửi sang, rồi xoá khỏi hộp thư.
    @discardableResult
    func drainSharedInbox() -> Int {
        guard let inbox = Self.sharedInboxURL(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path)
        else { return 0 }
        var results: [[String: String]] = []
        var totalBytes = 0
        for n in names where isLogFile(n) {
            let f = inbox.appendingPathComponent(n)
            if let data = try? Data(contentsOf: f),
               data.count <= 12 * 1024 * 1024,
               totalBytes + data.count <= 24 * 1024 * 1024 {
                totalBytes += data.count
                results.append(["name": n, "content": String(decoding: data, as: UTF8.self)])
            }
            try? FileManager.default.removeItem(at: f)
        }
        if !results.isEmpty { deliver(results, autoScan: false, source: "share") }
        return results.count
    }

    // MARK: - Bộ luật tải về

    /// Thư mục cache bộ luật trong vùng dữ liệu app.
    private var rulesCacheDir: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("rules", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Đọc một bộ dữ liệu: ưu tiên bản đã tải, không có thì dùng bản dựng sẵn trong app.
    private func loadDatabase(_ name: String) -> (Any, Bool)? {
        if let cached = rulesCacheDir?.appendingPathComponent("\(name).json"),
           let data = try? Data(contentsOf: cached),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            return (obj, true)
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "json",
                                        subdirectory: "assets"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return (obj, false)
    }

    private func databaseJSON() -> String? {
        var payload: [String: Any] = [:]
        var anyCached = false
        for name in dbNames {
            guard let (obj, cached) = loadDatabase(name) else { continue }
            payload[name] = obj
            if cached { anyCached = true }
        }
        if anyCached && rulesSource == "bundle" { rulesSource = "cache" }
        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    /// Kiểm tra tính hợp lệ trước khi ghi đè cache — tránh lưu file hỏng.
    private func isValidDatabase(_ name: String, _ obj: Any) -> Bool {
        switch name {
        case "panic_rules":
            guard let arr = obj as? [[String: Any]], arr.count >= 5 else { return false }
            return arr.allSatisfy { $0["id"] is String && $0["match"] is [String: Any] }
        case "sample_logs":
            return obj is [Any]
        default:
            return obj is [String: Any] || obj is [Any]
        }
    }

    /// Tải bộ luật mới nhất. Thất bại thì im lặng dùng bản đang có.
    func refreshRules(notifyJS: Bool = true) {
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 8
            c.timeoutIntervalForResource = 15
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return c
        }())
        let group = DispatchGroup()
        let counter = DispatchQueue(label: "rules.counter")
        var updated = 0

        for name in dbNames where name != "sample_logs" {
            guard let url = URL(string: rulesBaseURL + name + ".json") else { continue }
            group.enter()
            session.dataTask(with: url) { [weak self] data, response, _ in
                defer { group.leave() }
                guard let self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, data.count > 32,
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      self.isValidDatabase(name, obj),
                      let dir = self.rulesCacheDir
                else { return }
                try? data.write(to: dir.appendingPathComponent("\(name).json"), options: .atomic)
                counter.sync { updated += 1 }
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let updated = counter.sync { updated }
            if updated > 0 {
                self.rulesSource = "remote"
                let f = DateFormatter()
                f.dateFormat = "dd/MM/yyyy HH:mm"
                self.rulesUpdatedAt = f.string(from: Date())
            }
            if notifyJS { self.pushRulesToJS(changed: updated > 0) }
            self.checkAppUpdate()
        }
    }

    /// So sánh hai chuỗi phiên bản dạng "2.5.1" — trả về true nếu a mới hơn b.
    private func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Hỏi kho phát hành xem đã có bản ứng dụng mới chưa.
    func checkAppUpdate() {
        guard let url = URL(string: rulesBaseURL + "app_version.json") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remote = obj["version"] as? String,
                  self.isNewer(remote, than: self.appVersion)
            else { return }
            self.latestVersion = remote
            self.latestURL = (obj["url"] as? String) ?? ""
            let notes = (obj["notes"] as? String) ?? ""
            DispatchQueue.main.async {
                let payload = """
                {"version":"\(remote)","url":"\(self.latestURL)","notes":"\(notes)","current":"\(self.appVersion)"}
                """
                self.webView?.evaluateJavaScript("""
                (function(){ if (window.onNativeAppUpdate) window.onNativeAppUpdate(\(payload)); })();
                """)
            }
        }.resume()
    }

    private func pushRulesToJS(changed: Bool) {
        guard let json = databaseJSON() else { return }
        let info = """
        {"source":"\(rulesSource)","updatedAt":"\(rulesUpdatedAt)","changed":\(changed ? "true" : "false")}
        """
        let js = """
        (function(){
          window.__NATIVE_DB__ = \(json);
          window.__RULES_INFO__ = \(info);
          if (window.onNativeRulesUpdated) window.onNativeRulesUpdated(window.__RULES_INFO__);
        })();
        """
        webView?.evaluateJavaScript(js)
    }

    // MARK: - Bơm dữ liệu vào trang trước khi app.js chạy

    func injectionScript() -> String {
        var parts = ["window.__DEVICE_MODEL__ = \"\(deviceIdentifier)\";"]
        if let json = databaseJSON() { parts.append("window.__NATIVE_DB__ = \(json);") }
        parts.append("window.__RULES_INFO__ = {\"source\":\"\(rulesSource)\",\"updatedAt\":\"\(rulesUpdatedAt)\",\"changed\":false};")
        parts.append("window.__ADMIN_TELEGRAM__ = \"\(Self.adminTelegram)\";")
        parts.append("window.__CAN_READ_LOGS__ = \(canReadSystemLogs ? "true" : "false");")
        parts.append("window.__PAIRING_CONFIGURED__ = \(PairingLogService.shared.isConfigured ? "true" : "false");")
        parts.append("window.__IOS_VERSION__ = \"\(iosVersion)\";")
        parts.append("window.__APP_VERSION__ = \"\(appVersion)\";")
        parts.append("window.__NATIVE_BRIDGE_READY__ = true;")
        return parts.joined(separator: "\n")
    }

    // MARK: - Mở liên kết ngoài (Telegram của admin)

    func openExternal(_ raw: String) {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "tg" else { return }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }

    // MARK: - Quét log trực tiếp hoặc qua Remote Pairing

    func scanLogs() {
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [[String: String]] = []
            let fm = FileManager.default
            for dir in self.searchDirs {
                guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for n in names where self.isLogFile(n) {
                    let path = (dir as NSString).appendingPathComponent(n)
                    guard let text = try? String(contentsOfFile: path, encoding: .utf8)
                    else { continue }
                    results.append(["name": n, "content": text])
                }
            }
            if !results.isEmpty {
                self.deliver(results, autoScan: true, source: "filesystem")
                return
            }

            guard PairingLogService.shared.isConfigured else {
                self.deliver([], autoScan: true, source: "sandbox")
                return
            }
            do {
                let pairedLogs = try PairingLogService.shared.scanLogs()
                self.deliver(pairedLogs, autoScan: true, source: "pairing")
            } catch {
                self.deliver([], autoScan: true, source: "pairing")
                self.notifyPairingStatus(
                    configured: true,
                    message: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    private func isLogFile(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.hasSuffix(".ips") || l.hasSuffix(".crash") || l.hasSuffix(".panic")
            || l.hasSuffix(".synced") || l.contains("panic-full") || l.contains("watchdog")
    }

    // MARK: - Nhập file thủ công (đường hợp pháp trên non-JB)

    func presentPicker() {
        pickerMode = .logs
        let types: [UTType] = [
            UTType(filenameExtension: "ips") ?? .data,
            UTType(filenameExtension: "crash") ?? .data,
            UTType(filenameExtension: "panic") ?? .data,
            .plainText, .data
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types,
                                                    asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        topViewController()?.present(picker, animated: true)
    }

    func presentPairingPicker() {
        pickerMode = .pairing
        let propertyList = UTType("com.apple.property-list") ?? .data
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [propertyList, .xml, .data],
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.delegate = self
        topViewController()?.present(picker, animated: true)
    }

    func importFiles(_ urls: [URL]) {
        var results: [[String: String]] = []
        var totalBytes = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count <= 12 * 1024 * 1024,
                  totalBytes + data.count <= 24 * 1024 * 1024 else { continue }
            totalBytes += data.count
            results.append([
                "name": url.lastPathComponent,
                "content": String(decoding: data, as: UTF8.self)
            ])
        }
        deliver(results, autoScan: false, source: "file")
    }

    private func importPairingFile(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PairingLogService.shared.importPairingFile(from: url)
                self.notifyPairingStatus(
                    configured: true,
                    message: "Đã lưu Remote Pairing file. Hãy bật LocalDevVPN để quét log.",
                    isError: false
                )
                self.scanLogs()
            } catch {
                self.notifyPairingStatus(
                    configured: PairingLogService.shared.isConfigured,
                    message: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    private func removePairingFile() {
        do {
            try PairingLogService.shared.removePairingFile()
            notifyPairingStatus(
                configured: false,
                message: "Đã xoá Remote Pairing file khỏi ứng dụng.",
                isError: false
            )
        } catch {
            notifyPairingStatus(configured: true, message: error.localizedDescription, isError: true)
        }
    }

    // MARK: - Chia sẻ báo cáo

    func share(_ text: String) {
        guard !text.isEmpty else { return }
        let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let pop = vc.popoverPresentationController, let host = topViewController()?.view {
            pop.sourceView = host
            pop.sourceRect = CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 0, height: 0)
        }
        topViewController()?.present(vc, animated: true)
    }

    // MARK: - Đẩy kết quả về JS

    func deliver(_ logs: [[String: String]], autoScan: Bool, source: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: logs),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        // Bọc thành string literal an toàn cho JS (bỏ cặp ngoặc vuông của mảng)
        guard let qData = try? JSONSerialization.data(withJSONObject: [jsonStr],
                                                      options: .fragmentsAllowed),
              let qArray = String(data: qData, encoding: .utf8) else { return }
        let quoted = String(qArray.dropFirst().dropLast())

        let js = """
        (function(){
          if (window.handleNativeLogsReceived) window.handleNativeLogsReceived(\(quoted));
          if (window.onNativeScanMode) window.onNativeScanMode(\(autoScan ? "true" : "false"), \(logs.count), "\(source)");
        })();
        """
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(js) }
    }

    private func notifyPairingStatus(configured: Bool, message: String, isError: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: [message]),
              let array = String(data: data, encoding: .utf8) else { return }
        let quoted = String(array.dropFirst().dropLast())
        let js = """
        (function(){
          window.__PAIRING_CONFIGURED__ = \(configured ? "true" : "false");
          if (window.onNativePairingStatus) {
            window.onNativePairingStatus({configured:\(configured ? "true" : "false"),error:\(isError ? "true" : "false"),message:\(quoted)});
          }
        })();
        """
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(js) }
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

// MARK: - WKScriptMessageHandler

extension LogBridge: WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "autoScanLogs": scanLogs()
        case "pickFiles":    presentPicker()
        case "importPairing": presentPairingPicker()
        case "removePairing": removePairingFile()
        case "shareText":    share(body["text"] as? String ?? "")
        case "refreshRules": refreshRules()
        case "openURL":      openExternal(body["url"] as? String ?? "")
        default: break
        }
    }
}

// MARK: - UIDocumentPickerDelegate

extension LogBridge: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        switch pickerMode {
        case .logs:
            importFiles(urls)
        case .pairing:
            if let url = urls.first { importPairingFile(url) }
        }
        pickerMode = .logs
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerMode = .logs
    }
}
