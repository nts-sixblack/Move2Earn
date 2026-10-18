//
//  PassiveSyncService.swift
//  HealthKitExample2
//
//  Orchestrator for Trường hợp 2: Passive Background HealthKit Sync.
//  Coordinates between HealthKit sample queries, strict filtering (rejecting
//  manual and 3rd party entries), local persistence in `passive_records.json`,
//  and uploading to the server with precise round-trip timing.
//

import Combine
import Foundation
import HealthKit

enum QueryWindowScope: String, CaseIterable, Identifiable {
    case today = "today"
    case past24Hours = "24h"
    case past7Days = "7d"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .today: "Hôm nay (từ 00:00)"
        case .past24Hours: "24 giờ qua"
        case .past7Days: "7 ngày qua"
        }
    }
}

private struct ProcessedSamples {
    var deviceSteps: Int = 0
    var iPhoneSteps: Int = 0
    var watchSteps: Int = 0
    var manualSteps: Int = 0
    var thirdPartySteps: Int = 0
    var thirdPartySources: Set<String> = []
    var items: [PassiveSampleItem] = []
}

@MainActor
final class PassiveSyncService: ObservableObject {
    @Published private(set) var records: [PassiveSyncRecord] = []
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastStatusMessage: String?
    @Published private(set) var todayDeviceSteps: Int = 0
    @Published private(set) var todayManualStepsFiltered: Int = 0
    @Published private(set) var todayThirdPartyStepsFiltered: Int = 0
    @Published var selectedScope: QueryWindowScope = .today

    private let store: PassiveSyncStore
    private let healthKit: HealthKitProvider
    private let server: PassiveSyncAPI
    private let logger: EventLogger
    private let now: () -> Date
    private let deviceId: () -> String

    init(store: PassiveSyncStore = PassiveSyncStore(),
         healthKit: HealthKitProvider = HealthKitProvider.shared,
         server: PassiveSyncAPI = MockPassiveServer(),
         logger: EventLogger? = nil,
         now: @escaping () -> Date = Date.init,
         deviceId: @escaping () -> String = { DeviceIdentity.installId }) {
        self.store = store
        self.healthKit = healthKit
        self.server = server
        self.logger = logger ?? EventLogger.shared
        self.now = now
        self.deviceId = deviceId
        reload()
    }

    func reload() {
        records = store.loadRecords()
        let state = store.loadState()
        lastSyncDate = state.lastSyncDate
        recalculateTodayTotals()
    }

    func requestHealthKitPermission() async {
        try? await healthKit.requestAuthorization()
        reload()
    }

    /// Performs passive synchronization triggered by HealthKit background delivery,
    /// BGAppRefreshTask, BGProcessingTask, or manual user test.
    @discardableResult
    func sync(trigger: PassiveTriggerSource,
              customWindow: DateInterval? = nil,
              scopeOverride: QueryWindowScope? = nil) async -> PassiveSyncRecord {
        isSyncing = true
        defer { isSyncing = false }

        let tNow = now()
        let activeScope = scopeOverride ?? selectedScope
        let (start, end) = determineTimeWindow(custom: customWindow, scope: activeScope, tNow: tNow)

        // Ensure HealthKit authorization has been requested
        if !(await healthKit.hasRequestedAuthorization()) {
            try? await healthKit.requestAuthorization()
        }

        // Query both cumulative steps and individual samples
        async let cumulativeTask = healthKit.fetchCumulativeSteps(from: start, to: end)
        async let samplesTask = healthKit.fetchStepSamples(from: start, to: end)

        let rawTotalSteps = await cumulativeTask
        let samples = (await samplesTask) ?? []

        let processedIds = store.loadProcessedSampleIds()
        let (processed, newIds, totalGenuine) = classifySamples(samples, processedIds: processedIds)

        var record = PassiveSyncRecord(
            timestamp: tNow,
            trigger: trigger,
            queryStart: start,
            queryEnd: end,
            queryScope: activeScope.displayName,
            deviceSteps: processed.deviceSteps,
            iPhoneSteps: processed.iPhoneSteps,
            watchSteps: processed.watchSteps,
            manualSteps: processed.manualSteps,
            thirdPartySteps: processed.thirdPartySteps,
            thirdPartySources: processed.thirdPartySources.sorted(),
            sampleCount: samples.count,
            rawHealthKitTotalSteps: rawTotalSteps,
            cumulativeStepsToday: totalGenuine,
            samples: processed.items,
            clientSentAt: tNow,
            serverStatus: .pending,
            serverReceipt: nil,
            notes: nil
        )

        buildDiagnosticsNote(&record, samplesCount: samples.count, rawTotal: rawTotalSteps, scope: activeScope)

        store.saveRecord(record)
        store.markSamplesProcessed(newIds)

        await uploadSubmission(record: &record, trigger: trigger, start: start, end: end, count: samples.count)
        store.updateRecord(record)
        reload()

        logSyncResult(record: record, trigger: trigger, count: samples.count)
        return record
    }

