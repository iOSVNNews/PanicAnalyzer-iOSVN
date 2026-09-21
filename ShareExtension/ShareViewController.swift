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
    private let maxFiles = 20
    private let maxFileBytes = 12 * 1024 * 1024

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

        for provider in providers.prefix(maxFiles) {
            group.enter()
            guard let typeIdentifier = preferredTypeIdentifier(for: provider) else {
                group.leave()
                continue
            }
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                defer { group.leave() }
                guard let data, !data.isEmpty, data.count <= self.maxFileBytes else { return }
                let didSave = self.queue.sync {
                    let name = self.safeName(provider.suggestedName)
                    let destination = inbox.appendingPathComponent(self.uniqueName(name, in: inbox))
                    do {
                        try data.write(to: destination, options: [.atomic])
                        try? FileManager.default.setAttributes(
                            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                            ofItemAtPath: destination.path
                        )
                        return true
                    } catch {
                        return false
                    }
                }
                if didSave { self.queue.sync { saved += 1 } }
            }
        }

        group.notify(queue: .main) {
            self.finish(saved: saved, reason: saved == 0 ? "Không đọc được file" : nil)
        }
    }

    private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) || type.conforms(to: .plainText)
        }
    }

    private func safeName(_ suggestedName: String?) -> String {
        var name = ((suggestedName ?? "shared-log") as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
        if name.isEmpty { name = "shared-log" }
        let lower = name.lowercased()
        let supported = [".ips", ".crash", ".panic", ".synced", ".txt"]
            .contains { lower.hasSuffix($0) }
        if !supported { name += ".ips" }
        return name
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
        if saved > 0 {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        let title = "Không nhận được log"
        let msg = reason
        let alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Xong", style: .default) { _ in
            self.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }
}
