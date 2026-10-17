//
//  MockRewardServer.swift
//  HealthKitExample2
//
//  Temporary stand-in for the backend. It deliberately behaves like a server:
//  it only receives the signed bytes, re-runs verification from raw epochs with
//  its own config, keeps its own ledger / idempotency store / daily totals in a
//  separate folder, and uses its own clock for daily limits.
//

import CryptoKit
import Foundation

final class MockRewardServer: RewardAPI {
    nonisolated struct CreditedRange: Codable, Hashable, Sendable {
        var deviceId: String
        var sessionId: UUID
        var start: Date
        var end: Date
    }

    nonisolated struct DailyTotals: Codable, Hashable, Sendable {
        var coins: Double = 0
        var steps: Int = 0
        var sessions: Int = 0
    }

    nonisolated struct State: Codable, Sendable {
        var receipts: [UUID: RewardReceipt] = [:]
        var nonces: [String: UUID] = [:]
        var ledger: [LedgerEntry] = []
        var credited: [CreditedRange] = []
        var daily: [String: DailyTotals] = [:]
    }

    private let store: FileStore
    private let config: () -> RewardConfig
    private let keyLookup: (String) -> SymmetricKey?
    private let now: () -> Date
    private let simulateNetwork: Bool
    private(set) var state: State

    init(store: FileStore, config: @escaping () -> RewardConfig,
         keyLookup: @escaping (String) -> SymmetricKey?,
         now: @escaping () -> Date = Date.init, simulateNetwork: Bool = true) {
        self.store = store
        self.config = config
        self.keyLookup = keyLookup
        self.now = now
        self.simulateNetwork = simulateNetwork
        self.state = (try? store.load(State.self, from: "server_state.json")) ?? State()
    }

    // MARK: RewardAPI

    func balance() async throws -> Double {
        try await networkHop()
        return currentBalance
    }

    func ledger() async throws -> [LedgerEntry] {
        try await networkHop()
        return state.ledger.sorted { $0.at > $1.at }
    }

    func submit(_ submission: Submission) async throws -> RewardReceipt {
        try await networkHop()
        return process(submission)
    }

    var currentBalance: Double { state.ledger.reduce(0) { $0 + $1.coins } }

    func reset() {
        state = State()
        persist()
    }

    // MARK: Processing

