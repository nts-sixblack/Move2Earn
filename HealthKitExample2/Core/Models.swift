//
//  Models.swift
//  HealthKitExample2
//
//  Raw data captured on device. Everything here is plain, Codable and
//  nonisolated so it can be produced by sensor callbacks, persisted, signed,
//  and re-verified by the (mock) server without touching the main actor.
//

import Foundation

// MARK: - Sensor primitives

nonisolated enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case walking, running, cycling, automotive, stationary, unknown
}

/// Whether an epoch was observed live (app alive, GPS + accelerometer running)
/// or reconstructed afterwards from CoreMotion history (app suspended / killed).
nonisolated enum EpochSource: String, Codable, Sendable {
    case live, recovered
}

nonisolated enum AppPhase: String, Codable, Sendable {
    case foreground, background, notRunning
}

nonisolated struct LocationPoint: Codable, Hashable, Sendable {
    var t: Date
    var lat: Double
    var lon: Double
    var alt: Double
    var hAcc: Double
    var vAcc: Double
    /// m/s reported by CoreLocation, negative when invalid.
    var speed: Double
    var speedAcc: Double
    var course: Double
    /// `CLLocationSourceInformation.isSimulatedBySoftware` (Xcode/3uTools/iSpoofer style spoofing).
    var simulated: Bool
    /// `CLLocationSourceInformation.isProducedByAccessory` (external GPS dongle).
    var accessory: Bool
}

nonisolated struct ActivityPoint: Codable, Hashable, Sendable {
    var t: Date
    var kind: ActivityKind
    /// 0 = low, 1 = medium, 2 = high (CMMotionActivityConfidence)
    var confidence: Int
}

nonisolated struct PedometerSample: Codable, Hashable, Sendable {
    var start: Date
    var end: Date
    var steps: Int
    var distance: Double?
    var floorsAscended: Int?
}

/// Accelerometer derived features for one epoch. Shaker machines / pendulums
/// produce an unnaturally regular step rhythm (very low interval CV).
nonisolated struct MotionFeatures: Codable, Hashable, Sendable {
    var sampleCount: Int
    var peakCount: Int
    var magnitudeStd: Double
    var peakIntervalCV: Double?
}

// MARK: - Epoch

/// Fixed-length time window (default 60s). The unit of verification and reward.
nonisolated struct Epoch: Codable, Hashable, Identifiable, Sendable {
    var index: Int
    var start: Date
    var end: Date
    var source: EpochSource
    var phase: AppPhase
    /// Fraction of the window during which the app was alive (heartbeats).
    var aliveFraction: Double

    var steps: Int
    var pedometerDistance: Double?
    var floorsAscended: Int?

    var gpsPoints: Int
    var gpsDistance: Double
    /// Straight-line distance first → last accepted point.
    var gpsDisplacement: Double
    var gpsAvgAccuracy: Double?
    var gpsMaxSpeed: Double
    var gpsAvgSpeed: Double?
    var simulatedPoints: Int
    var teleports: Int

    /// Fraction of the window per `ActivityKind.rawValue`.
    var activity: [String: Double]
    var dominantActivity: ActivityKind
    var motion: MotionFeatures?

    var id: Int { index }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    /// Steps per minute.
    var cadence: Double { duration > 0 ? Double(steps) / (duration / 60) : 0 }

    func activityFraction(_ kind: ActivityKind) -> Double { activity[kind.rawValue] ?? 0 }
}

// MARK: - Clock

/// A pair of wall-clock and monotonic (continues during sleep, cannot be changed
/// by the user) timestamps. Comparing two anchors reveals manual clock changes.
nonisolated struct ClockAnchor: Codable, Hashable, Sendable {
    var wall: Date
    var monoNanos: UInt64
    var bootId: String
}

// MARK: - Flags

nonisolated enum FlagSeverity: String, Codable, Sendable, Comparable {
    case info, warning, reject

    private var rank: Int { self == .info ? 0 : self == .warning ? 1 : 2 }
    static func < (lhs: FlagSeverity, rhs: FlagSeverity) -> Bool { lhs.rank < rhs.rank }
}

