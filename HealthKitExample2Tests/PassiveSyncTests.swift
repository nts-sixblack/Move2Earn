//
//  PassiveSyncTests.swift
//  HealthKitExample2Tests
//
//  Unit tests for Trường hợp 2: Passive Background HealthKit Sync.
//

import Foundation
import HealthKit
import Testing
@testable import HealthKitExample2

@Suite("PassiveSyncTests")
struct PassiveSyncTests {

    @Test
    @MainActor
    func storeSavesAndLoadsRecordsAtomically() throws {
        let store = PassiveSyncStore(store: FileStore.temporary())
        #expect(store.loadRecords().isEmpty)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let record = PassiveSyncRecord(
            id: UUID(),
            timestamp: now,
            trigger: .bgAppRefresh,
            queryStart: now.addingTimeInterval(-900),
            queryEnd: now,
            deviceSteps: 350,
            iPhoneSteps: 350,
            watchSteps: 0,
            manualSteps: 50,
            thirdPartySteps: 100,
            thirdPartySources: ["FakeApp"],
            sampleCount: 3,
            samples: [],
            clientSentAt: now,
            serverStatus: .pending,
            serverReceipt: nil,
            notes: "Test record"
        )

        store.saveRecord(record)
        let loaded = store.loadRecords()
        #expect(loaded.count == 1)
        #expect(loaded[0].deviceSteps == 350)
        #expect(loaded[0].manualSteps == 50)
        #expect(loaded[0].thirdPartySteps == 100)
        #expect(loaded[0].trigger == .bgAppRefresh)

        let state = store.loadState()
        #expect(state.totalDeviceStepsAllTime == 350)
        #expect(state.totalManualStepsFilteredAllTime == 50)
        #expect(state.totalThirdPartyStepsFilteredAllTime == 100)
        #expect(state.lastSyncDate == now)

