//
//  RewardAPI.swift
//  HealthKitExample2
//
//  Contract between the app and the reward backend. `MockRewardServer`
//  implements it locally today; a URLSession client can replace it later
//  without touching tracking / UI code.
//

import CryptoKit
import Foundation

nonisolated enum ReceiptStatus: String, Codable, Sendable {
    case credited, rejected, duplicate
}

nonisolated struct RewardReceipt: Codable, Hashable, Sendable {
    var sessionId: UUID
    var status: ReceiptStatus
    var coins: Double
    var breakdown: RewardBreakdown
    var verification: VerificationResult
    var serverFlags: [Flag]
    var reason: String?
    var processedAt: Date
    var balanceAfter: Double
    var configVersion: Int

    var allFlags: [Flag] { serverFlags + verification.allFlags }
}

nonisolated struct LedgerEntry: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var sessionId: UUID
    var coins: Double
    var at: Date
    var note: String
}

enum APIError: LocalizedError {
    case network
    case server(String)

    var errorDescription: String? {
        switch self {
        case .network: "Network unavailable (simulated)"
        case .server(let message): message
        }
    }
}

/// Upload envelope. `sentAnchor` lets the server convert device time to server
/// time: if the device has not rebooted since the session ended, the real end
/// time is `serverNow − (sentMono − endMono)`, independent of the device clock.
nonisolated struct Submission: Codable, Sendable {
    var report: SignedReport
    var sentAnchor: ClockAnchor
    var signature: String

    static func make(_ report: SignedReport, anchor: ClockAnchor, key: SymmetricKey) -> Submission {
        Submission(report: report, sentAnchor: anchor, signature: mac(report, anchor, key))
    }

    func isValid(key: SymmetricKey) -> Bool {
        signature == Self.mac(report, sentAnchor, key) && ReportSigner.isValid(report, key: key)
    }

    private static func mac(_ report: SignedReport, _ anchor: ClockAnchor, _ key: SymmetricKey) -> String {
        let message = "\(report.payloadHash)|\(anchor.wall.timeIntervalSince1970)|\(anchor.monoNanos)|\(anchor.bootId)"
        return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)).base64EncodedString()
    }
}

protocol RewardAPI: AnyObject {
    func submit(_ submission: Submission) async throws -> RewardReceipt
    func balance() async throws -> Double
    func ledger() async throws -> [LedgerEntry]
}
