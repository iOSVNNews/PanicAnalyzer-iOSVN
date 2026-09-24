//  LocalHardware.swift
//  What this iPhone tells the app about its own parts without pairing.
//
//  - Face ID / Touch ID, every build: the public LocalAuthentication API. iOS
//    turns biometrics off when the sensor is broken or does not belong to this
//    iPhone ("Face ID is not available"), whatever the enrolment.
//  - Factory serials, TrollStore / jailbreak builds only: MobileGestalt's
//    protected "SysCfg" answer (the same key Apple's Diagnostics app reads)
//    holds the serials written at the factory (Batt, BCMS, FCMS, NSrN…).
//    The live battery and Touch ID serials come from BatterySerialNumber and
//    MesaSerialNumber, the keys corerepaird reads. A different serial means
//    the part is not the one this iPhone left the factory with.
//  - Camera modules, one entry each (rear main / ultra wide / tele, front,
//    TrueDepth IR camera and dot projector): the "…CameraModuleSerialNumber"
//    MobileGestalt keys and, for rear main / front, the factory BCMS / FCMS.
//    Not yet checked on an iPhone with a replaced camera that these keys give
//    the module fitted now, so the page reports a difference as "check", not
//    as "replaced".

import Foundation
import LocalAuthentication

enum LocalHardware {

    static func report(privileged: Bool) -> [String: Any] {
        var out: [String: Any] = ["biometrics": biometrics()]
        // The camera keys may also answer without the entitlement; SysCfg
        // (factory serials) needs it.
        let syscfg = privileged ? factorySysCfg() : nil
        if let syscfg {
            out["syscfgSource"] = syscfg.source
            out["syscfgKeys"] = syscfg.values.keys.sorted()
            let serials = factorySerials(syscfg.values)
            if !serials.isEmpty { out["syscfg"] = serials }
        }
        let cameras = cameraSerials(factory: syscfg?.values ?? [:])
        if !cameras.isEmpty { out["cameraSerials"] = cameras }
        return out
    }

    /// Camera modules: MobileGestalt key of the module and, where the factory
    /// wrote one, its SysCfg key. Keys from Apple's own entitlement lists
    /// (MobileGestalt AllowedProtectedKeys of Apple's repair tools).
    static let cameraModules: [(module: String, gestalt: String, factory: String?)] = [
        ("rear_main", "RearFacingCameraModuleSerialNumber", "BCMS"),
        ("rear_ultra_wide", "RearFacingSuperWideCameraModuleSerialNumber", nil),
        ("rear_tele", "RearFacingTelephotoCameraModuleSerialNumber", nil),
        ("front", "FrontFacingCameraModuleSerialNumber", "FCMS"),
        ("truedepth_ir", "FrontFacingIRCameraModuleSerialNumber", nil),
        ("truedepth_projector", "FrontFacingIRStructuredLightProjectorModuleSerialNumber", nil),
    ]

    /// One entry per module that answered: the MobileGestalt serial and the
    /// factory serial, each with the key it came from.
    static func cameraSerials(factory syscfg: [String: Any]) -> [[String: Any]] {
        cameraModules.compactMap { item in
            var entry: [String: Any] = ["module": item.module, "gestaltKey": item.gestalt]
            if let serial = serialText(gestalt(item.gestalt)) { entry["gestalt"] = serial }
            if let key = item.factory, let serial = serialText(syscfg[key]) {
                entry["factory"] = serial
                entry["factoryKey"] = key
            }
            return entry.count > 2 ? entry : nil
        }
    }

    // MARK: - Face ID / Touch ID

    static func biometrics() -> [String: Any] {
        let context = LAContext()
        var error: NSError?
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        var out: [String: Any] = [:]
        // biometryType is only filled in by canEvaluatePolicy.
        switch context.biometryType {
        case .faceID: out["part"] = "face_id"
        case .touchID: out["part"] = "touch_id"
        default:
            if let expected = expectedBiometry() { out["part"] = expected }
        }
        if usable {
            out["state"] = "ok"
        } else if let error {
            out["code"] = error.code
            switch error.code {
            case LAError.Code.biometryNotEnrolled.rawValue: out["state"] = "not_enrolled"
            case LAError.Code.biometryNotAvailable.rawValue: out["state"] = "not_available"
            case LAError.Code.biometryLockout.rawValue: out["state"] = "lockout"
            case LAError.Code.passcodeNotSet.rawValue: out["state"] = "passcode_not_set"
            default: out["state"] = "other"
            }
        }
        return out
    }

