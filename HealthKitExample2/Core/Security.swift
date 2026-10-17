//
//  Security.swift
//  HealthKitExample2
//
//  Device identity, report signing and runtime integrity checks.
//
//  NOTE: an HMAC key on the device only proves the payload was not edited in
//  transit / on disk. Production must bind the key to the genuine app with
//  App Attest (DCAppAttestService) so a re-implemented client cannot sign.
//

import CryptoKit
import DeviceCheck
import Foundation
import MachO
import Security
import UIKit

// MARK: - Keychain

nonisolated enum Keychain {
    private static let service = "com.sixpilot.HealthKitExample.m2e"

    static func data(for account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Returns the stored value or creates, stores and returns a new one.
    static func getOrCreate(_ account: String, make: () -> Data) -> Data {
        if let existing = data(for: account) { return existing }
        let value = make()
        set(value, for: account)
        return value
    }
}

// MARK: - Identity & signing

nonisolated enum DeviceIdentity {
    /// Survives reinstall (Keychain), unlike identifierForVendor.
    static let installId: String = {
        let data = Keychain.getOrCreate("installId") { Data(UUID().uuidString.utf8) }
        return String(data: data, encoding: .utf8) ?? "unknown"
    }()

    static let signingKey: SymmetricKey = {
        let data = Keychain.getOrCreate("hmacKey") {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return Data(bytes)
        }
        return SymmetricKey(data: data)
    }()

    static var keyId: String {
        String(HashChain.sha256Hex(signingKey.withUnsafeBytes { Data($0) }).prefix(16))
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?")(\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

nonisolated enum ReportSigner {
    static func sign(_ report: SessionReport, key: SymmetricKey, keyId: String) throws -> SignedReport {
        let payload = try FileStore.encoder.encode(report)
        return sign(payload: payload, key: key, keyId: keyId)
    }

    static func sign(payload: Data, key: SymmetricKey, keyId: String) -> SignedReport {
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return SignedReport(payload: payload, payloadHash: HashChain.sha256Hex(payload),
                            signature: Data(mac).base64EncodedString(), keyId: keyId)
    }

    static func isValid(_ signed: SignedReport, key: SymmetricKey) -> Bool {
        guard let mac = Data(base64Encoded: signed.signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: signed.payload, using: key)
            && HashChain.sha256Hex(signed.payload) == signed.payloadHash
    }
}

// MARK: - Integrity

nonisolated enum DeviceIntegrity {
    private static let jailbreakPaths = [
        "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib", "/usr/sbin/sshd", "/usr/bin/ssh",
        "/etc/apt", "/private/var/lib/apt/", "/var/jb", "/private/preboot/jb",
        "/usr/lib/libjailbreak.dylib", "/bin/bash",
    ]

    private static let hookLibraries = [
        "frida", "fridagadget", "substrate", "substitute", "libhooker", "ellekit", "cycript",
        "sslkillswitch", "libflex", "flexing", "locationfaker", "relocate", "fakegps",
    ]

    static func snapshot(preciseLocation: Bool?) -> IntegritySnapshot {
        #if targetEnvironment(simulator)
        let isSimulator = true
        let signals: [String] = []
        #else
        let isSimulator = false
        let signals = jailbreakSignals()
        #endif
        return IntegritySnapshot(isSimulator: isSimulator,
                                 isJailbroken: !signals.isEmpty,
                                 jailbreakSignals: signals,
                                 debuggerAttached: isDebuggerAttached(),
                                 suspiciousLibraries: loadedHookLibraries(),
                                 appAttestSupported: DCAppAttestService.shared.isSupported,
                                 lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                 preciseLocation: preciseLocation)
    }

    static func jailbreakSignals() -> [String] {
        var signals = jailbreakPaths.filter { FileManager.default.fileExists(atPath: $0) }
        let probe = "/private/m2e_jb_probe_\(UUID().uuidString)"
        if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            signals.append("sandboxWritable")
            try? FileManager.default.removeItem(atPath: probe)
        }
        if let env = getenv("DYLD_INSERT_LIBRARIES"), String(cString: env).isEmpty == false {
            signals.append("DYLD_INSERT_LIBRARIES")
        }
        return signals
    }

    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    static func loadedHookLibraries() -> [String] {
        var found: [String] = []
        for i in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let name = String(cString: cName)
            let file = (name as NSString).lastPathComponent.lowercased()
            if hookLibraries.contains(where: { file.contains($0) }) { found.append(file) }
        }
        return found
    }
}
