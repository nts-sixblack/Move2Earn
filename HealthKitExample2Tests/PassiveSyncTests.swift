//
//  PassiveSyncTests.swift
//  HealthKitExample2Tests
//
//  Unit tests for Trường hợp 2: Passive Background HealthKit Sync.
//

import Foundation
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
