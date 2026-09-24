//  WebLoadMonitor.swift
//  Loads the web UI and makes sure a failure is visible instead of a black
//  screen. The .deb builds live in /Applications or /var/jb/Applications as
//  system apps without the container sandbox the IPA/TIPA get, and there the
//  WebContent process may be unable to read file:// pages from the bundle. For
//  those installs (and as an automatic fallback anywhere) the page is served
//  through a custom scheme, so WebKit never needs file access to the bundle.

import UIKit
import WebKit

/// Serves files from the app bundle as panicanalyzer://app/<path>.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "panicanalyzer"
    static let indexURL = URL(string: "\(scheme)://app/web/index.html")!

    /// Maps a scheme URL to a file inside the bundle; nil for anything outside it.
    static func fileURL(for url: URL, bundle: URL = Bundle.main.bundleURL) -> URL? {
        let root = bundle.standardizedFileURL.resolvingSymlinksInPath()
        let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return nil }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        // A downloaded interface update replaces web/<file> (see WebUpdater).
        guard let url = task.request.url,
              let file = WebUpdater.shared.overrideFile(for: url) ?? Self.fileURL(for: url),
              let data = try? Data(contentsOf: file),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                  "Content-Type": Self.mimeType(for: file),
                  "Content-Length": String(data.count),
                  "Cache-Control": "no-cache"
              ]) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Navigation callbacks of the probe view, kept apart from the page's.
final class ProbeDelegate: NSObject, WKNavigationDelegate {
    private let done: (Bool) -> Void
    private var reported = false

    init(done: @escaping (Bool) -> Void) { self.done = done }

