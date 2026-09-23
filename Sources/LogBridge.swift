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
        "/var/mobile/Library/Logs/DiagnosticReports",
        "/var/mobile/Library/Logs/CrashReporter/Retired",
        "/var/db/CrashReporter",                       // panic-full ghi ở đây trên nhiều đời máy
        "/var/mobile/Library/Logs/CrashReporter/Panics"
    ]

    /// Máy này có đọc được thư mục log hệ thống không (TrollStore/jailbreak thì có).
    /// Trên non-JB các thư mục này nằm ngoài sandbox nên luôn trả về false.
    var canReadSystemLogs: Bool {
        let fm = FileManager.default
        for dir in searchDirs {
            if let names = try? fm.contentsOfDirectory(atPath: dir), !names.isEmpty {
                return true
            }
        }
        return false
    }

    private let maxFilesystemLogs = 200
    private let maxFilesystemBytes = 24 * 1024 * 1024
    private let maxFileBytes = 12 * 1024 * 1024

    /// Đọc thẳng log từ hệ thống (chỉ chạy được trên máy JB/TrollStore).
    /// Quét cả thư mục con của CrashReporter (Panics, Retired, DiagnosticLogs…)
    /// và bỏ trùng theo đường dẫn thật để không đọc lặp giữa /var và /private/var.
    func readFilesystemLogs() -> [[String: String]] {
        let fm = FileManager.default
        var results: [[String: String]] = []
        var seen = Set<String>()
        var totalBytes = 0

        for root in searchDirs {
            guard let enumerator = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in enumerator {
                if results.count >= maxFilesystemLogs || totalBytes >= maxFilesystemBytes { break }
                let name = (rel as NSString).lastPathComponent
                guard isLogFile(name) else { continue }
                let path = (root as NSString).appendingPathComponent(rel)
                // Bỏ trùng: /var là symlink của /private/var nên cùng một file.
                let canonical = (try? URL(fileURLWithPath: path).resourceValues(
                    forKeys: [.canonicalPathKey]))?.canonicalPath ?? path
                guard seen.insert(canonical).inserted else { continue }
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? Int, size > 0, size <= maxFileBytes,
                      let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                totalBytes += size
                results.append(["name": rel, "content": text])
            }
        }
        return results
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
        parts.append("window.__AUTO_PAIRING__ = \(PairingLogService.shared.supportsOnDevicePairing ? "true" : "false");")
        parts.append("window.__IOS_VERSION__ = \"\(iosVersion)\";")
        parts.append("window.__APP_VERSION__ = \"\(appVersion)\";")
        parts.append("window.__APP_LANG__ = \"\(Loc.lang)\";")
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
            // Trên máy JB / TrollStore đọc thẳng file log, không cần ghép đôi.
            let results = self.readFilesystemLogs()
            if !results.isEmpty {
                self.deliver(results, autoScan: true, source: "filesystem")
                return
            }

            guard PairingLogService.shared.isConfigured
                    || PairingLogService.shared.supportsOnDevicePairing else {
                self.deliver([], autoScan: true, source: "sandbox")
                return
            }
            let wasConfigured = PairingLogService.shared.isConfigured
            do {
                let pairedLogs = try PairingLogService.shared.scanLogs()
                if !wasConfigured && PairingLogService.shared.isConfigured {
                    self.notifyPairingStatus(
                        configured: true,
                        message: Loc.s("Đã tự ghép đôi và lưu pairing record trên thiết bị.",
                                       "Paired on-device and saved the pairing record.",
                                       "已在本机完成配对并保存配对记录。"),
                        isError: false
                    )
                }
                self.deliver(pairedLogs, autoScan: true, source: "pairing")
            } catch {
                let notPaired: Bool
                if case PairingLogService.PairingError.notPaired = error { notPaired = true } else { notPaired = false }
                self.notifyPairingStatus(
                    configured: PairingLogService.shared.isConfigured,
                    message: error.localizedDescription,
                    isError: !notPaired
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
                    message: Loc.s("Đã nhập pairing file. Bật LocalDevVPN để quét log.",
                                   "Pairing file imported. Turn on LocalDevVPN to scan logs.",
                                   "配对文件已导入。打开 LocalDevVPN 以扫描日志。"),
                    isError: false
                )
                self.scanLogs()
            } catch {
                let notPaired: Bool
                if case PairingLogService.PairingError.notPaired = error { notPaired = true } else { notPaired = false }
                self.notifyPairingStatus(
                    configured: PairingLogService.shared.isConfigured,
                    message: error.localizedDescription,
                    isError: !notPaired
                )
            }
        }
    }

    private func removePairingFile() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PairingLogService.shared.removePairingFile()
                self.notifyPairingStatus(
                    configured: false,
                    message: Loc.s("Đã xoá pairing file khỏi ứng dụng.",
                                   "Pairing file removed from the app.",
                                   "已从应用中删除配对文件。"),
                    isError: false
                )
            } catch {
                self.notifyPairingStatus(configured: true, message: error.localizedDescription, isError: true)
            }
        }
    }

    private var pairingInProgress = false

    /// iOS 27: the iPhone pairs with PanicAnalyzer itself. The app advertises a
    /// pairable host; the user picks it in Settings > Privacy & Security >
    /// Developer and types the PIN. The last working record is kept until the
    /// new one is saved.
    private func pairThisDevice() {
        guard PairingLogService.shared.supportsOnDevicePairing else {
            presentPairingPicker()
            return
        }
        guard !pairingInProgress else {
            presentPairingInstructions(pin: nil)
            return
        }
        pairingInProgress = true
        pushPairingCard(stage: "permission", pin: nil)
        notifyPairingStatus(
            configured: PairingLogService.shared.isConfigured,
            message: Loc.s("Đang xin quyền Mạng cục bộ… Hãy chọn Cho phép nếu iOS hỏi.",
                           "Requesting Local Network permission… Tap Allow if iOS asks.",
                           "正在请求本地网络权限… 如 iOS 询问请点「允许」。"),
            isError: false
        )
        // Without Local Network permission iOS drops our Bonjour advertisement
        // and Settings only lists other hosts (e.g. SideInstaller).
        localNetwork.request { granted in
            guard granted else {
                self.finishPairingUI()
                self.notifyPairingStatus(
                    configured: PairingLogService.shared.isConfigured,
                    message: Loc.s(
                        "Chưa có quyền Mạng cục bộ nên PanicAnalyzer không hiện trong Cài đặt. "
                            + "Vào Cài đặt > PanicAnalyzer > bật Mạng cục bộ rồi bấm Ghép đôi lại.",
                        "Without Local Network permission PanicAnalyzer cannot appear in Settings. "
                            + "Go to Settings > PanicAnalyzer, turn on Local Network, then tap Pair again.",
                        "没有本地网络权限，PanicAnalyzer 无法出现在设置中。"
                            + "请前往 设置 > PanicAnalyzer 开启本地网络，然后再次点配对。"),
                    isError: true
                )
                return
            }
            self.startPairingHost()
        }
    }

    private let localNetwork = LocalNetworkAuthorization()

    private func startPairingHost() {
        PairingKeepAlive.shared.start()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PairingLogService.shared.pairOnDevice(
                    onAdvertising: {
                        self.notifyPairingStatus(
                            configured: PairingLogService.shared.isConfigured,
                            message: Loc.s(
                                "Đang chờ ghép đôi: mở Cài đặt > Quyền riêng tư & Bảo mật > Nhà phát triển, "
                                    + "chọn \(PairableHostService.hostName) (không chọn SideInstaller hay máy khác).",
                                "Waiting for pairing: open Settings > Privacy & Security > Developer, "
                                    + "pick \(PairableHostService.hostName) (not SideInstaller or another computer).",
                                "等待配对：打开 设置 > 隐私与安全性 > 开发者，"
                                    + "选择 \(PairableHostService.hostName)（不要选 SideInstaller 或其他电脑）。"),
                            isError: false
                        )
                        DispatchQueue.main.async {
                            self.pushPairingCard(stage: "advertising", pin: nil)
                            self.presentPairingInstructions(pin: nil)
                        }
                    },
                    onPin: { pin in
                        DispatchQueue.main.async {
                            PairingKeepAlive.shared.showPin(pin)
                            self.pushPairingCard(stage: "pin", pin: pin)
                            self.presentPairingInstructions(pin: pin)
                        }
                        self.notifyPairingStatus(
                            configured: PairingLogService.shared.isConfigured,
                            message: Loc.s("Nhập mã \(pin) trong Cài đặt (đã sao chép mã).",
                                           "Enter code \(pin) in Settings (copied).",
                                           "请在设置中输入代码 \(pin)（已复制）。"),
                            isError: false
                        )
                    }
                )
                DispatchQueue.main.async {
                    self.finishPairingUI()
                    self.notifyPairingStatus(
                        configured: true,
                        message: Loc.s("Đã ghép đôi và lưu pairing record. Đang đọc CrashReporter qua LocalDevVPN…",
                                       "Paired and saved the pairing record. Reading CrashReporter via LocalDevVPN…",
                                       "配对成功并已保存配对记录。正在通过 LocalDevVPN 读取 CrashReporter…"),
                        isError: false
                    )
                    self.scanLogs()
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishPairingUI()
                    self.notifyPairingStatus(
                        configured: PairingLogService.shared.isConfigured,
                        message: error.localizedDescription,
                        isError: true
                    )
                }
            }
        }
    }

    private weak var pairingAlert: UIAlertController?

    private func finishPairingUI() {
        pairingInProgress = false
        PairingKeepAlive.shared.stop()
        pairingAlert?.dismiss(animated: true)
        pushPairingCard(stage: "done", pin: nil)
    }

    /// Keeps the pairing steps and PIN on the main screen (alerts vanish when
    /// the user switches to Settings).
    private func pushPairingCard(stage: String, pin: String?) {
        let pinJSON = pin.map { "\"\($0.filter(\.isNumber))\"" } ?? "null"
        let js = """
        (function(){ if (window.onNativePairingCard) window.onNativePairingCard({stage:"\(stage)",pin:\(pinJSON),host:"\(PairableHostService.hostName)"}); })();
        """
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(js) }
    }

    /// Opens the Settings app itself. Since iOS 18 Apple ignores the old
    /// "App-prefs:Privacy…" paths and lands on PanicAnalyzer's own page instead,
    /// so no link can reach Privacy & Security > Developer directly; the bare
    /// scheme opens Settings where the user last was (usually the root).
    private func openPrivacySettings() {
        guard let url = URL(string: "App-prefs:") else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened, let fallback = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(fallback)
            }
        }
    }

    private func presentPairingInstructions(pin: String?) {
        let host = PairableHostService.hostName
        let steps = Loc.s(
            "1. Bật LocalDevVPN và Chế độ nhà phát triển.\n"
                + "2. Trong Cài đặt (trang chính) chọn Quyền riêng tư & Bảo mật, cuộn xuống cuối, chọn Nhà phát triển.\n"
                + "3. Chọn đúng \"\(host)\" — không chọn SideInstaller hay máy khác.\n"
                + "4. Nhập mã PIN hiện trên màn hình app và trong thông báo (đã sao chép sẵn).",
            "1. Turn on LocalDevVPN and Developer Mode.\n"
                + "2. In Settings (main page) choose Privacy & Security, scroll to the bottom, choose Developer.\n"
                + "3. Pick \"\(host)\" — not SideInstaller or another computer.\n"
                + "4. Enter the PIN shown in the app and in the notification (already copied).",
            "1. 打开 LocalDevVPN 和开发者模式。\n"
                + "2. 在设置（主页面）选择 隐私与安全性，滑到底部，选择 开发者。\n"
                + "3. 选择 \"\(host)\"——不要选 SideInstaller 或其他电脑。\n"
                + "4. 输入应用和通知中显示的 PIN 码（已复制）。")
        let pinTitle: (String) -> String = { Loc.s("Mã ghép đôi: \($0)", "Pairing code: \($0)", "配对码：\($0)") }
        let message = pin.map { "PIN: \($0)\n\n" + steps } ?? steps
        if let alert = pairingAlert {
            alert.message = message
            if let pin { alert.title = pinTitle(pin) }
            return
        }
        let alert = UIAlertController(
            title: pin.map(pinTitle) ?? Loc.s("Ghép đôi iPhone này", "Pair this iPhone", "配对这台 iPhone"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: Loc.s("Huỷ ghép đôi", "Cancel pairing", "取消配对"), style: .destructive) { _ in
            PairingLogService.shared.cancelPairing()
        })
        alert.addAction(UIAlertAction(title: Loc.s("Mở Cài đặt", "Open Settings", "打开设置"), style: .default) { [weak self] _ in
            // Pairing keeps running in the background; the PIN arrives as a notification.
            self?.openPrivacySettings()
        })
        pairingAlert = alert
        topViewController()?.present(alert, animated: true)
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
        case "pairDevice":    pairThisDevice()
        case "openPrivacySettings": openPrivacySettings()
        case "setLanguage":   Loc.setLanguage(body["lang"] as? String ?? "")
        case "cancelPairing": PairingLogService.shared.cancelPairing()
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