    private func determineTimeWindow(custom: DateInterval?, scope: QueryWindowScope, tNow: Date) -> (Date, Date) {
        if let custom = custom {
            return (custom.start, custom.end)
        }
        let start: Date
        switch scope {
        case .today:
            start = Calendar.current.startOfDay(for: tNow)
        case .past24Hours:
            start = tNow.addingTimeInterval(-24 * 3600)
        case .past7Days:
            start = tNow.addingTimeInterval(-7 * 24 * 3600)
        }
        return (start, tNow)
    }

    private func classifySamples(_ samples: [HKQuantitySample],
                                 processedIds: Set<String>) -> (ProcessedSamples, [String], Int) {
        var res = ProcessedSamples()
        var newIds: [String] = []
        var totalGenuine = 0

        for sample in samples {
            let count = Int(sample.quantity.doubleValue(for: .count()))
            let bundle = sample.sourceRevision.source.bundleIdentifier
            let name = sample.sourceRevision.source.name
            let model = sample.sourceRevision.productType ?? sample.device?.model ?? ""
            let isUserEntered = (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) == true
            let isApple = HealthKitProvider.isAppleDeviceHardware(bundleIdentifier: bundle)
            let sampleId = sample.uuid.uuidString
            let isNew = !processedIds.contains(sampleId)

            if isUserEntered {
                if isNew {
                    res.manualSteps += count
                    newIds.append(sampleId)
                }
                res.items.append(PassiveSampleItem(
                    sampleUUID: sampleId, startDate: sample.startDate, endDate: sample.endDate, steps: count,
                    sourceBundle: bundle, sourceName: name, isDeviceHardware: false,
                    isUserEntered: true, deviceModel: model
                ))
            } else if isApple {
                totalGenuine += count
                if isNew {
                    res.deviceSteps += count
                    if model.hasPrefix("Watch") { res.watchSteps += count } else { res.iPhoneSteps += count }
                    newIds.append(sampleId)
                }
                res.items.append(PassiveSampleItem(
                    sampleUUID: sampleId, startDate: sample.startDate, endDate: sample.endDate, steps: count,
                    sourceBundle: bundle, sourceName: name, isDeviceHardware: true,
                    isUserEntered: false, deviceModel: model
                ))
            } else {
                if isNew {
                    res.thirdPartySteps += count
                    res.thirdPartySources.insert(name)
                    newIds.append(sampleId)
                }
                res.items.append(PassiveSampleItem(
                    sampleUUID: sampleId, startDate: sample.startDate, endDate: sample.endDate, steps: count,
                    sourceBundle: bundle, sourceName: name, isDeviceHardware: false,
                    isUserEntered: false, deviceModel: model
                ))
            }
        }
        return (res, newIds, totalGenuine)
    }

    private func buildDiagnosticsNote(_ record: inout PassiveSyncRecord, samplesCount: Int,
                                      rawTotal: Int, scope: QueryWindowScope) {
        if samplesCount == 0 {
            if rawTotal > 0 {
                record.notes = "HealthKit Statistics có \(rawTotal) bước, nhưng chưa có mẫu chi tiết nào được ghi vào DB."
            } else {
                record.notes = "Không tìm thấy bước chân trong \(scope.displayName). Hãy kiểm tra app Sức khoẻ."
            }
        } else if record.deviceSteps == 0 && record.cumulativeStepsToday > 0 {
            record.notes = "Đã tìm thấy \(record.cumulativeStepsToday) bước hôm nay (đã đồng bộ ở các lần trước)."
        }
    }

    private func uploadSubmission(record: inout PassiveSyncRecord, trigger: PassiveTriggerSource,
                                  start: Date, end: Date, count: Int) async {
        let sentAt = now()
        record.clientSentAt = sentAt
        let submission = PassiveServerSubmission(
            submissionId: UUID(),
            recordId: record.id,
            deviceId: deviceId(),
            clientSentAt: sentAt,
            trigger: trigger,
            periodStart: start,
            periodEnd: end,
            deviceSteps: record.deviceSteps,
            manualStepsFiltered: record.manualSteps,
            thirdPartyStepsFiltered: record.thirdPartySteps,
            sampleCount: count
        )

        do {
            let receipt = try await server.submitPassiveSync(submission)
            record.serverStatus = .success(receiptId: receipt.id, serverReceivedAt: receipt.serverReceivedAt,
                                           latencyMs: receipt.latencyMs)
            record.serverReceipt = receipt
            let timeStr = Format.time.string(from: receipt.serverReceivedAt)
            if record.notes == nil {
                record.notes = "Thành công: Server ghi nhận lúc \(timeStr)"
            }
        } catch {
            record.serverStatus = .failed(reason: error.localizedDescription)
            record.notes = "Lỗi gửi server: \(error.localizedDescription)"
        }
    }