    private func report(_ ok: Bool) {
        guard !reported else { return }
        reported = true
        DispatchQueue.main.async { self.done(ok) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { report(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(false) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { report(false) }
}

final class WebLoadMonitor: NSObject, WKNavigationDelegate {

    static let shared = WebLoadMonitor()

    private weak var webView: WKWebView?
    private var usingScheme = false
    /// The page comes from a downloaded interface update, not the bundle.
    private var usingUpdate = false
    private var pageReady = false
    private var terminations = 0
    private var lastError: String?
    private var watchdog: DispatchWorkItem?
    private let statusLabel = UILabel()
    private let statusPanel = UIView()

    /// The .deb puts the app in /Applications (rootful) or /var/jb/Applications
    /// (rootless, really /private/preboot/…/procursus; roothide uses a random
    /// /var/containers/Bundle/Application/.jbroot-…). IPA, TIPA and
    /// LiveContainer installs live elsewhere and keep the file:// load.
    static var isSystemInstall: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix("/var/jb/")
            || path.hasPrefix("/private/preboot/") || path.contains("/.jbroot-")
    }

    /// App Store, sideload and TrollStore installs run inside their own
    /// /var/mobile/Containers/Data/Application/<UUID>; system installs may not.
    static var hasDataContainer: Bool {
        NSHomeDirectory().contains("/Containers/Data/Application/")
    }

    /// A bare WKWebView (no scripts, no custom scheme, data in RAM), started
    /// only after the page failed: tells whether WebKit itself cannot run in
    /// this install or only our page does not.
    private var probe: WKWebView?
    private var probeDelegate: ProbeDelegate?
    private var probeResult: String?
    private var headline = ""

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        // Dark panel so the message reads on a white or black empty web view.
        statusPanel.backgroundColor = UIColor(white: 0.1, alpha: 0.96)
        statusPanel.layer.cornerRadius = 14
        statusPanel.isHidden = true
        statusPanel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.addSubview(statusLabel)
        webView.addSubview(statusPanel)
        NSLayoutConstraint.activate([
            statusPanel.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
            statusPanel.leadingAnchor.constraint(equalTo: webView.leadingAnchor, constant: 20),
            statusPanel.trailingAnchor.constraint(equalTo: webView.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: statusPanel.topAnchor, constant: 18),
            statusLabel.bottomAnchor.constraint(equalTo: statusPanel.bottomAnchor, constant: -18),
            statusLabel.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: statusPanel.trailingAnchor, constant: -16)
        ])
        load(viaScheme: Self.isSystemInstall)
    }

    /// Called by the page (app.js) as soon as its script runs.
    func markReady() {
        dispatchPrecondition(condition: .onQueue(.main))
        pageReady = true
        watchdog?.cancel()
        statusPanel.isHidden = true
    }

    private func load(viaScheme: Bool) {
        guard let webView else { return }
        usingScheme = viaScheme
        let update = WebUpdater.shared.activeDirectory
        usingUpdate = update != nil
        pageReady = false
        if viaScheme {
            webView.load(URLRequest(url: BundleSchemeHandler.indexURL))
        } else if let update {
            // Same file:// origin as the bundled page, so saved data is kept.
            webView.loadFileURL(update.appendingPathComponent("index.html"), allowingReadAccessTo: update)
        } else if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            // Read access to the whole bundle so ../assets resolves.
            webView.loadFileURL(index, allowingReadAccessTo: Bundle.main.bundleURL)
        } else {
            show(Loc.s("Thiếu web/index.html trong gói ứng dụng.",
                       "web/index.html is missing from the app bundle.",
                       "应用包中缺少 web/index.html。"))
            return
        }
        armWatchdog()
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.pageDidNotStart() }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    /// Reloads the interface, e.g. after a downloaded update was applied.
    func reloadInterface() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let webView else { return }
        // Fresh start-up values (__WEB_BUILD__, pairing state…).
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: LogBridge.shared.injectionScript(),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        terminations = 0
        lastError = nil
        statusPanel.isHidden = true
        load(viaScheme: usingScheme)
    }

    /// A downloaded interface that does not start is dropped for good and
    /// the one inside the app is loaded instead.
    private func dropUpdate() -> Bool {
        guard usingUpdate else { return false }
        WebUpdater.shared.rejectActiveBuild()
        load(viaScheme: usingScheme)
        return true
    }

    /// The page never ran its script: try the other way once, then explain.
    private func pageDidNotStart() {
        guard !pageReady else { return }
        if dropUpdate() { return }
        if !usingScheme {
            load(viaScheme: true)
            return
        }
        show(Loc.s("Giao diện chưa tải được.", "The interface did not load.", "界面未能加载。"))
    }

    private func failed(_ error: Error) {
        // Only the first page load matters; a cancelled load is a reload.
        let code = (error as NSError).code
        guard !pageReady, code != NSURLErrorCancelled else { return }
        lastError = error.localizedDescription
        if dropUpdate() { return }
        if !usingScheme {
            load(viaScheme: true)
            return
        }
        show(Loc.s("Giao diện chưa tải được.", "The interface did not load.", "界面未能加载。"))
    }

    private func show(_ headline: String) {
        guard let webView else { return }
        self.headline = headline
        var lines = [headline]
        if let lastError { lines.append(lastError) }
        lines.append(Loc.s("Chế độ tải: ", "Load mode: ", "加载方式：") + (usingScheme ? "scheme" : "file")
                     + " · web \(WebUpdater.shared.currentBuild)")
        lines.append(Loc.s("Vị trí cài: ", "Installed at: ", "安装位置：") + Bundle.main.bundlePath)
        lines.append(Loc.s("Thư mục dữ liệu: ", "Data folder: ", "数据目录：") + NSHomeDirectory()
                     + (Self.hasDataContainer ? "" : Loc.s(" (không có container)", " (no container)", "（无容器）")))
        lines.append(probeResult ?? Loc.s("Đang thử WebKit tối giản…", "Testing a bare WebKit view…", "正在测试精简 WebKit…"))
        lines.append(Loc.s("Chụp màn hình này gửi iOSVN để được hỗ trợ.",
                           "Send a screenshot of this to iOSVN for help.",
                           "请截图发送给 iOSVN 以获取帮助。"))
        statusLabel.text = lines.joined(separator: "\n\n")
        statusPanel.isHidden = false
        webView.bringSubviewToFront(statusPanel)
        runProbe()
    }

    private func runProbe() {
        guard probe == nil, probeResult == nil, let webView else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: config)
        view.alpha = 0.01
        let delegate = ProbeDelegate { [weak self] ok in
            guard let self, self.probeResult == nil else { return }
            self.probeResult = ok
                ? Loc.s("WebKit tối giản: chạy được (lỗi nằm ở cấu hình trang).",
                        "Bare WebKit: works (the page configuration fails).",
                        "精简 WebKit：可以运行（问题在页面配置）。")
                : Loc.s("WebKit tối giản: cũng dừng (WebKit không chạy được trong bản cài này).",
                        "Bare WebKit: also stops (WebKit cannot run in this install).",
                        "精简 WebKit：同样停止（此安装方式下 WebKit 无法运行）。")
            self.probe?.removeFromSuperview()
            self.probe = nil
            self.show(self.headline)
        }
        view.navigationDelegate = delegate
        probeDelegate = delegate
        probe = view
        webView.addSubview(view)
        view.loadHTMLString("<html><body>ok</body></html>", baseURL: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    /// WebContent crashed or was killed: reload a couple of times, then explain.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        terminations += 1
        lastError = Loc.s("Tiến trình WebKit đã dừng (\(terminations) lần).",
                          "The WebKit process stopped (\(terminations) times).",
                          "WebKit 进程已停止（\(terminations) 次）。")
        if usingUpdate && !pageReady && terminations >= 2 && dropUpdate() {
            return
        }
        if terminations <= 2 {
            load(viaScheme: usingScheme || terminations == 2)
        } else {
            show(Loc.s("Giao diện chưa tải được.", "The interface did not load.", "界面未能加载。"))
        }
    }
}