nonisolated enum FlagCode: String, Codable, CaseIterable, Sendable {
    // Epoch level
    case vehicleSpeed, instantSpeedSpike, automotiveActivity, cyclingActivity
    case cadenceTooHigh, strideImplausible, gpsPedometerMismatch
    case simulatedLocation, teleport, noGpsCoverage, stepsWithoutMovement
    case stationaryWithSteps, roboticRhythm, recoveredData, beyondSessionMax
    // Session level
    case clockTampered, clockMovedBackwards, deviceRebooted, timezoneChanged
    case jailbroken, debuggerAttached, simulatorDevice, hookingLibrary
    case sessionTooShort, epochOverlap, epochOutOfBounds, futureEpoch
    case healthKitMismatch, manualHealthEntry, thirdPartyHealthSteps
    case permissionRevoked, appRelaunched, gapExceeded, logChainBroken
    case signatureInvalid, duplicateSubmission, overlapsCreditedSession
    case dailyStepCap, dailyCoinCap, dailySessionCap, malformedReport, replaySensors
}

nonisolated struct Flag: Codable, Hashable, Sendable, Identifiable {
    var code: FlagCode
    var severity: FlagSeverity
    var epochIndex: Int?
    var detail: String
    var id: String { "\(code.rawValue)-\(epochIndex ?? -1)-\(detail)" }
}

// MARK: - Integrity & HealthKit

nonisolated struct IntegritySnapshot: Codable, Hashable, Sendable {
    var isSimulator: Bool
    var isJailbroken: Bool
    var jailbreakSignals: [String]
    var debuggerAttached: Bool
    var suspiciousLibraries: [String]
    var appAttestSupported: Bool
    var lowPowerMode: Bool
    var preciseLocation: Bool?
}

nonisolated struct HealthKitSummary: Codable, Hashable, Sendable {
    var authorized: Bool
    var iPhoneSteps: Int
    var watchSteps: Int
    var thirdPartySteps: Int
    var manualSteps: Int
    var thirdPartySources: [String]
}

// MARK: - Session

nonisolated enum EndReason: String, Codable, Sendable {
    case user, idle, maxDuration, gapExceeded, permissionRevoked
}

/// The in-flight session, checkpointed to disk so it survives suspension,
/// jetsam, force-quit and reboot.
nonisolated struct ActiveSession: Codable, Sendable {
    var id: UUID
    var nonce: String
    var startedAt: Date
    var startAnchor: ClockAnchor
    var lastTick: ClockAnchor
    var nextEpochStart: Date
    var nextEpochIndex: Int
    var aliveIntervals: [DateInterval]
    var pendingLocations: [LocationPoint]
    var epochs: [Epoch]
    var clientFlags: [Flag]
    var firstLogSeq: Int
    var relaunchCount: Int
    var routePointCount: Int
    var routeDistance: Double
    /// Last accepted fix of the previous epoch, so jumps across epoch boundaries are caught.
    var lastEpochLocation: LocationPoint?
    var lastRouteLocation: LocationPoint?
    /// Foreground/background transitions, so each epoch records the phase it was observed in.
    var phaseMarks: [PhaseMark]?
}

nonisolated struct PhaseMark: Codable, Hashable, Sendable {
    var t: Date
    var phase: AppPhase
}

nonisolated struct SessionReport: Codable, Sendable {
    var schemaVersion: Int = 1
    var sessionId: UUID
    var nonce: String
    var deviceId: String
    var appVersion: String
    var osVersion: String
    var deviceModel: String
    var configVersion: Int
    var startedAt: Date
    var endedAt: Date
    var endReason: EndReason
    var startAnchor: ClockAnchor
    var endAnchor: ClockAnchor
    var epochs: [Epoch]
    var routePointCount: Int
    var routeDistance: Double
    var routeHash: String
    var healthKit: HealthKitSummary?
    var integrity: IntegritySnapshot
    var clientFlags: [Flag]
    var events: [LogEntry]
    var createdAt: Date
    /// "coremotion" in production; "replay" for the DEBUG simulator source.
    var sensorSource: String? = nil

    var totalSteps: Int { epochs.reduce(0) { $0 + $1.steps } }
}

/// What actually goes over the wire: the exact signed bytes plus signature.
nonisolated struct SignedReport: Codable, Sendable {
    var payload: Data
    var payloadHash: String
    var signature: String
    var keyId: String
}
