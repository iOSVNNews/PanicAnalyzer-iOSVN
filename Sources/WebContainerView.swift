//  WebContainerView.swift
//  Host WKWebView load ui/index.html — thay cho đoạn dựng WebView trong script.js

import SwiftUI
import WebKit

struct WebContainerView: UIViewRepresentable {

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()

        // QUAN TRỌNG: fetch('../Resources/*.json') bị CORS chặn trên file:// trong WKWebView.
        // Nên nạp sẵn toàn bộ rule database vào trang trước khi app.js chạy.
        ucc.addUserScript(WKUserScript(source: LogBridge.shared.injectionScript(),
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true))

        // Giữ nguyên tên "nativeBridge" để ui/app.js không phải sửa
        ucc.add(LogBridge.shared, name: "nativeBridge")
        config.userContentController = ucc
        config.allowsInlineMediaPlayback = true

        // Bản .deb (cài vào /Applications, không có sandbox container) có thể
        // không cho WebContent đọc file:// trong bundle: phục vụ trang qua
        // scheme riêng thay vì file://. Xem WebLoadMonitor.
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        LogBridge.shared.webView = webView
        // Tải trang và hiện lỗi rõ ràng thay vì màn đen nếu trang không chạy.
        WebLoadMonitor.shared.attach(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
