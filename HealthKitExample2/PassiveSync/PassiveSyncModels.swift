//
//  PassiveSyncModels.swift
//  HealthKitExample2
//
//  Data models, server API, mock server, and file store for
//  Trường hợp 2: Passive Background HealthKit Sync.
//

import Foundation

nonisolated enum PassiveTriggerSource: String, Codable, CaseIterable, Sendable {
    case healthKitWake = "hk_background_delivery"
    case bgAppRefresh = "bg_app_refresh"
    case bgProcessing = "bg_processing"
    case foreground = "foreground_sync"
    case manualTest = "manual_test"
    case simulated = "simulated_scenario"

    var displayName: String {
        switch self {
        case .healthKitWake: "HealthKit Background Delivery"
        case .bgAppRefresh: "BGAppRefreshTask"
        case .bgProcessing: "BGProcessingTask"
        case .foreground: "App Foreground"
        case .manualTest: "Manual Sync"
        case .simulated: "Simulated Scenario"
        }
    }

    var shortTag: String {
        switch self {
        case .healthKitWake: "HK-Wake"
        case .bgAppRefresh: "BG-Refresh"
        case .bgProcessing: "BG-Process"
        case .foreground: "Foreground"
        case .manualTest: "Manual"
        case .simulated: "Simulated"
        }
    }

    var icon: String {
        switch self {
        case .healthKitWake: "heart.fill"
        case .bgAppRefresh: "arrow.triangle.2.circlepath"
        case .bgProcessing: "gearshape.2.fill"
        case .foreground: "iphone"
        case .manualTest: "hand.tap.fill"
        case .simulated: "sparkles"
        }
    }
}

nonisolated struct PassiveSampleItem: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var sampleUUID: String?
    var startDate: Date
    var endDate: Date
    var steps: Int
    var sourceBundle: String
    var sourceName: String
    var isDeviceHardware: Bool
    var isUserEntered: Bool
    var deviceModel: String?
}

nonisolated struct PassiveServerReceipt: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var recordId: UUID
    var deviceId: String
    var clientSentAt: Date
    var serverReceivedAt: Date
    var latencyMs: Double
    var deviceSteps: Int
    var status: String
    var serverNote: String
}

nonisolated enum PassiveServerStatus: Codable, Hashable, Sendable {
    case pending
    case success(receiptId: UUID, serverReceivedAt: Date, latencyMs: Double)
    case failed(reason: String)
    case skipped(reason: String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var statusTitle: String {
        switch self {
        case .pending: "Đang gửi server..."
        case .success(_, _, let latency): String(format: "Đã ghi nhận (%.0f ms)", latency)
        case .failed(let reason): "Lỗi: \(reason)"
        case .skipped(let reason): "Bỏ qua: \(reason)"
        }
    }
}

nonisolated struct PassiveSyncRecord: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date
    var trigger: PassiveTriggerSource
    var queryStart: Date
    var queryEnd: Date
    var queryScope: String = "today"

    // Filtered step counts for this sync run
    var deviceSteps: Int
    var iPhoneSteps: Int
    var watchSteps: Int
    var manualSteps: Int
    var thirdPartySteps: Int
    var thirdPartySources: [String]

    // Raw samples breakdown
    var sampleCount: Int
    var rawHealthKitTotalSteps: Int = 0
    var cumulativeStepsToday: Int = 0
    var samples: [PassiveSampleItem]

    // Server submission & response timing
    var clientSentAt: Date?
    var serverStatus: PassiveServerStatus
    var serverReceipt: PassiveServerReceipt?
    var notes: String?

    var totalRawSteps: Int {
        deviceSteps + manualSteps + thirdPartySteps
    }

    var rejectedSteps: Int {
        manualSteps + thirdPartySteps
    }
}

nonisolated struct PassiveServerSubmission: Codable, Sendable {
    var submissionId: UUID
    var recordId: UUID
    var deviceId: String
    var clientSentAt: Date
    var trigger: PassiveTriggerSource
    var periodStart: Date
    var periodEnd: Date
    var deviceSteps: Int
    var manualStepsFiltered: Int
    var thirdPartyStepsFiltered: Int
    var sampleCount: Int
}

// MARK: - Server Contract

protocol PassiveSyncAPI: AnyObject {
    func submitPassiveSync(_ submission: PassiveServerSubmission) async throws -> PassiveServerReceipt
    func passiveReceipts() async throws -> [PassiveServerReceipt]
}

// MARK: - Mock Server for Passive Step Logging