        store.clearAll()
        #expect(store.loadRecords().isEmpty)
    }

    @Test
    @MainActor
    func storePersistsHealthKitAnchorAcrossClearAll() throws {
        let root = FileStore.temporary()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(PassiveSyncStore(store: root).loadAnchor() == nil)

        PassiveSyncStore(store: root).saveAnchor(HKQueryAnchor(fromValue: 42), baseline: baseline)
        let reopened = PassiveSyncStore(store: root)
        let saved = try #require(reopened.loadAnchor())
        #expect(saved.anchor == HKQueryAnchor(fromValue: 42))
        #expect(saved.baseline == baseline)

        reopened.clearAll()
        #expect(reopened.loadAnchor()?.anchor == HKQueryAnchor(fromValue: 42))
    }

    @Test
    @MainActor
    func passiveSyncFiltersManualAndThirdPartyStepsAndSubmitsToServer() async throws {
        let root = FileStore.temporary()
        let store = PassiveSyncStore(store: root.sub("passive_sync"))
        let server = MockPassiveServer(
            store: root.sub("server"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            simulateNetwork: false
        )
        let service = PassiveSyncService(
            store: store,
            healthKit: HealthKitProvider.shared,
            server: server,
            logger: EventLogger(store: root.sub("logs")),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            deviceId: { "test-device-uuid" }
        )

        // Simulate scenario with 500 device steps, 200 manual steps, 800 third party steps
        let record = await service.simulateScenario(
            trigger: .bgProcessing,
            deviceSteps: 500,
            manualSteps: 200,
            thirdPartySteps: 800,
            thirdPartyName: "ShakerApp"
        )

        #expect(record.deviceSteps == 500)
        #expect(record.manualSteps == 200)
        #expect(record.thirdPartySteps == 800)
        #expect(record.rejectedSteps == 1000)
        #expect(record.thirdPartySources == ["ShakerApp"])
        #expect(record.trigger == .bgProcessing)

        // Verify server status
        #expect(record.serverStatus.isSuccess)
        #expect(record.serverReceipt != nil)
        #expect(record.serverReceipt?.deviceSteps == 500)
        #expect(record.serverReceipt?.status == "recorded")

        // Verify server-side receipts
        let serverReceipts = try await server.passiveReceipts()
        #expect(serverReceipts.count == 1)
        #expect(serverReceipts[0].deviceId == "test-device-uuid")
        #expect(serverReceipts[0].deviceSteps == 500)

        // Verify service state
        #expect(service.records.count == 1)
        #expect(service.todayDeviceSteps == 500)
        #expect(service.todayManualStepsFiltered == 200)
        #expect(service.todayThirdPartyStepsFiltered == 800)
    }

    @Test
    @MainActor
    func failedUploadsStayLoggedAndAreRetriedOldestFirst() async throws {
        let root = FileStore.temporary()
        let server = FlakyPassiveServer(wrapping: MockPassiveServer(
            store: root.sub("server"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            simulateNetwork: false
        ))
        let service = PassiveSyncService(
            store: PassiveSyncStore(store: root.sub("passive_sync")),
            healthKit: HealthKitProvider.shared,
            server: server,
            logger: EventLogger(store: root.sub("logs")),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            deviceId: { "test-device-uuid" }
        )

        // Server is down: both records are still logged, the first upload fails and the
        // second one is not even attempted.
        server.failing = true
        let first = await service.simulateScenario(deviceSteps: 100, manualSteps: 0, thirdPartySteps: 0)
        let second = await service.simulateScenario(deviceSteps: 200, manualSteps: 0, thirdPartySteps: 0)
        #expect(service.records.count == 2)
        #expect(service.records.allSatisfy { $0.serverStatus.needsUpload })
        #expect(server.attemptedRecordIds == [first.id, first.id])
        #expect(second.notes == "Kịch bản test giả lập")

        // Server is back: the retry sends both, oldest first, and nothing is left waiting.
        server.failing = false
        let uploaded = await service.uploadPendingRecords()
        #expect(uploaded.map(\.id) == [first.id, second.id])
        #expect(service.records.allSatisfy { $0.serverStatus.isSuccess })
        #expect(try await server.passiveReceipts().map(\.deviceSteps) == [200, 100]) // server stores newest first
        #expect(await service.uploadPendingRecords().isEmpty)
    }

    @Test
    @MainActor
    func passiveSyncTriggerSourcesAndFileReload() async throws {
        let root = FileStore.temporary()
        let store = PassiveSyncStore(store: root.sub("passive_sync"))
        let server = MockPassiveServer(
            store: root.sub("server"),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            simulateNetwork: false
        )
        let service1 = PassiveSyncService(
            store: store,
            healthKit: HealthKitProvider.shared,
            server: server,
            logger: EventLogger(store: root.sub("logs")),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            deviceId: { "test-device-uuid" }
        )

        // 1. Trigger via HK wake
        await service1.simulateScenario(trigger: .healthKitWake, deviceSteps: 120, manualSteps: 0, thirdPartySteps: 0)

        // 2. Trigger via BGAppRefresh
        await service1.simulateScenario(trigger: .bgAppRefresh, deviceSteps: 250, manualSteps: 30, thirdPartySteps: 0)

        // 3. Trigger via BGProcessing
        await service1.simulateScenario(trigger: .bgProcessing, deviceSteps: 600, manualSteps: 0, thirdPartySteps: 150)

        #expect(service1.records.count == 3)

        // Instantiate new service (simulating app restart)
        let service2 = PassiveSyncService(
            store: store,
            healthKit: HealthKitProvider.shared,
            server: server,
            logger: EventLogger(store: root.sub("logs")),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            deviceId: { "test-device-uuid" }
        )

        #expect(service2.records.count == 3)
        #expect(service2.records[0].trigger == .bgProcessing)
        #expect(service2.records[1].trigger == .bgAppRefresh)
        #expect(service2.records[2].trigger == .healthKitWake)
        #expect(service2.todayDeviceSteps == 970)
        #expect(service2.todayManualStepsFiltered == 30)
        #expect(service2.todayThirdPartyStepsFiltered == 150)
    }
}

/// Passive server that can be switched off to exercise the retry path.
final class FlakyPassiveServer: PassiveSyncAPI {
    struct Offline: Error {}

    var failing = false
    private(set) var attemptedRecordIds: [UUID] = []
    private let wrapped: MockPassiveServer

    init(wrapping wrapped: MockPassiveServer) {
        self.wrapped = wrapped
    }

    func submitPassiveSync(_ submission: PassiveServerSubmission) async throws -> PassiveServerReceipt {
        attemptedRecordIds.append(submission.recordId)
        if failing { throw Offline() }
        return try await wrapped.submitPassiveSync(submission)
    }

    func passiveReceipts() async throws -> [PassiveServerReceipt] {
        try await wrapped.passiveReceipts()
    }
}
