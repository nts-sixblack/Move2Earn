//
//  SyncService.swift
//  HealthKitExample2
//
//  Outbox → server. Signed reports are written to disk *before* any network
//  call, so a session is never lost if the app is killed or offline; the
//  queue is retried on launch, foreground, BGAppRefresh and HealthKit wakes.
//  Submissions are idempotent server-side (session id + nonce).
//

import Foundation
import Combine

nonisolated enum RecordStatus: String, Codable, Sendable {
    case pending, credited, rejected
}

nonisolated struct SessionRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var endReason: EndReason
    var steps: Int
    var distance: Double
    var epochCount: Int
    var recoveredEpochs: Int
    var relaunches: Int
    var estimate: Double
    var localFlags: [FlagCode]
    var status: RecordStatus
    var receipt: RewardReceipt?
    var lastError: String?
}

final class HistoryStore: ObservableObject {
    @Published private(set) var records: [SessionRecord] = []
    private let store: FileStore

    init(store: FileStore) {
        self.store = store
        records = (try? store.load([SessionRecord].self, from: "index.json")) ?? []
    }

    func upsert(_ record: SessionRecord) {
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record } else { records.insert(record, at: 0) }
        records.sort { $0.startedAt > $1.startedAt }
        try? store.save(records, to: "index.json")
    }

    func record(_ id: UUID) -> SessionRecord? { records.first { $0.id == id } }

    func saveReport(_ report: SessionReport) { try? store.save(report, to: "report-\(report.sessionId.uuidString).json") }

    func report(_ id: UUID) -> SessionReport? { try? store.load(SessionReport.self, from: "report-\(id.uuidString).json") }

    func reportFileURL(_ id: UUID) -> URL { store.url("report-\(id.uuidString).json") }

    func wipe() {
        store.wipe()
        records = []
    }
}

final class WalletStore: ObservableObject {
    @Published private(set) var balance: Double = 0
    @Published private(set) var ledger: [LedgerEntry] = []
    @Published private(set) var lastError: String?
    private let api: RewardAPI

    init(api: RewardAPI) { self.api = api }

    func refresh() async {
        do {
            balance = try await api.balance()
            ledger = try await api.ledger()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func todayCoins() -> Double {
        ledger.filter { Calendar.current.isDateInToday($0.at) }.reduce(0) { $0 + $1.coins }
    }
}

final class SyncService: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var pendingCount = 0

    private let outbox: FileStore
    private let api: RewardAPI
    private let history: HistoryStore
    private let wallet: WalletStore
    private let logger: EventLogger
    private let config: () -> RewardConfig

    init(outbox: FileStore, api: RewardAPI, history: HistoryStore, wallet: WalletStore, logger: EventLogger,
         config: @escaping () -> RewardConfig) {
        self.outbox = outbox
        self.api = api
        self.history = history
        self.wallet = wallet
        self.logger = logger
        self.config = config
        pendingCount = outbox.list().count
    }

    /// Persist the finished session and its signed payload, then try to upload.
    func handleFinished(_ report: SessionReport) async {
        let cfg = config()
        let verification = ActivityVerifier.verify(VerificationInput(report: report), config: cfg)
        let estimate = RewardCalculator.calculate(epochs: report.epochs, result: verification, config: cfg,
                                                  todayCoins: wallet.todayCoins())
        history.saveReport(report)
        history.upsert(SessionRecord(
            id: report.sessionId, startedAt: report.startedAt, endedAt: report.endedAt, endReason: report.endReason,
            steps: report.totalSteps, distance: report.epochs.reduce(0) { $0 + $1.gpsDistance },
            epochCount: report.epochs.count, recoveredEpochs: report.epochs.filter { $0.source == .recovered }.count,
            relaunches: report.clientFlags.filter { $0.code == .appRelaunched }.count,
            estimate: estimate.coins,
            localFlags: Array(Set(verification.allFlags.filter { $0.severity != .info }.map(\.code))).sorted { $0.rawValue < $1.rawValue },
            status: .pending, receipt: nil, lastError: nil))
        do {
            let signed = try ReportSigner.sign(report, key: DeviceIdentity.signingKey, keyId: DeviceIdentity.keyId)
            try outbox.save(signed, to: "\(report.sessionId.uuidString).json")
            logger.log("reportQueued", session: report.sessionId, [
                "bytes": String(signed.payload.count), "hash": String(signed.payloadHash.prefix(16)),
                "estimate": String(estimate.coins),
            ])
        } catch {
            logger.log("reportQueueFailed", level: .error, session: report.sessionId, ["error": error.localizedDescription])
        }
        pendingCount = outbox.list().count
        await syncPending()
    }

    func syncPending() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            pendingCount = outbox.list().count
        }
        for file in outbox.list() where file.hasSuffix(".json") {
            guard let signed = try? outbox.load(SignedReport.self, from: file) else {
                outbox.delete(file)
                continue
            }
            let id = UUID(uuidString: String(file.dropLast(5)))
            do {
                let submission = Submission.make(signed, anchor: ClockGuard.anchor(), key: DeviceIdentity.signingKey)
                let receipt = try await api.submit(submission)
                outbox.delete(file)
                logger.log("reportSubmitted", session: receipt.sessionId, [
                    "status": receipt.status.rawValue, "coins": String(receipt.coins),
                    "reason": receipt.reason ?? "-",
                ])
                if var record = history.record(receipt.sessionId) {
                    record.status = receipt.status == .rejected ? .rejected : .credited
                    if receipt.status != .duplicate || record.receipt == nil { record.receipt = receipt }
                    record.lastError = nil
                    history.upsert(record)
                }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                logger.log("reportSubmitFailed", level: .warning, session: id, ["error": error.localizedDescription])
                if let id, var record = history.record(id) {
                    record.lastError = error.localizedDescription
                    history.upsert(record)
                }
                break
            }
        }
        lastSyncAt = Date()
        await wallet.refresh()
    }
}
