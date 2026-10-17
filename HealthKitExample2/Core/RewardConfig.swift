//
//  RewardConfig.swift
//  HealthKitExample2
//
//  Every tunable number used by tracking, verification, rewards and the mock
//  server. In production this would be delivered by the server (remote config);
//  for now it is persisted locally and editable from Settings → Config.
//

import Foundation
import Combine

nonisolated struct RewardConfig: Codable, Equatable, Sendable {
    var version: Int = 1
    var tracking = TrackingConfig()
    var rules = VerificationRules()
    var reward = RewardRules()
    var limits = LimitRules()
    var mockServer = MockServerConfig()

    static let `default` = RewardConfig()
}

nonisolated struct TrackingConfig: Codable, Equatable, Sendable {
    /// Length of one verification window.
    var epochSeconds: Double = 60
    /// How often the in-flight session is persisted (max data lost on a crash).
    var checkpointSeconds: Double = 10
    /// Heartbeat period while the app is alive.
    var heartbeatSeconds: Double = 5
    /// Location fixes worse than this are ignored.
    var gpsMaxAccuracy: Double = 50
    /// 0 = every fix (~1Hz). Needed to tell "standing still" from "walking".
    var gpsDistanceFilter: Double = 0
    var motionSampleHz: Double = 25
}

nonisolated struct VerificationRules: Codable, Equatable, Sendable {
    /// Average GPS speed over an epoch above this = vehicle.
    var vehicleSpeedMps: Double = 7.5
    /// A single reported speed above this is suspicious.
    var maxInstantSpeedMps: Double = 11
    /// Jump between consecutive fixes faster than this = teleport / spoof.
    var teleportSpeedMps: Double = 60
    var teleportMinDistance: Double = 100
    var cadenceMax: Double = 240
    var runningCadence: Double = 145
    var strideMin: Double = 0.25
    var strideMax: Double = 2.5
    /// GPS vs pedometer distance ratio (either direction) tolerated.
    var gpsPedometerMismatchRatio: Double = 2.5
    var minGpsPointsForCoverage: Int = 5
    var stepsWithoutMovementMinSteps: Int = 60
    var stepsWithoutMovementMaxDisplacement: Double = 12
    /// Peak-interval coefficient of variation below this = machine-like rhythm.
    var roboticRhythmCV: Double = 0.012
    var roboticMinPeaks: Int = 40
    /// Cadence CV across consecutive epochs below this = machine-like.
    var roboticSessionCadenceCV: Double = 0.006
    var roboticSessionMinEpochs: Int = 8
    var automotiveFractionReject: Double = 0.25
    var cyclingFractionReject: Double = 0.5
    var stationaryFractionWarn: Double = 0.8
    var rejectSimulatedLocation: Bool = true
    var rejectSessionOnSpoofing: Bool = true
    var clockToleranceSeconds: Double = 30
    var rejectOnClockTamper: Bool = true
    var healthKitMismatchRatio: Double = 0.35
    var rejectJailbreak: Bool = true
    var rejectHookingLibraries: Bool = true
    var rejectDebugger: Bool = false
    var rejectSimulator: Bool = false
    /// Reports produced by the DEBUG replay sensor source.
    var rejectReplaySensors: Bool = true
    /// Trust penalty per warning flag.
    var warningPenalty: Double = 0.15
}

nonisolated struct RewardRules: Codable, Equatable, Sendable {
    var coinsPer1000StepsWalking: Double = 1.0
    var coinsPer1000StepsRunning: Double = 1.4
    var coinsPerVerifiedKm: Double = 0.3
    var recoveredMultiplier: Double = 0.7
    var noGpsMultiplier: Double = 0.85
    var minEpochSteps: Int = 10
    var minTrustToReward: Double = 0.4
    var decimals: Int = 3
}

nonisolated struct LimitRules: Codable, Equatable, Sendable {
    var dailyCoinCap: Double = 30
    var dailyStepCap: Int = 25_000
    var maxSessionsPerDay: Int = 10
    var sessionMinSeconds: Double = 120
    var sessionMaxSeconds: Double = 4 * 3600
    /// Longest gap (app killed / suspended) that may be back-filled from CoreMotion.
    var maxRecoveryGapSeconds: Double = 6 * 3600
    var autoEndIdleMinutes: Double = 30
}

nonisolated struct MockServerConfig: Codable, Equatable, Sendable {
    var latencyMs: Int = 400
    /// 0...1, simulate flaky network to exercise the retry queue.
    var failureRate: Double = 0
}

// MARK: - Store

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore(store: FileStore.app)

    @Published private(set) var config: RewardConfig
    private let store: FileStore
    private let fileName = "config.json"

    init(store: FileStore) {
        self.store = store
        self.config = (try? store.load(RewardConfig.self, from: fileName)) ?? .default
    }

    func update(_ newValue: RewardConfig) {
        var value = newValue
        if value != config { value.version = config.version + 1 }
        config = value
        try? store.save(value, to: fileName)
    }

    func reset() { update(.default) }

    func exportJSON() -> String {
        (try? String(data: FileStore.prettyEncoder.encode(config), encoding: .utf8)) ?? "{}"
    }

    func importJSON(_ json: String) throws {
        let value = try FileStore.decoder.decode(RewardConfig.self, from: Data(json.utf8))
        update(value)
    }
}