    private func logSyncResult(record: PassiveSyncRecord, trigger: PassiveTriggerSource, count: Int) {
        _ = logger.log("passiveSyncExecuted", [
            "trigger": trigger.rawValue,
            "deviceSteps": String(record.deviceSteps),
            "manualFiltered": String(record.manualSteps),
            "thirdPartyFiltered": String(record.thirdPartySteps),
            "samples": String(count),
            "status": record.serverStatus.statusTitle
        ])
        lastStatusMessage = "Đồng bộ \(trigger.shortTag): +\(record.deviceSteps) bước máy mới (Hôm nay: \(record.cumulativeStepsToday))."
    }

    /// Creates a simulated passive sync event for testing filtering and server timestamp logging
    /// on Simulator or without walking.
    @discardableResult
    func simulateScenario(trigger: PassiveTriggerSource = .manualTest,
                          deviceSteps: Int,
                          manualSteps: Int,
                          thirdPartySteps: Int,
                          thirdPartyName: String = "CheatStepsApp") async -> PassiveSyncRecord {
        isSyncing = true
        defer { isSyncing = false }

        let tNow = now()
        let start = tNow.addingTimeInterval(-30 * 60)
        let end = tNow

        var sampleItems: [PassiveSampleItem] = []
        if deviceSteps > 0 {
            sampleItems.append(PassiveSampleItem(
                sampleUUID: UUID().uuidString,
                startDate: start, endDate: end, steps: deviceSteps,
                sourceBundle: "com.apple.Health", sourceName: "Apple Health",
                isDeviceHardware: true, isUserEntered: false, deviceModel: "iPhone16,1"
            ))
        }
        if manualSteps > 0 {
            sampleItems.append(PassiveSampleItem(
                sampleUUID: UUID().uuidString,
                startDate: start, endDate: end, steps: manualSteps,
                sourceBundle: "com.apple.Health", sourceName: "Health App (User)",
                isDeviceHardware: false, isUserEntered: true, deviceModel: nil
            ))
        }
        if thirdPartySteps > 0 {
            sampleItems.append(PassiveSampleItem(
                sampleUUID: UUID().uuidString,
                startDate: start, endDate: end, steps: thirdPartySteps,
                sourceBundle: "com.fake.\(thirdPartyName.lowercased())", sourceName: thirdPartyName,
                isDeviceHardware: false, isUserEntered: false, deviceModel: nil
            ))
        }

        var record = PassiveSyncRecord(
            timestamp: tNow,
            trigger: trigger,
            queryStart: start,
            queryEnd: end,
            queryScope: "Simulated",
            deviceSteps: deviceSteps,
            iPhoneSteps: deviceSteps,
            watchSteps: 0,
            manualSteps: manualSteps,
            thirdPartySteps: thirdPartySteps,
            thirdPartySources: thirdPartySteps > 0 ? [thirdPartyName] : [],
            sampleCount: sampleItems.count,
            rawHealthKitTotalSteps: deviceSteps,
            cumulativeStepsToday: deviceSteps,
            samples: sampleItems,
            clientSentAt: tNow,
            serverStatus: .pending,
            serverReceipt: nil,
            notes: "Kịch bản test giả lập"
        )

        store.saveRecord(record)
        await uploadSubmission(record: &record, trigger: trigger, start: start, end: end, count: sampleItems.count)
        store.updateRecord(record)
        reload()

        _ = logger.log("passiveSyncSimulated", [
            "trigger": trigger.rawValue,
            "deviceSteps": String(deviceSteps),
            "manualFiltered": String(manualSteps),
            "thirdPartyFiltered": String(thirdPartySteps),
            "status": record.serverStatus.statusTitle
        ])

        lastStatusMessage = "Giả lập \(trigger.shortTag): +\(deviceSteps) bước hợp lệ, loại \(manualSteps + thirdPartySteps) bước không hợp lệ."
        return record
    }

    func clearLogs() {
        store.clearAll()
        reload()
        _ = logger.log("passiveLogsCleared")
        lastStatusMessage = "Đã xoá toàn bộ log passive sync."
    }

    func exportJSONString() -> String {
        store.exportJSONString()
    }

    private func recalculateTodayTotals() {
        let cal = Calendar.current
        let currentDay = now()
        let today = records.filter { cal.isDate($0.timestamp, inSameDayAs: currentDay) }
        todayDeviceSteps = today.reduce(0) { $0 + $1.deviceSteps }
        todayManualStepsFiltered = today.reduce(0) { $0 + $1.manualSteps }
        todayThirdPartyStepsFiltered = today.reduce(0) { $0 + $1.thirdPartySteps }
    }
}
