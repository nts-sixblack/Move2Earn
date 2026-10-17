import CryptoKit
import Foundation
@testable import HealthKitExample2

/// Controllable wall + monotonic clock.
final class FakeClock {
    var wall: Date
    var mono: UInt64 = 5_000_000_000_000
    var bootId = "test-boot"

    init(start: Date) { wall = start }

    func advance(_ seconds: Double) {
        wall = wall.addingTimeInterval(seconds)
        mono += UInt64(seconds * 1_000_000_000)
    }

    /// User changes the system clock: wall jumps, monotonic does not.
    func shiftWall(_ seconds: Double) { wall = wall.addingTimeInterval(seconds) }

    func reboot() {
        bootId = UUID().uuidString
        mono = 1_000_000_000
    }

    func anchor(_ date: Date) -> ClockAnchor { ClockAnchor(wall: date, monoNanos: mono, bootId: bootId) }
}

nonisolated final class FakePedometer: StepCounting, @unchecked Sendable {
    var stepsPerMinute: Double = 110
    var isAvailable: Bool { true }
    func query(from: Date, to: Date) async throws -> PedometerSample {
        let steps = Int((to.timeIntervalSince(from) / 60 * stepsPerMinute).rounded())
        return PedometerSample(start: from, end: to, steps: steps, distance: Double(steps) * 0.75, floorsAscended: 0)
    }
    func startLive(from: Date, handler: @escaping @Sendable (PedometerSample) -> Void) {}
    func stopLive() {}
}

nonisolated final class FakeActivity: ActivitySensing, @unchecked Sendable {
    var kind: ActivityKind = .walking
    var isAvailable: Bool { true }
    func query(from: Date, to: Date) async throws -> [ActivityPoint] {
        [ActivityPoint(t: from, kind: kind, confidence: 2)]
    }
    func startLive(handler: @escaping @Sendable (ActivityPoint) -> Void) {}
    func stopLive() {}
}

nonisolated final class FakeMotion: MotionAnalyzing, @unchecked Sendable {
    func start(hz: Double) {}
    func stop() {}
    func features(from: Date, to: Date) -> MotionFeatures? { nil }
}

final class FakeLocation: LocationTracking {
    var onPoints: (([LocationPoint]) -> Void)?
    var onAuthorizationChange: ((LocationAuth) -> Void)?
    var authorization: LocationAuth = .always
    var preciseLocation: Bool { true }
    private(set) var started = false
    func requestWhenInUse() {}
    func requestAlways() {}
    func start(config: TrackingConfig) { started = true }
    func stop() { started = false }
}

/// Reference box so closures handed to SessionManager don't capture the harness itself.
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// One "process" of the app: a SessionManager bound to a persistent store.
final class Harness {
    let clock: FakeClock
    let store: FileStore
    let logger: EventLogger
    let pedometer = FakePedometer()
    let activity = FakeActivity()
    let location = FakeLocation()
    private let configBox = Box(RewardConfig.default)
    private let reportsBox = Box([SessionReport]())
    private(set) var manager: SessionManager!

    var config: RewardConfig {
        get { configBox.value }
        set { configBox.value = newValue }
    }
    var reports: [SessionReport] { reportsBox.value }

    init(clock: FakeClock, store: FileStore = .temporary(), logger: EventLogger? = nil) {
        self.clock = clock
        self.store = store
        self.logger = logger ?? EventLogger(store: store.sub("logs"))
        launch()
    }

    /// Simulates the process being killed and launched again (in-memory state lost, disk kept).
    func launch() {
        let clock = clock
        let configBox = configBox
        let reportsBox = reportsBox
        manager = SessionManager(
            steps: pedometer, activity: activity, location: location, motion: FakeMotion(),
            store: store.sub("session"), logger: logger, config: { configBox.value },
            now: { clock.wall },
            anchor: { clock.anchor($0) },
            integrity: { _ in SyntheticData.cleanIntegrity },
            useTimer: false,
            onReportReady: { report in reportsBox.value.append(report) })
    }

    /// Advances time with heartbeats, like an app alive in the background.
    func runAlive(seconds: Double, step: Double = 5) async {
        var elapsed = 0.0
        while elapsed < seconds {
            clock.advance(step)
            elapsed += step
            await manager.tick()
        }
    }

    func submit(_ report: SessionReport, to server: MockRewardServer, key: CryptoKitKey) -> RewardReceipt {
        let signed = try! ReportSigner.sign(report, key: key.key, keyId: key.id)
        return server.process(Submission.make(signed, anchor: clock.anchor(clock.wall), key: key.key))
    }

    func server() -> (MockRewardServer, CryptoKitKey) {
        let key = CryptoKitKey()
        let clock = clock
        let configBox = configBox
        let server = MockRewardServer(store: .temporary(), config: { configBox.value },
                                      keyLookup: { $0 == key.id ? key.key : nil },
                                      now: { clock.wall }, simulateNetwork: false)
        return (server, key)
    }
}

struct CryptoKitKey {
    let key = SymmetricKey(size: .bits256)
    let id = "test-key"
}