final class MockPassiveServer: PassiveSyncAPI, @unchecked Sendable {
    private let store: FileStore
    private let now: () -> Date
    private let lock = NSLock()
    private let file = "server_passive_receipts.json"
    private let simulateNetwork: Bool

    init(store: FileStore = FileStore.app.sub("mock_server"),
         now: @escaping () -> Date = Date.init,
         simulateNetwork: Bool = true) {
        self.store = store
        self.now = now
        self.simulateNetwork = simulateNetwork
    }

    func submitPassiveSync(_ submission: PassiveServerSubmission) async throws -> PassiveServerReceipt {
        if simulateNetwork {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let serverNow = now()
        let latencyMs = max(0, serverNow.timeIntervalSince(submission.clientSentAt) * 1000)
        let receipt = PassiveServerReceipt(
            id: UUID(),
            recordId: submission.recordId,
            deviceId: submission.deviceId,
            clientSentAt: submission.clientSentAt,
            serverReceivedAt: serverNow,
            latencyMs: latencyMs,
            deviceSteps: submission.deviceSteps,
            status: "recorded",
            serverNote: "Server logged \(submission.deviceSteps) device steps at \(serverNow)"
        )

        lock.lock()
        defer { lock.unlock() }
        var list = (try? store.load([PassiveServerReceipt].self, from: file)) ?? []
        list.insert(receipt, at: 0)
        try? store.save(list, to: file)

        return receipt
    }

    func passiveReceipts() async throws -> [PassiveServerReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return (try? store.load([PassiveServerReceipt].self, from: file)) ?? []
    }
}

// MARK: - Persistence Store

nonisolated final class PassiveSyncStore: @unchecked Sendable {
    private let store: FileStore
    private let recordsFile = "passive_records.json"
    private let stateFile = "passive_state.json"
    private let lock = NSLock()

    struct State: Codable {
        var lastSyncDate: Date?
        var totalDeviceStepsAllTime: Int = 0
        var totalManualStepsFilteredAllTime: Int = 0
        var totalThirdPartyStepsFilteredAllTime: Int = 0
        var processedSampleIds: [String] = []
    }

    init(store: FileStore = FileStore.app.sub("passive_sync")) {
        self.store = store
    }

    func loadRecords() -> [PassiveSyncRecord] {
        lock.lock()
        defer { lock.unlock() }
        return (try? store.load([PassiveSyncRecord].self, from: recordsFile)) ?? []
    }

    func saveRecord(_ record: PassiveSyncRecord) {
        lock.lock()
        defer { lock.unlock() }
        var list = (try? store.load([PassiveSyncRecord].self, from: recordsFile)) ?? []
        list.insert(record, at: 0)
        try? store.save(list, to: recordsFile)

        var state = (try? store.load(State.self, from: stateFile)) ?? State()
        state.lastSyncDate = record.queryEnd
        state.totalDeviceStepsAllTime += record.deviceSteps
        state.totalManualStepsFilteredAllTime += record.manualSteps
        state.totalThirdPartyStepsFilteredAllTime += record.thirdPartySteps
        try? store.save(state, to: stateFile)
    }

    func updateRecord(_ record: PassiveSyncRecord) {
        lock.lock()
        defer { lock.unlock() }
        var list = (try? store.load([PassiveSyncRecord].self, from: recordsFile)) ?? []
        if let idx = list.firstIndex(where: { $0.id == record.id }) {
            list[idx] = record
            try? store.save(list, to: recordsFile)
        }
    }

    func loadState() -> State {
        lock.lock()
        defer { lock.unlock() }
        return (try? store.load(State.self, from: stateFile)) ?? State()
    }

    func loadProcessedSampleIds() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let state = (try? store.load(State.self, from: stateFile)) ?? State()
        return Set(state.processedSampleIds)
    }

    func markSamplesProcessed(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var state = (try? store.load(State.self, from: stateFile)) ?? State()
        var currentSet = Set(state.processedSampleIds)
        currentSet.formUnion(ids)
        if currentSet.count > 10_000 {
            state.processedSampleIds = Array(currentSet.suffix(8_000))
        } else {
            state.processedSampleIds = Array(currentSet)
        }
        try? store.save(state, to: stateFile)
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        store.delete(recordsFile)
        store.delete(stateFile)
    }

    func exportJSONData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let records = (try? store.load([PassiveSyncRecord].self, from: recordsFile)) ?? []
        return try? FileStore.prettyEncoder.encode(records)
    }

    func exportJSONString() -> String {
        guard let data = exportJSONData(), let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
