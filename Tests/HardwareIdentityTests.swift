import Foundation

// IORegistry answers of several iPhone generations → the Linh kiện report.
// Run on macOS CI: swiftc Sources/HardwareIdentity.swift Sources/LocalHardware.swift <this file>.
// The iPhone 14 Pro Max entries are copied from a real iOS 27 scan.
@main
struct HardwareIdentityTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            print("FAILED: \(message)")
            exit(1)
        }
    }

    typealias Entry = [String: Any]
    static let notFound: Entry = ["error": "IORegistry: non-Success Status"]

    /// First pass in HardwareIdentity.First order; missing queries answer "not found".
    static func firstPass(_ entries: [HardwareIdentity.First: Entry]) -> [Entry] {
        HardwareIdentity.First.allCases.map { entries[$0] ?? notFound }
    }

    static func report(_ first: [HardwareIdentity.First: Entry], second: [String: Entry] = [:],
                       components: [String: Entry] = [:]) -> [String: Any] {
        let pass = firstPass(first)
        let candidates = HardwareIdentity.displayAuthCandidates(
            treeNames: HardwareIdentity.entry(pass, .treeNames)["names"] as? [String] ?? [],
            serviceNames: HardwareIdentity.entry(pass, .serviceNames)["names"] as? [String] ?? [])
        let secondPass = candidates.map { second[$0] ?? notFound }
        let componentPass = HardwareIdentity.componentClasses.map { components[$0.className] ?? notFound }
        return HardwareIdentity.report(first: pass, candidates: candidates, second: secondPass,
                                       components: componentPass)
    }

    /// DER fragment with a commonName, as in the display auth certificate.
    static func certificate(commonName: String) -> Data {
        var bytes: [UInt8] = [0x30, 0x10, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0C, UInt8(commonName.utf8.count)]
        bytes += Array(commonName.utf8)
        return Data(bytes)
    }

    static let battery14: Entry = [
        "Serial": "F5D3266045420J8A5", "CycleCount": 1317, "DesignCapacity": 4297,
        "NominalChargeCapacity": 3265,
        "BatteryData": ["DesignCapacity": 4297, "FullChargeCapacity": 3397] as Entry
    ]

    static let camera14: Entry = [
        "IOClass": "AppleH13CamIn",
        "BackCameraModuleSerialNumString": "DN83156CUMN1CDK2U",
        "BackSuperWideCameraModuleSerialNumString": "DNL32163BAJ15FY1X",
        "BackTeleCameraModuleSerialNumString": "GCF320245WL1CY057",
        "FrontCameraModuleSerialNumString": "GCF31712HJU1CXC37",
        "FrontIRCameraModuleSerialNumString": "HNQ3191058P15F81B",
        "FrontIRStructuredLightProjectorSerialNumString": "A227C700044012480",
        "JasperSNUM": "HNQ31934U82Q7PX1D",
        "BackCameraSNUM": "",
        "BackCameraExpected": true, "BackCameraActive": false, "BackDepthCameraExpected": true,
        "FrontCameraSerialNumber": Data([0x27, 0x27, 0x20, 0x59, 0xce, 0x28, 0, 0]),
        "CmClValidationStatus": "Pass", "FCClValidationStatus": "Pass", "CmPMValidationStatus": "Invalid"
    ]

    static func run() {
        // iPhone 14 Pro Max (iPhone15,3), iOS 27: battery figures, no display
        // auth result, trusted battery data off, every camera module.
        let r14 = report([
            .batteryByName: battery14, .batteryByClass: battery14,
            .panelByClass: ["Panel_ID": "GVC31971YGZ14YFAK+A2CH343K26A118111K10"],
            .batteryAuth: ["PackIndex": 0, "TrustedBatteryEnabled": 0],
            .treeNames: ["names": ["device-tree", "arm-io", "i2c3", "hpm0", "display-eeprom"]],
            .serviceNames: ["names": ["AppleSmartBattery", "AppleBatteryAuth", "AppleAuthCPAID", "AppleAuthCPDock"]]
        ], components: ["AppleH13CamIn": camera14])
        let display14 = r14["display"] as? Entry ?? [:]
        expect(display14["authPassed"] == nil, "14: no display flag invented")
        expect((display14["panelId"] as? String)?.hasPrefix("GVC") == true, "14: panel id read")
        let battery = r14["battery"] as? Entry ?? [:]
        expect(battery["settingsHealthPercent"] as? Int == 75, "14: Settings health 75 %")
        expect(battery["cycleCount"] as? Int == 1317, "14: cycles")
        let auth14 = battery["auth"] as? Entry ?? [:]
        expect(auth14["driver"] as? Bool == true, "14: battery auth driver present")
        expect(auth14["trustedEnabled"] as? Bool == false, "14: trusted battery data off")
        expect(auth14["passed"] == nil, "14: no battery verdict")
        let cameras = r14["cameras"] as? [Entry] ?? []
        let modules = Dictionary(uniqueKeysWithValues: cameras.compactMap { item -> (String, String)? in
            guard let module = item["module"] as? String, let serial = item["serial"] as? String else { return nil }
            return (module, serial)
        })
        expect(modules["back"] == "DN83156CUMN1CDK2U", "14: rear main serial")
        expect(modules["back_super_wide"] == "DNL32163BAJ15FY1X", "14: ultra wide serial")
        expect(modules["back_tele"] == "GCF320245WL1CY057", "14: tele serial")
        expect(modules["front"] == "GCF31712HJU1CXC37", "14: front serial")
        expect(modules["front_ir"] == "HNQ3191058P15F81B", "14: TrueDepth IR serial")
        expect(modules["front_ir_structured_light"] == "A227C700044012480", "14: dot projector serial")
        expect(modules["lidar"] == "HNQ31934U82Q7PX1D", "14: LiDAR serial")
        expect(modules["back_camera_snum"] == nil && !modules.values.contains(""), "14: empty serials skipped")
        let validation = r14["cameraValidation"] as? [String: String] ?? [:]
        expect(validation["CmClValidationStatus"] == "Pass", "14: rear camera validation")
        expect(validation["FCClValidationStatus"] == "Pass", "14: front camera validation")
        expect((r14["errors"] as? [String] ?? []).isEmpty, "14: 'not found' answers are not errors")

        // iPhone 17 Pro Max (iPhone18,2): mogul-display certificate + auth-passed,
        // BatteryAuthPassed on AppleBatteryAuth.
        let r17 = report([
            .batteryByClass: battery14,
            .batteryAuth: ["TrustedBatteryEnabled": 1, "BatteryAuthPassed": true],
            .treeNames: ["names": ["mogul-display", "mogul-mlb"]]
        ], second: ["mogul-display": [
            "certificate": certificate(commonName: "G9N1234567890ABCDE-0123456789AB"), "auth-passed": 1
        ]])
        let display17 = r17["display"] as? Entry ?? [:]
        expect(display17["authPassed"] as? Bool == true, "17: display auth passed")
        expect(display17["panelSerial"] as? String == "G9N1234567890ABCDE", "17: panel serial from certificate")
        let auth17 = (r17["battery"] as? Entry)?["auth"] as? Entry ?? [:]
        expect(auth17["passed"] as? Bool == true, "17: battery auth passed")
        expect(auth17["trustedEnabled"] as? Bool == true, "17: trusted battery data on")

        // iPhone 11 (iPhone12,1): roswell with auth-passed, no certificate.
        let r11 = report([.treeNames: ["names": ["roswell", "display-eeprom"]]],
                         second: ["roswell": ["compatible": "roswell", "auth-passed": 0]])
        expect((r11["display"] as? Entry)?["authPassed"] as? Bool == false, "11: failed display auth reported")

        // iPhone 12 mini: babbage is queried by name.
        let candidates12 = HardwareIdentity.displayAuthCandidates(treeNames: ["babbage", "mogul-mlb"], serviceNames: [])
        expect(candidates12.contains("babbage"), "12 mini: babbage queried")
        expect(!candidates12.contains("mogul-mlb"), "logic-board auth is not the display")

        // Port-controller auth driver serving the display (AppleAuthCPAID).
        let rAID = report([.authAID: ["ComponentFunction": "auth,display", "PrimaryAuthPassed": 1]])
        expect((rAID["display"] as? Entry)?["authPassed"] as? Bool == true, "AID: display flag")
        let rMLB = report([.authAID: ["ComponentFunction": "auth,mlb", "PrimaryAuthPassed": 1]])
        expect((rMLB["display"] as? Entry)?["authPassed"] == nil, "AID: logic board is not the display")
        let flags = HardwareIdentity.partFlags([HardwareIdentity.Hit(
            path: "hpm0/AppleAuthCPAID", className: "AppleAuthCPAID",
            props: ["ComponentFunction": "auth,display", "PrimaryAuthPassed": 0])])
        expect(flags.first?["part"] as? String == "display" && flags.first?["authPassed"] as? Bool == false,
               "AID found by the plane scan")

        // iPhone XS (iPhone11,2): battery chip does not answer.
        let rXS = report([.batteryByClass: battery14, .batteryAuth: ["CommunicationError": 3]])
        let authXS = (rXS["battery"] as? Entry)?["auth"] as? Entry ?? [:]
        expect(authXS["commError"] as? Int == 3, "XS: battery auth chip error")
        expect(authXS["passed"] == nil, "XS: error is not a verdict")

        // Nothing answered at all (connection reset after the first queries).
        let rNone = report([:])
        expect((rNone["display"] as? Entry)?.isEmpty == true, "no answers: empty display")
        expect((rNone["battery"] as? Entry)?.isEmpty == true, "no answers: empty battery")

        print("Hardware identity: iPhone XS, 11, 12 mini, 14 Pro Max, 17 Pro Max — passed")
    }

    static func main() {
        run()
    }
}
