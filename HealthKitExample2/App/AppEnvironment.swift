//
//  AppEnvironment.swift
//  HealthKitExample2
//

import Foundation

final class AppEnvironment {
    static let shared = AppEnvironment()

    let config: ConfigStore
    let logger: EventLogger
    let history: HistoryStore
    let server: MockRewardServer
    let wallet: WalletStore
    let sync: SyncService
    let session: SessionManager
    let location: LocationProvider

    private init() {
        let root = FileStore.app
        let config = ConfigStore.shared
        let logger = EventLogger.shared
        let history = HistoryStore(store: root.sub("history"))
        let server = MockRewardServer(
            store: root.sub("mock_server"),
            config: { config.config },
            // Simulated key registry: the server knows this device's key after onboarding.
            keyLookup: { $0 == DeviceIdentity.keyId ? DeviceIdentity.signingKey : nil })
        let wallet = WalletStore(api: server)
        let sync = SyncService(outbox: root.sub("outbox"), api: server, history: history, wallet: wallet,
                               logger: logger, config: { config.config })
        let location = LocationProvider()
        var steps: StepCounting = CorePedometer()
        var activity: ActivitySensing = CoreActivity()
        var source = "coremotion"
        #if DEBUG
        if SensorMode.replayEnabled {
            steps = ReplayPedometer()
            activity = ReplayActivity()
            source = "replay"
        }
        #endif
        let session = SessionManager(
            steps: steps, activity: activity, location: location, motion: AccelerometerAnalyzer(),
            store: root.sub("session"), logger: logger, config: { config.config },
            healthSummary: { await HealthKitProvider.shared.summary(from: $0, to: $1) },
            sensorSource: source,
            onReportReady: { await sync.handleFinished($0) })

        self.config = config
        self.logger = logger
        self.history = history
        self.server = server
        self.wallet = wallet
        self.sync = sync
        self.session = session
        self.location = location
    }

    /// Runs on every process launch, including silent background relaunches.
    func bootstrap(reason: String) async {
        await session.restoreIfNeeded(reason: reason)
        await sync.syncPending()
    }

    /// Resets all local data (debug only).
    func wipeAll() {
        session.discard()
        history.wipe()
        server.reset()
        FileStore.app.sub("outbox").wipe()
        Task { await wallet.refresh() }
    }
}
