//  ShareViewController.swift
//  Share Extension - nhận file .ips từ Share Sheet của iOS.
//
//  Luồng: Cài đặt -> Quyền riêng tư & Bảo mật -> Phân tích & Cải thiện
//         -> Dữ liệu phân tích -> chọn file panic -> Chia sẻ -> PanicAnalyzer
//
//  Extension chỉ COPY file vào hộp thư App Group rồi thoát. App chính
//  đọc hộp thư đó mỗi khi quay lại foreground.

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private let appGroupID = "group.com.iosvn.panicanalyzer"
    private let queue = DispatchQueue(label: "share.inbox")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        receiveFiles()
    }

    private func inboxURL() -> URL? {
        guard let c = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let inbox = c.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    private func receiveFiles() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { return finish(saved: 0, reason: "Không có file nào") }
        guard let inbox = inboxURL() else {
            return finish(saved: 0, reason: "Không mở được vùng chia sẻ App Group")
        }

        var saved = 0
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                // Bản sao tạm bị xoá ngay khi closure kết thúc -> phải copy đồng bộ
                let name = url.lastPathComponent.isEmpty ? "shared.ips" : url.lastPathComponent
                let dst = inbox.appendingPathComponent(self.uniqueName(name, in: inbox))
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    self.queue.sync { saved += 1 }
                } catch { }
            }
        }

        group.notify(queue: .main) {
            self.finish(saved: saved, reason: saved == 0 ? "Không đọc được file" : nil)
        }
    }

    private func uniqueName(_ name: String, in dir: URL) -> String {
        var candidate = name
        var i = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            i += 1
        }
        return candidate
    }

    private func finish(saved: Int, reason: String?) {
        let title = saved > 0 ? "Đã nhận \(saved) log" : "Không nhận được log"
        let msg = saved > 0 ? "Mở PanicAnalyzer để xem kết quả phân tích." : reason
        let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Xong", style: .default) { _ in
            self.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }
}
