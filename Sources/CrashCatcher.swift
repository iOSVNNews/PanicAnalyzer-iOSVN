//  CrashCatcher.swift
//  When PanicAnalyzer itself crashes, the next start says so and offers to
//  send the details to iOSVN (the app cannot read the system crash folder
//  without pairing or TrollStore).
//
//  Three sources, newest first in the list shown to the page:
//  - a signal handler (SIGSEGV, SIGABRT, Swift traps…) that writes the signal
//    and a backtrace to a file opened at start-up;
//  - the Objective-C uncaught-exception handler;
//  - MetricKit crash diagnostics, which iOS hands over on a later start with
//    the full call stack.

import Foundation
import MetricKit
import Darwin

/// What the signal handler needs, set up before any crash can happen. It is
/// reached through a constant pointer: the handler may only touch plain
/// memory (no allocation, no Swift runtime checks).
private struct CrashState {
    var fd: Int32 = -1
    var header: UnsafeMutablePointer<CChar>?
    var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    var digits: UnsafeMutablePointer<CChar>?
}

private let crashState: UnsafeMutablePointer<CrashState> = {
    let state = UnsafeMutablePointer<CrashState>.allocate(capacity: 1)
    state.initialize(to: CrashState())
    return state
}()
private let crashFrameCapacity: Int32 = 64
private let crashDigitCapacity = 24

private func writeStatic(_ text: StaticString) {
    _ = write(crashState.pointee.fd, text.utf8Start, text.utf8CodeUnitCount)
}

/// Decimal output without allocating.
private func writeNumber(_ value: Int) {
    guard let digits = crashState.pointee.digits else { return }
    var number = value < 0 ? 0 : value
    var index = crashDigitCapacity - 1
    repeat {
        digits[index] = CChar(48 + number % 10)
        number /= 10
        index -= 1
    } while number > 0 && index >= 0
    _ = write(crashState.pointee.fd, digits + index + 1, crashDigitCapacity - 1 - index)
}

private func handleCrashSignal(_ signalNumber: Int32) {
    let state = crashState.pointee
    if state.fd >= 0 {
        if let header = state.header { _ = write(state.fd, header, strlen(header)) }
        writeStatic("signal ")
        writeNumber(Int(signalNumber))
        writeStatic("\ntime ")
        writeNumber(time(nil))
        writeStatic("\n")
        if let frames = state.frames {
            let count = backtrace(frames, crashFrameCapacity)
            backtrace_symbols_fd(frames, count, state.fd)
        }
        fsync(state.fd)
    }
    // Let iOS write its own crash report as usual.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

final class CrashCatcher: NSObject {

    static let shared = CrashCatcher()
    private let maxReports = 5
    private let maxReportBytes = 60_000

    private var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.iosvn.panicanalyzer.crashes", isDirectory: true)
    }
    private var signalFile: URL? { directory?.appendingPathComponent("signal.log") }

    /// Call once, as early as possible.
    func install() {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keepSignalLogOfLastRun()

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let header = "PanicAnalyzer \(version) (\(build)) · web \(WebUpdater.shared.currentBuild)"
            + " · iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            + " · \(LocalHardware.modelIdentifier)\n"
        crashState.pointee.header = strdup(header)
        crashState.pointee.frames = .allocate(capacity: Int(crashFrameCapacity))
        crashState.pointee.digits = .allocate(capacity: crashDigitCapacity)
        if let path = signalFile?.path {
            crashState.pointee.fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(signalNumber, handleCrashSignal)
        }
        NSSetUncaughtExceptionHandler { exception in
            CrashCatcher.shared.save(kind: "exception",
                                     title: "\(exception.name.rawValue): \(exception.reason ?? "")",
                                     text: exception.callStackSymbols.joined(separator: "\n"))
        }
        MXMetricManager.shared.add(self)
        receive(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    /// A non-empty signal.log means the previous run crashed.
    private func keepSignalLogOfLastRun() {
        guard let file = signalFile, let data = try? Data(contentsOf: file), !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        let number = text.components(separatedBy: "\n")
            .first { $0.hasPrefix("signal ") }
            .flatMap { Int32($0.dropFirst(7)) }
        var date = Date()
        if let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("time ") }),
           let seconds = TimeInterval(line.dropFirst(5)) {
            date = Date(timeIntervalSince1970: seconds)
        }
        save(kind: "signal", title: number.map(Self.signalName) ?? "signal", text: text, date: date)
        try? FileManager.default.removeItem(at: file)
    }

    static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGABRT: return "SIGABRT"
        case SIGFPE: return "SIGFPE"
        default: return "signal \(number)"
        }
    }

    /// Mach exception types as crash reports name them.
    static func exceptionName(_ type: Int) -> String {
        switch type {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        default: return "exception \(type)"
        }
    }

    // MARK: - Stored reports

    private func save(kind: String, title: String, text: String, date: Date = Date()) {
        guard let directory else { return }
        let id = "\(kind)-\(Int(date.timeIntervalSince1970))"
        let file = directory.appendingPathComponent("\(id).json")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let report: [String: Any] = [
            "id": id, "kind": kind, "title": title,
            "time": ISO8601DateFormatter().string(from: date),
            "text": String(text.prefix(maxReportBytes))
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: file, options: .atomic)
        }
        trim()
    }

    private func reportFiles() -> [URL] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    private func trim() {
        for file in reportFiles().dropFirst(maxReports) { try? FileManager.default.removeItem(at: file) }
    }

    /// Reports not dismissed yet, newest first, for window.__APP_CRASHES__.
    func reports() -> [[String: Any]] {
        reportFiles().compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    /// The user sent or dismissed them.
    func clear() {
        for file in reportFiles() { try? FileManager.default.removeItem(at: file) }
    }
}

// MARK: - MetricKit

extension CrashCatcher: MXMetricManagerSubscriber {

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        receive(payloads)
    }

    fileprivate func receive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var title = [crash.exceptionType.map { Self.exceptionName($0.intValue) },
                             crash.signal.map { Self.signalName($0.int32Value) }]
                    .compactMap { $0 }.joined(separator: " · ")
                if let reason = crash.terminationReason, !reason.isEmpty { title += " · " + reason }
                let json = String(decoding: crash.jsonRepresentation(), as: UTF8.self)
                save(kind: "metrickit", title: title.isEmpty ? "crash" : title,
                     text: json, date: payload.timeStampEnd)
            }
        }
    }
}
