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

    /// Performs passive synchronization triggered by HealthKit background delivery,
    /// BGAppRefreshTask, BGProcessingTask, or manual user test.
    @discardableResult
    func sync(trigger: PassiveTriggerSource, customWindow: DateInterval? = nil) async -> PassiveSyncRecord {
        isSyncing = true
        defer { isSyncing = false }

        let tNow = now()
        let (start, end) = determineTimeWindow(custom: customWindow, tNow: tNow)
        let samples = await healthKit.fetchStepSamples(from: start, to: end) ?? []
        let processed = classifySamples(samples)

        var record = PassiveSyncRecord(
            timestamp: tNow,
            trigger: trigger,
            queryStart: start,
            queryEnd: end,
            deviceSteps: processed.deviceSteps,
            iPhoneSteps: processed.iPhoneSteps,
            watchSteps: processed.watchSteps,
            manualSteps: processed.manualSteps,
            thirdPartySteps: processed.thirdPartySteps,
            thirdPartySources: processed.thirdPartySources.sorted(),
            sampleCount: samples.count,
            samples: processed.items,
            clientSentAt: tNow,
            serverStatus: .pending,
            serverReceipt: nil,
            notes: nil
        )

        store.saveRecord(record)
        await uploadSubmission(record: &record, trigger: trigger, start: start, end: end, count: samples.count)
        store.updateRecord(record)
        reload()

        logSyncResult(record: record, trigger: trigger, count: samples.count)
        return record
    }

    private func determineTimeWindow(custom: DateInterval?, tNow: Date) -> (Date, Date) {
        if let custom = custom {
            return (custom.start, custom.end)
        }
        let last = store.loadState().lastSyncDate ?? Calendar.current.startOfDay(for: tNow)
        let start = last >= tNow ? tNow.addingTimeInterval(-15 * 60) : last
        return (start, tNow)
    }

    private func classifySamples(_ samples: [HKQuantitySample]) -> ProcessedSamples {
        var res = ProcessedSamples()
        for sample in samples {
            let count = Int(sample.quantity.doubleValue(for: .count()))
            let bundle = sample.sourceRevision.source.bundleIdentifier
            let name = sample.sourceRevision.source.name
            let model = sample.sourceRevision.productType ?? sample.device?.model ?? ""
            let isUserEntered = (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) == true
            let isAppleHealth = bundle.hasPrefix("com.apple.health")

            if isUserEntered {
                res.manualSteps += count
                res.items.append(PassiveSampleItem(
                    startDate: sample.startDate, endDate: sample.endDate, steps: count,
                    sourceBundle: bundle, sourceName: name, isDeviceHardware: false,
                    isUserEntered: true, deviceModel: model
                ))
            } else if isAppleHealth {
                res.deviceSteps += count
                if model.hasPrefix("Watch") { res.watchSteps += count } else { res.iPhoneSteps += count }
                res.items.append(PassiveSampleItem(
                    startDate: sample.startDate, endDate: sample.endDate, steps: count,
                    sourceBundle: bundle, sourceName: name, isDeviceHardware: true,
                    isUserEntered: false, deviceModel: model
                ))
            } else {
                res.thirdPartySteps += count
                res.thirdPartySources.insert(name)
                res.items.append(PassiveSampleItem(
                    startDate: sample.startDate, endDate: sample.endDate, steps: count,
                    sourceBundle: bundle, sourceName: name, isDeviceHardware: false,
                    isUserEntered: false, deviceModel: model
                ))
            }
        }
        return res
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
            record.notes = "Thành công: Server ghi nhận lúc \(Format.time.string(from: receipt.serverReceivedAt))"
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
        lastStatusMessage = "Đồng bộ \(trigger.shortTag) xong: +\(record.deviceSteps) bước máy, loại \(record.rejectedSteps) bước rác."
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
                startDate: start, endDate: end, steps: deviceSteps,
                sourceBundle: "com.apple.health", sourceName: "Apple Health",
                isDeviceHardware: true, isUserEntered: false, deviceModel: "iPhone16,1"
            ))
        }
        if manualSteps > 0 {
            sampleItems.append(PassiveSampleItem(
                startDate: start, endDate: end, steps: manualSteps,
                sourceBundle: "com.apple.Health", sourceName: "Health App (User)",
                isDeviceHardware: false, isUserEntered: true, deviceModel: nil
            ))
        }
        if thirdPartySteps > 0 {
            sampleItems.append(PassiveSampleItem(
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
            deviceSteps: deviceSteps,
            iPhoneSteps: deviceSteps,
            watchSteps: 0,
            manualSteps: manualSteps,
            thirdPartySteps: thirdPartySteps,
            thirdPartySources: thirdPartySteps > 0 ? [thirdPartyName] : [],
            sampleCount: sampleItems.count,
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
