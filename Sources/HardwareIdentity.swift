//  HardwareIdentity.swift
//  Turns IORegistry entries read through diagnostics_relay (lockdown +
//  heartbeat) into a small report for the Linh kiện tab. It only repeats what
//  the device itself states: the display authentication IC's "auth-passed"
//  flag (the check behind iOS's "Unknown Part" display warning) and battery
//  figures. It never guesses whether a part is original.

import Foundation

enum HardwareIdentity {

    /// Device-tree nodes that hold the display authentication IC. Apple renames
    /// them between generations, so the tree is also scanned for similar names.
    static let knownDisplayAuthNodes = ["mogul-display", "display-auth", "panel-auth"]
    static let maxCandidates = 16

    /// First pass. Display auth hardware differs by generation: newer iPhones
    /// keep an Apple-signed certificate + "auth-passed" on a device-tree node
    /// (mogul-display…); older ones relay through an I2C auth driver under
    /// display-eeprom (RoswellAuthI2CRelayInterface on iPhone 11). The battery
    /// has its own relay, AppleBatteryAuth. The two whole-plane dumps come
    /// last: they are the largest, and when the device resets the connection
    /// on one of them the small queries before it are already answered.
    enum First: Int, CaseIterable {
        case batteryByName, batteryByClass, panelByClass, panelByName,
             batteryAuth, roswellAuth, treeNames, serviceNames
    }

    /// Driver classes of other parts, read one by one on their own connection
    /// (names from real iPhone IORegistry trees and corerepaird's entitlements).
    /// Classes a model does not have simply answer "not found".
    static let componentClasses: [(part: String, className: String)] = [
        ("face_id", "ApplePearlSEPDriver"), ("face_id", "AppleH16PearlCam"),
        ("face_id", "AppleH13PearlCam"), ("face_id", "AppleH10PearlCam"),
        ("touch_id", "AppleMesaSEPDriver"), ("touch_id", "AppleSandDollar"),
        ("camera", "AppleH17CamIn"), ("camera", "AppleH16CamIn"),
        ("camera", "AppleH13CamIn"), ("camera", "AppleH10CamIn"),
        ("speaker", "AppleCS35L27Amp"), ("speaker", "AppleCS35L26Amp"),
        ("touch_panel", "AppleMultitouchDevice"), ("touch_panel", "AppleEmbeddedTouchEEPROMDriver"),
    ]

    static let componentPass: [[String: Any]] = componentClasses.map { ["class": $0.className] }

    static let firstPass: [[String: Any]] = First.allCases.map { (query: First) -> [String: Any] in
        switch query {
        case .treeNames: return ["plane": "IODeviceTree", "namesOnly": true, "scanKeys": true]
        case .batteryByName: return ["name": "AppleSmartBattery"]
        case .batteryByClass: return ["class": "AppleSmartBattery"]
        case .panelByClass: return ["class": "AppleCLCD2"]
        case .panelByName: return ["name": "AppleCLCD2"]
        case .batteryAuth: return ["class": "AppleBatteryAuth"]
        case .roswellAuth: return ["class": "RoswellAuthI2CRelayInterface"]
        case .serviceNames: return ["plane": "IOService", "namesOnly": true, "scanKeys": true]
        }
    }

    static func entry(_ results: [[String: Any]], _ query: First) -> [String: Any] {
        query.rawValue < results.count ? results[query.rawValue] : [:]
    }

    /// Nodes that may hold a display authentication result, newest naming first.
    static func displayAuthCandidates(treeNames: [String], serviceNames: [String]) -> [String] {
        var result = knownDisplayAuthNodes
        func add(_ name: String) {
            if result.count < maxCandidates, !result.contains(name) { result.append(name) }
        }
        for name in treeNames {
            let lower = name.lowercased()
            if lower.hasSuffix("-display") || lower.contains("display-auth") || lower.contains("panel-auth")
                || (lower.contains("display") && lower.contains("auth")) {
                add(name)
            }
        }
        // Auth drivers in the IOService plane, minus the Lightning accessory
        // (AuthCPAID), user clients, the generic relay child and the battery.
        for name in serviceNames {
            let lower = name.lowercased()
            if lower.contains("auth"), !lower.contains("userclient"), !lower.contains("authcpaid"),
               lower != "appleauthcprelay", lower != "applebatteryauth" {
                add(name)
            }
        }
        return result
    }