    /// Model identifier of this iPhone, e.g. "iPhone11,6".
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }

    /// The sensor this model ships with, when iOS reports none (a dead or
    /// rejected sensor can make biometryType come back empty).
    static func expectedBiometry(model: String = modelIdentifier) -> String? {
        let digits = model.dropFirst("iPhone".count).split(separator: ",").compactMap { Int($0) }
        guard model.hasPrefix("iPhone"), digits.count == 2 else { return nil }
        let (major, minor) = (digits[0], digits[1])
        if (major == 12 && minor == 8) || (major == 14 && minor == 6) { return "touch_id" }  // SE 2, SE 3
        if major < 10 || (major == 10 && [1, 2, 4, 5].contains(minor)) { return "touch_id" }  // ≤ iPhone 8
        return "face_id"
    }

    // MARK: - Factory serials (SysCfg)

    private typealias CopyAnswer = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?

    private static let copyAnswer: CopyAnswer? = {
        guard let handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY),
              let symbol = dlsym(handle, "MGCopyAnswer") else { return nil }
        return unsafeBitCast(symbol, to: CopyAnswer.self)
    }()

    static func gestalt(_ key: String) -> Any? {
        copyAnswer?(key as CFString)?.takeRetainedValue()
    }

    /// Readable text for a SysCfg value: printable ASCII as is, otherwise hex.
    static func serialText(_ value: Any?) -> String? {
        let raw: String
        switch value {
        case let string as String:
            raw = string
        case let data as Data:
            let bytes = data.prefix { $0 != 0 }
            if !bytes.isEmpty, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
                raw = String(decoding: bytes, as: UTF8.self)
            } else {
                raw = data.map { String(format: "%02X", $0) }.joined()
            }
        default:
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.allSatisfy({ $0 == "0" }) ? nil : trimmed
    }

    /// Same serial written differently (hex vs text, padding, case).
    static func sameSerial(_ first: String, _ second: String) -> Bool {
        let a = first.uppercased().filter { $0.isLetter || $0.isNumber }
        let b = second.uppercased().filter { $0.isLetter || $0.isNumber }
        guard a.count >= 6, b.count >= 6 else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// The factory SysCfg as a dictionary: "SysCfgDict" where iOS offers it,
    /// otherwise "SysCfg" (a dictionary, or raw data on some versions).
    static func factorySysCfg() -> (source: String, values: [String: Any])? {
        for key in ["SysCfgDict", "SysCfg"] {
            if let values = gestalt(key) as? [String: Any], !values.isEmpty { return (key, values) }
        }
        if let answer = gestalt("SysCfg") {
            // Unknown shape on this iOS version: keep its type for the raw data.
            return ("SysCfg:" + String(describing: type(of: answer)), [:])
        }
        return nil
    }

    /// Part, factory serial and — where iOS exposes it — the serial fitted now.
    /// Cameras are reported separately (cameraSerials).
    static func factorySerials(_ syscfg: [String: Any]) -> [[String: Any]] {
        guard !syscfg.isEmpty else { return [] }
        let parts: [(part: String, key: String, live: String?)] = [
            ("battery", "Batt", "BatterySerialNumber"),
            ("touch_id", "NSrN", "MesaSerialNumber"),
            ("display", "LCM#", nil),
        ]
        var out: [[String: Any]] = []
        for item in parts {
            guard let factory = serialText(syscfg[item.key]) else { continue }
            var entry: [String: Any] = ["part": item.part, "key": item.key, "factory": factory]
            if let liveKey = item.live, let current = serialText(gestalt(liveKey)) {
                entry["current"] = current
                entry["match"] = sameSerial(factory, current)
            }
            out.append(entry)
        }
        // Face ID sensor serials as corerepaird reads them.
        for key in ["RosalineSerialNumber", "SavageSerialNumber"] {
            if let current = serialText(gestalt(key)) {
                out.append(["part": "face_id", "key": key, "current": current])
            }
        }
        return out
    }
}
