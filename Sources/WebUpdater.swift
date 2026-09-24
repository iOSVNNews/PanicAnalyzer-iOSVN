//  WebUpdater.swift
//  Small fixes without a new app version: the interface (web/*.html, js,
//  css) is updated from the repository, like the rule files.
//
//  The repository publishes assets/web_update.json:
//    {"webBuild": 12, "nativeApi": 1, "files": {"app.js": "<sha256>", …}}
//  A newer build is downloaded from web/ on main, every file is checked
//  against its SHA-256, and it is used from the next launch (or at once when
//  the user taps "apply"). A build that needs a newer native side
//  (nativeApi) is ignored until the app itself is updated; a build whose page
//  does not start is never used again. Native changes still need a new app
//  version.

import Foundation
import CryptoKit

final class WebUpdater {

    static let shared = WebUpdater()

    /// Native bridge level of this app. Bump when the page starts relying on
    /// a new native action; web builds asking for more wait for the app update.
    static let nativeApi = 1

    private let baseURL = "https://raw.githubusercontent.com/iOSVNNews/PanicAnalyzer-iOSVN/main/"
    private let allowedFiles: Set<String> = ["index.html", "app.js", "parts.js", "i18n.js", "app.css"]
    private let lock = NSLock()

    private var rootDir: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.iosvn.panicanalyzer.web", isDirectory: true)
    }
    private var activeDir: URL? { rootDir?.appendingPathComponent("active", isDirectory: true) }
    private var pendingDir: URL? { rootDir?.appendingPathComponent("pending", isDirectory: true) }
    private var badURL: URL? { rootDir?.appendingPathComponent("bad.json") }

    /// Set when the downloaded page failed this session: serve the bundle.
    private var disabledForSession = false
    private var checking = false

    // MARK: - Builds

    private static func manifest(at url: URL?) -> [String: Any]? {
        guard let url, let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// Build number of the web files inside the app bundle.
    let bundledBuild: Int

    private init() {
        let url = Bundle.main.url(forResource: "web_update", withExtension: "json", subdirectory: "assets")
        bundledBuild = Self.manifest(at: url)?["webBuild"] as? Int ?? 0
    }

    private var badBuild: Int? {
        Self.manifest(at: badURL)?["webBuild"] as? Int
    }

    private func usableBuild(in dir: URL?) -> Int? {
        guard let dir, let manifest = Self.manifest(at: dir.appendingPathComponent("manifest.json")),
              let build = manifest["webBuild"] as? Int, build > bundledBuild, build != badBuild,
              (manifest["nativeApi"] as? Int ?? Int.max) <= Self.nativeApi,
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path)
        else { return nil }
        return build
    }

    /// Downloaded build served now, or nil when the bundled page is used.
    var activeBuild: Int? {
        lock.lock(); defer { lock.unlock() }
        return disabledForSession ? nil : usableBuild(in: activeDir)
    }

    /// Build number shown in Settings.
    var currentBuild: Int { activeBuild ?? bundledBuild }

    /// Moves a verified download into place. Called before the page loads.
    /// Files the update does not carry (logo.png…) are copied from the
    /// bundle, so the folder can be loaded on its own as file://.
    @discardableResult
    func promotePending() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let pending = pendingDir, let active = activeDir, usableBuild(in: pending) != nil else { return false }
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true),
           let names = try? fm.contentsOfDirectory(atPath: bundled.path) {
            for name in names where !fm.fileExists(atPath: pending.appendingPathComponent(name).path) {
                try? fm.copyItem(at: bundled.appendingPathComponent(name), to: pending.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: active)
        do {
            try fm.moveItem(at: pending, to: active)
            disabledForSession = false
            return true
        } catch {
            return false
        }
    }

    /// A downloaded build is waiting for the next start (or "apply now").
    var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return usableBuild(in: pendingDir) != nil
    }

    /// Folder holding the downloaded page, when one is in use.
    var activeDirectory: URL? { activeBuild == nil ? nil : activeDir }

    /// web/<name> from the downloaded build, when one is in use.
    func overrideFile(_ name: String) -> URL? {
        guard allowedFiles.contains(name), let dir = activeDirectory else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Same for a panicanalyzer://app/web/<name> request.
    func overrideFile(for url: URL) -> URL? {
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "web" else { return nil }
        return overrideFile(String(parts[1]))
    }

    /// The downloaded page did not start: back to the bundle, never retry it.
    func rejectActiveBuild() {
        guard let build = activeBuild, let badURL else { return }
        lock.lock(); defer { lock.unlock() }
        if let root = rootDir { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        disabledForSession = true
        if let data = try? JSONSerialization.data(withJSONObject: ["webBuild": build]) {
            try? data.write(to: badURL, options: .atomic)
        }
    }

    // MARK: - Download

    /// Looks for a newer web build and downloads it into "pending".
    /// Calls back on the main queue with the new build number, or nil.
    func checkForUpdate(completion: @escaping (Int?) -> Void) {
        let finish: (Int?) -> Void = { build in DispatchQueue.main.async { completion(build) } }
        lock.lock()
        if checking { lock.unlock(); return finish(nil) }
        checking = true
        lock.unlock()
        let done: (Int?) -> Void = { [weak self] build in
            self?.lock.lock(); self?.checking = false; self?.lock.unlock()
            finish(build)
        }
        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 40
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return config
        }())
        guard let url = URL(string: baseURL + "assets/web_update.json") else { return done(nil) }
        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self, let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let build = manifest["webBuild"] as? Int,
                  let files = manifest["files"] as? [String: String],
                  (manifest["nativeApi"] as? Int ?? Int.max) <= Self.nativeApi,
                  build > max(self.bundledBuild, self.activeBuild ?? 0, self.usableBuild(in: self.pendingDir) ?? 0),
                  build != self.badBuild,
                  files["index.html"] != nil, Set(files.keys).isSubset(of: self.allowedFiles)
            else { return done(nil) }
            self.download(files: files, manifest: data, session: session) { ok in done(ok ? build : nil) }
        }.resume()
    }

    private func download(files: [String: String], manifest: Data, session: URLSession,
                          completion: @escaping (Bool) -> Void) {
        guard let root = rootDir else { return completion(false) }
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return completion(false)
        }
        let group = DispatchGroup()
        let results = NSLock()
        var ok = true
        for (name, expected) in files {
            guard let url = URL(string: baseURL + "web/" + name) else { ok = false; continue }
            group.enter()
            session.dataTask(with: url) { data, response, _ in
                defer { group.leave() }
                let hash = data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                      hash == expected.lowercased(),
                      (try? data.write(to: staging.appendingPathComponent(name), options: .atomic)) != nil
                else {
                    results.lock(); ok = false; results.unlock()
                    return
                }
            }.resume()
        }
        group.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self, ok, (try? manifest.write(to: staging.appendingPathComponent("manifest.json"))) != nil,
                  let pending = self.pendingDir
            else {
                try? fm.removeItem(at: staging)
                return completion(false)
            }
            self.lock.lock()
            try? fm.removeItem(at: pending)
            let moved = (try? fm.moveItem(at: staging, to: pending)) != nil
            self.lock.unlock()
            if !moved { try? fm.removeItem(at: staging) }
            completion(moved)
        }
    }
}
