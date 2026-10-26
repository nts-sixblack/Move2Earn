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
    private var queueTail: Task<Void, Never>?

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

    /// Logs the samples added to HealthKit since the last run as a record waiting for upload.
    /// Nothing is sent to the server; use `uploadPendingRecords()` or `sync(trigger:)` for that.
    @discardableResult
    func recordNewSamples(trigger: PassiveTriggerSource,
                          customWindow: DateInterval? = nil,
                          scopeOverride: QueryWindowScope? = nil) async -> PassiveSyncRecord? {
        await serialized {
            await self.logNewSamples(trigger: trigger, customWindow: customWindow,
                                     scopeOverride: scopeOverride, skipIfEmpty: false)
        }
    }

    /// Sends every record the server has not acknowledged yet (pending or failed), oldest first.
    @discardableResult
    func uploadPendingRecords() async -> [PassiveSyncRecord] {
        await serialized { await self.uploadPending() }
    }

    /// Full passive sync triggered by HealthKit background delivery, BGAppRefreshTask,
    /// BGProcessingTask, or manual user test. Before uploading it checks HealthKit once more
    /// and logs any samples added since the last log, so the upload is not missing data.
    @discardableResult
    func sync(trigger: PassiveTriggerSource,
              customWindow: DateInterval? = nil,
              scopeOverride: QueryWindowScope? = nil) async -> [PassiveSyncRecord] {
        await serialized {
            let logged = await self.logNewSamples(trigger: trigger, customWindow: customWindow,
                                                  scopeOverride: scopeOverride, skipIfEmpty: true)
            let uploaded = await self.uploadPending()
            let failed = uploaded.filter { !$0.serverStatus.isSuccess }.count
            self.lastStatusMessage = "Đồng bộ \(trigger.shortTag): +\(logged?.deviceSteps ?? 0) bước máy mới, "
                + "gửi \(uploaded.count - failed)/\(uploaded.count) bản ghi."
            return uploaded
        }
    }

    /// Runs `operation` after every earlier one has finished. Logging reads the HealthKit anchor
    /// saved by the previous run and uploading reads the records it saved, so two overlapping
    /// triggers must never interleave: they would count or upload the same samples twice.
    private func serialized<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = queueTail
        let run = Task { @MainActor in
            await previous?.value
            self.isSyncing = true
            defer { self.isSyncing = false }
            return await operation()
        }
        queueTail = Task { _ = await run.value }
        return await run.value
    }

    /// Saves samples added since the last anchor as a pending record, then advances the anchor.
    /// With `skipIfEmpty` no record is written when there is nothing new.
    private func logNewSamples(trigger: PassiveTriggerSource,
                               customWindow: DateInterval?,
                               scopeOverride: QueryWindowScope?,
                               skipIfEmpty: Bool) async -> PassiveSyncRecord? {
        let tNow = now()
        let activeScope = scopeOverride ?? selectedScope
        let (start, end) = determineTimeWindow(custom: customWindow, scope: activeScope, tNow: tNow)

        // Ensure HealthKit authorization has been requested
        if !(await healthKit.hasRequestedAuthorization()) {
            try? await healthKit.requestAuthorization()
        }

        // New samples come from the anchored query; the window is only used for the
        // HealthKit statistics total shown alongside them. The first run starts counting
        // from the beginning of today and that baseline is kept for every later run.
        let saved = store.loadAnchor()
        let baseline = saved?.baseline ?? Calendar.current.startOfDay(for: tNow)
        async let cumulativeTask = healthKit.fetchCumulativeSteps(from: start, to: end)
        async let changesTask = healthKit.fetchStepSampleChanges(since: saved?.anchor, startingFrom: baseline)

        let rawTotalSteps = await cumulativeTask
        let changes = await changesTask
        let samples = changes?.added ?? []

        if skipIfEmpty && samples.isEmpty {
            // No samples means there is nothing to lose, so the anchor can move past deletions.
            if let changes {
                store.saveAnchor(changes.newAnchor, baseline: baseline)
            }
            logRecordResult(record: nil, trigger: trigger, queryFailed: changes == nil,
                            deleted: changes?.deletedCount ?? 0)
            return nil
        }

        let processed = classifySamples(samples)
        let countedEarlier = records
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .reduce(0) { $0 + $1.deviceSteps }

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
            cumulativeStepsToday: countedEarlier + processed.deviceSteps,
            samples: processed.items,
            clientSentAt: tNow,
            serverStatus: .pending,
            serverReceipt: nil,
            notes: nil
        )

        buildDiagnosticsNote(&record, samplesCount: samples.count, rawTotal: rawTotalSteps, scope: activeScope,
                             queryFailed: changes == nil)

        // Advance the anchor only after the record is on disk: if the app dies in between,
        // the next run re-reads the same samples instead of losing them.
        store.saveRecord(record)
        if let changes {
            store.saveAnchor(changes.newAnchor, baseline: baseline)
        }
        reload()

        logRecordResult(record: record, trigger: trigger, queryFailed: changes == nil,
                        deleted: changes?.deletedCount ?? 0)
        return record
    }

    /// Uploads waiting records oldest first and stops at the first failure: the rest are most
    /// likely to fail the same way, and they stay waiting for the next run.
    @discardableResult
    private func uploadPending() async -> [PassiveSyncRecord] {
        let waiting = store.loadRecords().filter(\.serverStatus.needsUpload).reversed()
        var uploaded: [PassiveSyncRecord] = []
        for var record in waiting {
            await uploadSubmission(record: &record)
            store.updateRecord(record)
            uploaded.append(record)
            if !record.serverStatus.isSuccess { break }
        }
        reload()

        if !uploaded.isEmpty {
            _ = logger.log("passiveUploadExecuted", [
                "attempted": String(uploaded.count),
                "succeeded": String(uploaded.filter(\.serverStatus.isSuccess).count),
                "remaining": String(waiting.count - uploaded.filter(\.serverStatus.isSuccess).count)
            ])
        }
        return uploaded
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

    /// Splits newly added samples into device / manual / third-party steps.
    private func classifySamples(_ samples: [HKQuantitySample]) -> ProcessedSamples {
        var res = ProcessedSamples()

        for sample in samples {
            let count = Int(sample.quantity.doubleValue(for: .count()))
            let bundle = sample.sourceRevision.source.bundleIdentifier
            let name = sample.sourceRevision.source.name
            let model = sample.sourceRevision.productType ?? sample.device?.model ?? ""
            let isUserEntered = (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) == true
            let isApple = HealthKitProvider.isAppleDeviceHardware(bundleIdentifier: bundle)
            let sampleId = sample.uuid.uuidString

            if isUserEntered {
                res.manualSteps += count
                res.items.append(PassiveSampleItem(
                    sampleUUID: sampleId, startDate: sample.startDate, endDate: sample.endDate, steps: count,
                    sourceBundle: bundle, sourceName: name, isDeviceHardware: false,
                    isUserEntered: true, deviceModel: model
                ))
            } else if isApple {
                res.deviceSteps += count
                if model.hasPrefix("Watch") { res.watchSteps += count } else { res.iPhoneSteps += count }
                res.items.append(PassiveSampleItem(
                    sampleUUID: sampleId, startDate: sample.startDate, endDate: sample.endDate, steps: count,
                    sourceBundle: bundle, sourceName: name, isDeviceHardware: true,
                    isUserEntered: false, deviceModel: model
                ))
            } else {
                res.thirdPartySteps += count
                res.thirdPartySources.insert(name)
                res.items.append(PassiveSampleItem(
                    sampleUUID: sampleId, startDate: sample.startDate, endDate: sample.endDate, steps: count,
                    sourceBundle: bundle, sourceName: name, isDeviceHardware: false,
                    isUserEntered: false, deviceModel: model
                ))
            }
        }
        return res
    }

    private func buildDiagnosticsNote(_ record: inout PassiveSyncRecord, samplesCount: Int,
                                      rawTotal: Int, scope: QueryWindowScope, queryFailed: Bool) {
        if queryFailed {
            record.notes = "Không đọc được mẫu mới từ HealthKit. Lần đồng bộ sau sẽ thử lại từ cùng vị trí."
        } else if samplesCount == 0 {
            if rawTotal > 0 {
                record.notes = "Không có mẫu mới kể từ lần đồng bộ trước (HealthKit: \(rawTotal) bước trong \(scope.displayName))."
            } else {
                record.notes = "Không tìm thấy bước chân trong \(scope.displayName). Hãy kiểm tra app Sức khoẻ."
            }
        } else if record.deviceSteps == 0 && record.cumulativeStepsToday > 0 {
            record.notes = "Đã tìm thấy \(record.cumulativeStepsToday) bước hôm nay (đã đồng bộ ở các lần trước)."
        }
    }

    /// A retried record keeps its `recordId`, so the server can recognise a resend.
    private func uploadSubmission(record: inout PassiveSyncRecord) async {
        let sentAt = now()
        record.clientSentAt = sentAt
        let submission = PassiveServerSubmission(
            submissionId: UUID(),
            recordId: record.id,
            deviceId: deviceId(),
            clientSentAt: sentAt,
            trigger: record.trigger,
            periodStart: record.queryStart,
            periodEnd: record.queryEnd,
            deviceSteps: record.deviceSteps,
            manualStepsFiltered: record.manualSteps,
            thirdPartyStepsFiltered: record.thirdPartySteps,
            sampleCount: record.sampleCount
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
            // The reason is kept in `serverStatus`; `notes` keeps the HealthKit diagnostics
            // so they are still there once a retry succeeds.
            record.serverStatus = .failed(reason: error.localizedDescription)
        }
    }

    /// `record` is nil when the run found nothing new and skipped writing a record.
    private func logRecordResult(record: PassiveSyncRecord?, trigger: PassiveTriggerSource,
                                 queryFailed: Bool, deleted: Int) {
        _ = logger.log("passiveSamplesRecorded", [
            "trigger": trigger.rawValue,
            "deviceSteps": String(record?.deviceSteps ?? 0),
            "manualFiltered": String(record?.manualSteps ?? 0),
            "thirdPartyFiltered": String(record?.thirdPartySteps ?? 0),
            "samples": String(record?.sampleCount ?? 0),
            "deletedSamples": String(deleted),
            "queryFailed": String(queryFailed),
            "recordSaved": String(record != nil)
        ])
        if let record {
            lastStatusMessage = "Ghi log \(trigger.shortTag): +\(record.deviceSteps) bước máy mới, chờ gửi server "
                + "(Hôm nay: \(record.cumulativeStepsToday))."
        }
    }

    /// Creates a simulated passive sync event for testing filtering and server timestamp logging
    /// on Simulator or without walking.
    @discardableResult
    func simulateScenario(trigger: PassiveTriggerSource = .manualTest,
                          deviceSteps: Int,
                          manualSteps: Int,
                          thirdPartySteps: Int,
                          thirdPartyName: String = "CheatStepsApp") async -> PassiveSyncRecord {
        await serialized {
            await self.logAndUploadSimulated(trigger: trigger, deviceSteps: deviceSteps, manualSteps: manualSteps,
                                             thirdPartySteps: thirdPartySteps, thirdPartyName: thirdPartyName)
        }
    }

    private func logAndUploadSimulated(trigger: PassiveTriggerSource, deviceSteps: Int, manualSteps: Int,
                                       thirdPartySteps: Int, thirdPartyName: String) async -> PassiveSyncRecord {
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

        let logged = PassiveSyncRecord(
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

        store.saveRecord(logged)
        await uploadPending()
        let record = records.first { $0.id == logged.id } ?? logged

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
