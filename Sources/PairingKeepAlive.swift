//  PairingKeepAlive.swift
//  While the user is in Settings typing the PIN, PanicAnalyzer is in the
//  background but must keep answering iOS's pairing messages. A background task
//  gives ~30 s; a silent, mixable audio loop (UIBackgroundModes: audio) keeps the
//  process alive for the rest of the pairing window. Both stop as soon as pairing
//  ends. The PIN is also posted as a local notification and copied to the
//  clipboard so it can be pasted in Settings.

import UIKit
import AVFoundation
import UserNotifications

final class PairingKeepAlive {

    static let shared = PairingKeepAlive()

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var player: AVAudioPlayer?
    private let notificationID = "panicanalyzer.pairing.pin"

    /// Call on the main queue.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RemotePairing") { [weak self] in
            self?.endBackgroundTask()
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV())
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            self.player = player
        } catch {
            // The background task alone still covers a quick pairing.
            player = nil
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Call on the main queue.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let player {
            player.stop()
            self.player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        endBackgroundTask()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    func showPin(_ pin: String) {
        UIPasteboard.general.string = pin
        let content = UNMutableNotificationContent()
        content.title = "Mã ghép đôi PanicAnalyzer: \(pin)"
        content.body = "Nhập mã này trong Cài đặt > Quyền riêng tư & Bảo mật > Nhà phát triển. Mã đã được sao chép."
        content.sound = .default
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// One second of 8 kHz mono 16-bit silence as an in-memory WAV file.
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let samples = sampleRate
        let dataSize = samples * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))            // PCM, mono
        append(sampleRate); append(sampleRate * 2)      // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16))           // block align, bits
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