    func process(_ submission: Submission) -> RewardReceipt {
        let cfg = config()
        let serverNow = now()
        let signed = submission.report

        guard let key = keyLookup(signed.keyId), submission.isValid(key: key) else {
            return reject(sessionId: (try? decode(signed))?.sessionId ?? UUID(), code: .signatureInvalid,
                          reason: "HMAC signature does not match payload", cfg: cfg, persistReceipt: false)
        }
        guard let report = try? decode(signed) else {
            return reject(sessionId: UUID(), code: .malformedReport, reason: "Cannot decode report", cfg: cfg,
                          persistReceipt: false)
        }

        // Idempotency / replay
        if var previous = state.receipts[report.sessionId] {
            previous.status = .duplicate
            previous.serverFlags.append(Flag(code: .duplicateSubmission, severity: .info, detail: "already processed"))
            return previous
        }
        if let owner = state.nonces[report.nonce], owner != report.sessionId {
            return reject(sessionId: report.sessionId, code: .duplicateSubmission,
                          reason: "Nonce already used by session \(owner)", cfg: cfg)
        }

        var serverFlags: [Flag] = []

        // Tamper evidence: the log segment must be an intact hash chain for this session
        if let broken = HashChain.firstBreak(in: report.events) {
            serverFlags.append(Flag(code: .logChainBroken, severity: .reject, detail: "chain broken at seq \(broken)"))
        }
        let markers = Set(report.events.filter { $0.sessionId == report.sessionId }.map(\.type))
        if !markers.contains("sessionStarted") || !markers.contains("sessionEnded") {
            serverFlags.append(Flag(code: .logChainBroken, severity: .reject, detail: "missing start/end events"))
        }

        // Device clock vs server clock. With no reboot since the session ended, the
        // monotonic delta tells us exactly when (server time) the session ended.
        let sent = submission.sentAnchor
        var clockOffset: Double = 0
        if sent.bootId == report.endAnchor.bootId, sent.monoNanos >= report.endAnchor.monoNanos {
            let elapsed = Double(sent.monoNanos - report.endAnchor.monoNanos) / 1_000_000_000
            clockOffset = report.endAnchor.wall.timeIntervalSince(serverNow.addingTimeInterval(-elapsed))
            if abs(clockOffset) > cfg.rules.clockToleranceSeconds {
                serverFlags.append(Flag(code: .clockTampered, severity: cfg.rules.rejectOnClockTamper ? .reject : .warning,
                                        detail: String(format: "device clock offset %.0fs vs server", clockOffset)))
            }
        } else {
            clockOffset = sent.wall.timeIntervalSince(serverNow)
            if abs(clockOffset) > 300 {
                serverFlags.append(Flag(code: .clockTampered, severity: .warning,
                                        detail: String(format: "device clock skew %.0fs (rebooted, unverifiable)", clockOffset)))
            }
        }

        // Timestamps must not be in the server's future
        if report.endedAt > serverNow.addingTimeInterval(120)
            || report.epochs.contains(where: { $0.end > serverNow.addingTimeInterval(120) }) {
            serverFlags.append(Flag(code: .futureEpoch, severity: .reject, detail: "data is ahead of server time"))
        }

        // Daily session limit (server calendar day of the session start)
        let day = Self.dayKey(report.startedAt.addingTimeInterval(-clockOffset))
        let totals = state.daily[day] ?? DailyTotals()
        if totals.sessions >= cfg.limits.maxSessionsPerDay {
            serverFlags.append(Flag(code: .dailySessionCap, severity: .reject,
                                    detail: "\(totals.sessions) sessions already today"))
        }

        var verification = ActivityVerifier.verify(VerificationInput(report: report), config: cfg)

        // Same device, same wall-clock time, different session id (reinstall / parallel sessions)
        let others = state.credited.filter { $0.deviceId == report.deviceId && $0.sessionId != report.sessionId }
        for i in verification.verdicts.indices {
            guard let epoch = report.epochs.first(where: { $0.index == verification.verdicts[i].index }) else { continue }
            if others.contains(where: { epoch.start < $0.end && epoch.end > $0.start }) {
                verification.verdicts[i].valid = false
                verification.verdicts[i].rewardSteps = 0
                verification.verdicts[i].verifiedDistance = 0
                verification.verdicts[i].flags.append(Flag(code: .overlapsCreditedSession, severity: .reject,
                                                           epochIndex: epoch.index, detail: "time already credited"))
            }
        }

        let serverRejected = serverFlags.contains { $0.severity == .reject }
        if serverRejected {
            verification.sessionRejected = true
            for i in verification.verdicts.indices {
                verification.verdicts[i].valid = false
                verification.verdicts[i].rewardSteps = 0
                verification.verdicts[i].verifiedDistance = 0
            }
        }

        var breakdown = RewardCalculator.calculate(epochs: report.epochs, result: verification, config: cfg,
                                                   todayCoins: totals.coins, todaySteps: totals.steps)
        for code in breakdown.cappedBy {
            serverFlags.append(Flag(code: code, severity: .info, detail: "daily limit reached"))
        }
        if verification.sessionRejected { breakdown.coins = 0 }

        let status: ReceiptStatus = verification.sessionRejected ? .rejected : .credited
        if status == .credited {
            if breakdown.coins > 0 {
                state.ledger.append(LedgerEntry(id: UUID(), sessionId: report.sessionId, coins: breakdown.coins,
                                                at: serverNow, note: "\(breakdown.rewardedSteps) steps"))
            }
            if let first = report.epochs.map(\.start).min(), let last = report.epochs.map(\.end).max() {
                state.credited.append(CreditedRange(deviceId: report.deviceId, sessionId: report.sessionId,
                                                    start: first, end: last))
            }
            var t = totals
            t.coins += breakdown.coins
            t.steps += breakdown.rewardedSteps
            t.sessions += 1
            state.daily[day] = t
        }
        let reason = verification.sessionRejected
            ? (serverFlags + verification.sessionFlags).first { $0.severity == .reject }.map { "\($0.code.rawValue): \($0.detail)" }
            : nil
        let receipt = RewardReceipt(sessionId: report.sessionId, status: status, coins: breakdown.coins,
                                    breakdown: breakdown, verification: verification, serverFlags: serverFlags,
                                    reason: reason, processedAt: serverNow, balanceAfter: currentBalance,
                                    configVersion: cfg.version)
        state.receipts[report.sessionId] = receipt
        state.nonces[report.nonce] = report.sessionId
        persist()
        return receipt
    }

    // MARK: Helpers

    private func reject(sessionId: UUID, code: FlagCode, reason: String, cfg: RewardConfig,
                        persistReceipt: Bool = true) -> RewardReceipt {
        let receipt = RewardReceipt(sessionId: sessionId, status: .rejected, coins: 0, breakdown: .zero,
                                    verification: VerificationResult(verdicts: [], sessionFlags: [], sessionRejected: true),
                                    serverFlags: [Flag(code: code, severity: .reject, detail: reason)],
                                    reason: "\(code.rawValue): \(reason)", processedAt: now(),
                                    balanceAfter: currentBalance, configVersion: cfg.version)
        if persistReceipt {
            state.receipts[sessionId] = receipt
            persist()
        }
        return receipt
    }

    private func decode(_ signed: SignedReport) throws -> SessionReport {
        try FileStore.decoder.decode(SessionReport.self, from: signed.payload)
    }

    private func networkHop() async throws {
        guard simulateNetwork else { return }
        let cfg = config().mockServer
        if cfg.latencyMs > 0 { try? await Task.sleep(nanoseconds: UInt64(cfg.latencyMs) * 1_000_000) }
        if Double.random(in: 0..<1) < cfg.failureRate { throw APIError.network }
    }

    private func persist() { try? store.save(state, to: "server_state.json") }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
