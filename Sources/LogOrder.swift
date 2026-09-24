//  LogOrder.swift
//  Which logs to read first when there are more than one scan can take
//  (100 files / 24 MB over pairing, 200 files / 24 MB on TrollStore/JB):
//  kernel panics first — the reason the app exists — then everything else,
//  each newest first. CrashReporter puts the time in every file name
//  ("panic-full-2026-09-24-101530.000.ips", "App-2026-09-24-101530.ips").

import Foundation

enum LogOrder {

    private static let stamp = try? NSRegularExpression(pattern: #"(\d{4})-(\d{2})-(\d{2})-(\d{6})"#)

    /// "20260924101530" for a CrashReporter file name, nil without a date.
    static func stamp(in path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let range = NSRange(name.startIndex..., in: name)
        guard let match = stamp?.firstMatch(in: name, range: range) else { return nil }
        return (1...4).compactMap { Range(match.range(at: $0), in: name).map { String(name[$0]) } }.joined()
    }

    static func isPanic(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name.hasPrefix("panic-") || name.hasSuffix(".panic")
    }

    /// Panics first, then newest first; `dates` (file modification times)
    /// wins over the date in the name when known.
    static func sorted(_ paths: [String], dates: [String: Date] = [:]) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        func key(_ path: String) -> String {
            if let date = dates[path] { return formatter.string(from: date) }
            return stamp(in: path) ?? ""
        }
        let keys = Dictionary(paths.map { ($0, key($0)) }, uniquingKeysWith: { first, _ in first })
        return paths.sorted { a, b in
            let (pa, pb) = (isPanic(a), isPanic(b))
            if pa != pb { return pa }
            let (ka, kb) = (keys[a] ?? "", keys[b] ?? "")
            if ka != kb { return ka > kb }
            return a < b
        }
    }

    /// What a scan read out of what it found, for the page.
    static func summary(found: Int, read: Int, maxFiles: Int, maxBytes: Int) -> [String: Any] {
        ["found": found, "read": read, "maxFiles": maxFiles, "maxMB": maxBytes / (1024 * 1024),
         "truncated": read < found]
    }
}
