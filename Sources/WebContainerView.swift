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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        LogBridge.shared.webView = webView

        if let index = Bundle.main.url(forResource: "index",
                                       withExtension: "html",
                                       subdirectory: "web") {
            // Cấp quyền đọc cả bundle để ../Resources/ truy cập được
            webView.loadFileURL(index, allowingReadAccessTo: Bundle.main.bundleURL)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