    // MARK: - Value decoding (IORegistry mixes numbers, strings and raw bytes)

    static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let data as Data where !data.isEmpty && data.count <= 8:
            return data.reversed().reduce(0) { ($0 << 8) | Int($1) }
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    static func text(_ value: Any?) -> String? {
        let raw: String?
        switch value {
        case let string as String:
            raw = string
        case let data as Data:
            raw = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        default:
            raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// commonName values inside a DER certificate, found without a crypto
    /// library (OID 2.5.4.3 followed by a short string).
    static func commonNames(in der: Data) -> [String] {
        let bytes = [UInt8](der)
        let oid: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
        var names: [String] = []
        var index = 0
        while index + oid.count + 2 <= bytes.count {
            guard Array(bytes[index..<index + oid.count]) == oid else { index += 1; continue }
            let tagIndex = index + oid.count
            let tag = bytes[tagIndex]
            let length = Int(bytes[tagIndex + 1])
            let start = tagIndex + 2
            if [0x0C, 0x13, 0x16].contains(tag), length < 0x80, start + length <= bytes.count,
               let name = String(bytes: bytes[start..<start + length], encoding: .ascii) {
                names.append(name)
            }
            index = start
        }
        return names
    }

    /// Module serial + auth IC serial, e.g. "G9N1234567890ABCDE-0123456789AB".
    static func panelSerial(in text: String) -> String? {
        guard let range = text.range(of: "[A-Z][A-Z0-9]{17}-[0-9A-F]{12}", options: .regularExpression) else { return nil }
        return String(text[range])
    }

    // MARK: - Report

    static func display(candidates: [(name: String, entry: [String: Any])],
                        panelEntries: [[String: Any]]) -> [String: Any] {
        for (name, entry) in candidates {
            guard let certificate = entry["certificate"] as? Data else { continue }
            let names = commonNames(in: certificate)
            let ascii = String(decoding: certificate.map { (32...126).contains($0) ? $0 : 32 }, as: UTF8.self)
            let serial = names.compactMap(panelSerial(in:)).first ?? panelSerial(in: ascii)
            var out: [String: Any] = ["node": name]
            if let serial {
                let parts = serial.split(separator: "-", maxSplits: 1).map(String.init)
                out["panelSerial"] = parts.first
                out["authICSerial"] = parts.count > 1 ? parts[1] : nil
            }
            out["authCA"] = names.first { $0.contains("CA") && !$0.contains("Root") }
            if let passed = integer(entry["auth-passed"]) {
                out["authPassed"] = passed != 0
            }
            return out
        }
        // Older nodes: the same "auth-passed" flag without a certificate.
        for (name, entry) in candidates {
            if let passed = integer(entry["auth-passed"]) {
                return ["node": name, "authPassed": passed != 0]
            }
        }
        for entry in panelEntries {
            if let panel = text(entry["Panel_ID"]) {
                return ["panelId": panel]
            }
        }
        return [:]
    }

    static func battery(from entries: [[String: Any]]) -> [String: Any] {
        guard let entry = entries.first(where: { $0["error"] == nil && ($0["Serial"] != nil || $0["CycleCount"] != nil) }) else {
            return [:]
        }
        let data = entry["BatteryData"] as? [String: Any] ?? [:]
        var out: [String: Any] = [:]
        out["serial"] = text(entry["Serial"])
        out["cycleCount"] = integer(entry["CycleCount"]) ?? integer(data["CycleCount"])
        let design = integer(data["DesignCapacity"]) ?? integer(entry["DesignCapacity"])
        let full = integer(data["FullChargeCapacity"]) ?? integer(entry["AppleRawMaxCapacity"])
        out["designCapacity"] = design
        out["fullChargeCapacity"] = full
        if let design, let full, design > 0, full > 0 {
            out["healthPercent"] = (Double(full) / Double(design) * 1000).rounded() / 10
        }
        // Settings › Battery "Maximum Capacity" is powerd's nominal figure, not
        // FullChargeCapacity: ceil(NominalChargeCapacity / DesignCapacity × 100)
        // (Apple PowerManagement, BatteryTimeRemaining.m rawToNominal). Use the
        // gauge's own MaximumCapacityPercent when it is published.
        let nominal = integer(entry["NominalChargeCapacity"]) ?? integer(data["NominalChargeCapacity"])
        let nominalBase = integer(entry["DesignCapacity"]) ?? design
        out["nominalChargeCapacity"] = nominal
        if let percent = integer(data["MaximumCapacityPercent"]) ?? integer(entry["MaximumCapacityPercent"]) {
            out["settingsHealthPercent"] = percent
        } else if let nominal, let nominalBase, nominal > 0, nominalBase > 0 {
            // Rounded down: 4269/4768 mAh = 89.5 % shows as 89 % in Settings.
            let percent = Int((Double(nominal) / Double(nominalBase) * 100).rounded(.down))
            if (1...150).contains(percent) { out["settingsHealthPercent"] = percent }
        }
        // Only flags whose name states success (1 = passed). Counters such as
        // "AuthFailures" must never turn into a verdict.
        var flags: [String: Int] = [:]
        for source in [entry, data] {
            for (key, value) in source where isPassFlagName(key) {
                if let number = integer(value), number == 0 || number == 1 { flags[key] = number }
            }
        }
        if !flags.isEmpty { out["authFlags"] = flags }
        return out
    }

    static func isPassFlagName(_ key: String) -> Bool {
        let lower = key.lowercased()
        let positive = ["auth-passed", "authpassed", "auth_passed", "authenticated", "isauthentic",
                        "authok", "auth-ok", "authvalid", "isgenuine", "genuine"]
        let negative = ["fail", "error", "count", "attempt", "retry", "time"]
        return positive.contains { lower.contains($0) } && !negative.contains { lower.contains($0) }
    }

    // MARK: - Battery authentication driver (AppleBatteryAuth)

    /// Reads what the battery authentication driver publishes. Per Apple's
    /// open-source PowerManagement (AppleSmartBatteryManager/AppleBatteryAuth.cpp):
    /// - "CommunicationError" / "CoProcError": set once when the auth chip inside
    ///   the battery does not answer over I2C or reports an error. Batteries
    ///   without Apple's auth chip fail exactly here.
    /// - a trusted-data "…Pass" boolean, set true/false after the challenge on
    ///   iOS versions that enable trusted battery data.
    /// The first entry is the driver itself (queried by class); the rest are
    /// battery nodes found by the property scan.
    static func batteryAuth(driver: [String: Any], scanned: [[String: Any]]) -> [String: Any] {
        var out: [String: Any] = [:]
        let driverFound = driver["error"] == nil && !driver.isEmpty
        if driverFound { out["driver"] = true }
        for props in (driverFound ? [driver] : []) + scanned {
            for key in props.keys.sorted() {
                let lower = key.lowercased()
                let value = props[key]
                if out["passed"] == nil, isTrustedPassKey(lower),
                   let number = integer(value), number == 0 || number == 1 {
                    out["passed"] = number == 1
                    out["passKey"] = key
                } else if out["commError"] == nil, lower == "communicationerror",
                          let number = integer(value), number != 0 {
                    out["commError"] = number
                } else if out["coprocError"] == nil, lower == "coprocerror",
                          let number = integer(value), number != 0 {
                    out["coprocError"] = number
                }
            }
        }
        return out
    }

    /// "TrustedBatteryAuthPass"-style names: a pass result, not a counter.
    static func isTrustedPassKey(_ lower: String) -> Bool {
        lower.contains("pass") && (lower.contains("trust") || lower.contains("auth"))
            && !["count", "retry", "fail", "time", "bypass"].contains { lower.contains($0) }
    }

    /// IOService names that look like battery or auth drivers, so the raw data
    /// shows how this iPhone generation names them.
    static func batteryNodeNames(_ names: [String]) -> [String] {
        var seen: [String] = []
        for name in names {
            let lower = name.lowercased()
            let batteryLike = lower.contains("batt") || lower.contains("gasgauge") || lower.contains("charger")
            let authLike = lower.contains("auth") && !lower.contains("userclient")
            if (batteryLike || authLike), !seen.contains(name) {
                seen.append(name)
                if seen.count == 30 { break }
            }
        }
        return seen
    }

    // MARK: - Property scan (finds auth nodes whatever they are called)

    struct Hit {
        let path: String
        let className: String?
        let props: [String: Any]
    }

    /// Nodes with auth/certificate-like properties from both plane scans.
    static func hits(in first: [[String: Any]]) -> [Hit] {
        [entry(first, .treeNames), entry(first, .serviceNames)].flatMap { result -> [Hit] in
            (result["hits"] as? [[String: Any]] ?? []).compactMap { item -> Hit? in
                guard let path = item["path"] as? String, let props = item["props"] as? [String: Any] else { return nil }
                return Hit(path: path, className: item["class"] as? String, props: props)
            }
        }
    }

    /// Which part a node belongs to, from its own name and class.
    static func part(of hit: Hit) -> String? {
        let leaf = hit.path.split(separator: "/").last.map(String.init) ?? hit.path
        let text = (leaf + " " + (hit.className ?? "")).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["display", "panel", "lcd", "oled"]) { return "display" }
        if has(["battery", "gasgauge", "gas-gauge"]) { return "battery" }
        if has(["pearl", "romeo", "juliet", "truedepth", "faceid"]) { return "face_id" }
        if has(["mesa", "touchid"]) { return "touch_id" }
        if has(["cam", "isp"]) {
            if text.contains("front") { return "front_camera" }
            if has(["rear", "back"]) { return "rear_camera" }
            return "camera"
        }
        return nil
    }

    /// The same "auth-passed" flag the newest iPhones put on mogul-display,
    /// found on any node of any part.
    static func partFlags(_ hits: [Hit]) -> [[String: Any]] {
        var seen = Set<String>()
        var flags: [[String: Any]] = []
        for hit in hits {
            guard let component = HardwareIdentity.part(of: hit), !seen.contains(component),
                  let key = hit.props.keys.first(where: { $0.lowercased() == "auth-passed" }),
                  let passed = integer(hit.props[key]) else { continue }
            seen.insert(component)
            flags.append(["part": component, "authPassed": passed != 0, "path": hit.path])
        }
        return flags
    }

    // MARK: - Other parts (Face ID, Touch ID, cameras, speakers, touch panel)

    /// A driver node the bridge kept whole because of the part it serves.
    struct ComponentNode {
        let part: String
        let hit: Hit
    }

    static func componentNodes(in first: [[String: Any]], classResults: [[String: Any]] = []) -> [ComponentNode] {
        var nodes: [ComponentNode] = []
        for (query, props) in zip(componentClasses, classResults) where props["error"] == nil && !props.isEmpty {
            nodes.append(ComponentNode(part: query.part,
                                       hit: Hit(path: query.className, className: query.className, props: props)))
        }
        for result in [entry(first, .treeNames), entry(first, .serviceNames)] {
            for item in result["components"] as? [[String: Any]] ?? [] {
                guard let part = item["part"] as? String, let path = item["path"] as? String,
                      let props = item["props"] as? [String: Any] else { continue }
                nodes.append(ComponentNode(part: part,
                                           hit: Hit(path: path, className: item["class"] as? String, props: props)))
            }
        }
        return nodes
    }

    /// Per part: how many driver nodes answered and the first pass flag any
    /// of them publishes (never a guess from counters or errors).
    static func componentSummary(_ nodes: [ComponentNode]) -> [[String: Any]] {
        var order: [String] = []
        var summary: [String: [String: Any]] = [:]
        for node in nodes {
            var item = summary[node.part] ?? ["part": node.part, "nodes": 0]
            item["nodes"] = (item["nodes"] as? Int ?? 0) + 1
            if item["authPassed"] == nil {
                for key in node.hit.props.keys.sorted() where isPassFlagName(key) {
                    if let number = integer(node.hit.props[key]), number == 0 || number == 1 {
                        item["authPassed"] = number == 1
                        item["flag"] = key
                        item["path"] = node.hit.path
                        break
                    }
                }
            }
            if summary[node.part] == nil { order.append(node.part) }
            summary[node.part] = item
        }
        return order.compactMap { summary[$0] }
    }

    // MARK: - Raw data (to learn the flag names of each iPhone generation)

    /// Short text for one IORegistry value.
    static func describe(_ value: Any) -> String {
        switch value {
        case let data as Data:
            let hex = data.prefix(16).map { String(format: "%02x", $0) }.joined()
            return "<\(data.count) byte\(data.count == 1 ? "" : "s")> \(hex)\(data.count > 16 ? "…" : "")"
        case let dict as [String: Any]:
            return "{\(dict.count) keys}"
        case let array as [Any]:
            return "[\(array.count) items]"
        default:
            let text = "\(value)"
            return text.count > 80 ? String(text.prefix(80)) + "…" : text
        }
    }

    /// Properties of auth-related entries, as sent to the UI for copying.
    static func rawEntries(_ entries: [(name: String, entry: [String: Any])], limit: Int = 30) -> [[String: Any]] {
        entries.compactMap { item -> [String: Any]? in
            let (name, entry) = item
            guard entry["error"] == nil, !entry.isEmpty else { return nil }
            var props: [String: String] = [:]
            for key in entry.keys.sorted().prefix(limit) {
                if let value = entry[key] { props[key] = describe(value) }
            }
            return ["name": name, "props": props]
        }
    }

    /// Everything the Linh kiện tab needs, from both passes.
    static func report(first: [[String: Any]], candidates: [String], second: [[String: Any]],
                       components classResults: [[String: Any]] = []) -> [String: Any] {
        let scanned = hits(in: first)
        let hitPairs = scanned.map { (name: $0.path, entry: $0.props) }
        let displayHits = zip(scanned, hitPairs).filter { HardwareIdentity.part(of: $0.0) == "display" }.map { $0.1 }
        let pairs = zip(candidates, second).map { (name: $0, entry: $1) } + displayHits
        let batteryAuth = entry(first, .batteryAuth)
        let roswell = entry(first, .roswellAuth)
        var batteryInfo = battery(from: [entry(first, .batteryByName), entry(first, .batteryByClass)])
        let auth = HardwareIdentity.batteryAuth(
            driver: batteryAuth,
            scanned: scanned.filter { HardwareIdentity.part(of: $0) == "battery" }.map { $0.props })
        if !auth.isEmpty { batteryInfo["auth"] = auth }
        var report: [String: Any] = [
            "display": display(candidates: pairs,
                               panelEntries: [entry(first, .panelByClass), entry(first, .panelByName)]),
            "battery": batteryInfo
        ]
        let flags = partFlags(scanned)
        if !flags.isEmpty { report["parts"] = flags }
        let components = componentNodes(in: first, classResults: classResults)
        let componentList = componentSummary(components)
        if !componentList.isEmpty { report["components"] = componentList }
        var raw = rawEntries(Array(zip(candidates, second).map { (name: $0, entry: $1) }))
        raw += rawEntries([(name: "AppleBatteryAuth", entry: batteryAuth),
                           (name: "RoswellAuthI2CRelayInterface", entry: roswell)])
        raw += rawEntries(Array(hitPairs.prefix(40)))
        raw += rawEntries(components.prefix(40).map { (node: ComponentNode) -> (name: String, entry: [String: Any]) in
            let leaf = node.hit.path.split(separator: "/").last.map(String.init) ?? node.hit.path
            return (name: "\(node.part): \(leaf)", entry: node.hit.props)
        }, limit: 60)
        if !raw.isEmpty { report["raw"] = raw }
        report["probe"] = [
            "treeNames": (entry(first, .treeNames)["names"] as? [Any])?.count ?? 0,
            "serviceNames": (entry(first, .serviceNames)["names"] as? [Any])?.count ?? 0,
            "hits": scanned.count,
            "candidates": candidates,
            "batteryNodes": batteryNodeNames(
                (entry(first, .serviceNames)["names"] as? [Any])?.compactMap { $0 as? String } ?? [])
        ] as [String: Any]
        // The two whole-plane dumps are best effort (the device sometimes
        // resets the connection on them): their errors go to the raw data
        // only, the screen reports errors of the reads that matter.
        let dumps: Set<Int> = [First.treeNames.rawValue, First.serviceNames.rawValue]
        let mainEntries = first.enumerated().filter { !dumps.contains($0.offset) }.map { $0.element }
        let errorList = errors(in: mainEntries + second)
        if !errorList.isEmpty { report["errors"] = errorList }
        let dumpErrors = errors(in: [entry(first, .treeNames), entry(first, .serviceNames)])
        if !dumpErrors.isEmpty, var probe = report["probe"] as? [String: Any] {
            probe["scanErrors"] = dumpErrors
            report["probe"] = probe
        }
        return report
    }

    /// First few errors, so the UI can say what could not be read.
    static func errors(in entries: [[String: Any]]) -> [String] {
        var seen: [String] = []
        // "non-Success Status" = that node does not exist on this model: expected
        // while probing candidate names, not worth showing.
        for message in entries.compactMap({ $0["error"] as? String })
        where !seen.contains(message) && !message.contains("non-Success") {
            seen.append(message)
            if seen.count == 3 { break }
        }
        return seen
    }
}
