//  PanicAnalyzerApp.swift

import SwiftUI

@main
struct PanicAnalyzerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var didRefreshRules = false

    var body: some Scene {
        WindowGroup {
            WebContainerView()
                .ignoresSafeArea()
                // Nhận file .ips mở bằng "Sao chép vào PanicAnalyzer"
                .onOpenURL { url in
                    LogBridge.shared.importFiles([url])
                }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            // Share Extension ghi file vào App Group -> nuốt khi app quay lại
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                LogBridge.shared.drainSharedInbox()
                // Pairing file iLoader / Files / Finder đặt vào Documents của app
                LogBridge.shared.importPairingFromDocuments(atLaunch: false)
            }
            // Tải bộ luật mới nhất, mỗi lần mở app một lần
            if !didRefreshRules {
                didRefreshRules = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    LogBridge.shared.refreshRules()
                }
            }
        }
    }
}
