//
//  SyntheticScenarios.swift
//  HealthKitExample2
//
//  Deterministic synthetic sessions — honest and cheating — pushed through the
//  real pipeline (EpochBuilder → report → HMAC → Submission → MockRewardServer).
//  Used by the in-app Scenario Lab and by the unit tests.
//

import CryptoKit
import Foundation

/// SplitMix64 — deterministic randomness so scenarios are reproducible.
nonisolated struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * next() }
}

nonisolated struct MotionProfile: Sendable {
    var cadence: Double
    /// Relative minute-to-minute cadence variation (humans ~3-8%, machines ~0).
    var cadenceJitter: Double
    var speed: Double
    var activity: ActivityKind
    var gps: Bool = true
    var gpsStationary = false
    var simulatedGPS = false
    var rhythmCV: Double = 0.05
    var live = true
    var stride: Double = 0.75
}

nonisolated enum SyntheticData {
    static let bootId = "lab-boot"
    static let baseLat = 10.7769
    static let baseLon = 106.7009

    static func anchor(_ wall: Date, origin: Date, offset: Double = 0) -> ClockAnchor {
        // Monotonic clock = real elapsed time; `offset` simulates a wrong device wall clock.
        ClockAnchor(wall: wall.addingTimeInterval(offset),
                    monoNanos: UInt64(max(0, wall.timeIntervalSince(origin) + 10_000) * 1_000_000_000),
                    bootId: bootId)
    }

    static func epochs(start: Date, count: Int, profile: MotionProfile, startIndex: Int = 0,
                       config: RewardConfig = .default, seed: UInt64 = 1,
                       teleportAtEpoch: Int? = nil) -> [Epoch] {
        var rng = SeededRandom(seed: seed)
        var result: [Epoch] = []
        let length = config.tracking.epochSeconds
        var lat = baseLat
        var lon = baseLon
        var previous: LocationPoint?
        for k in 0..<count {
            let s = start.addingTimeInterval(Double(k) * length)
            let e = s.addingTimeInterval(length)
            let cadence = profile.cadence * (1 + profile.cadenceJitter * rng.range(-1...1))
            let steps = Int((cadence * length / 60).rounded())
            var locations: [LocationPoint] = []
            if profile.gps && profile.live {
                for j in stride(from: 0.0, to: length, by: 2) {
                    let t = s.addingTimeInterval(j + 0.5)
                    if profile.gpsStationary {
                        lat = baseLat + rng.range(-1...1) * 0.00001
                        lon = baseLon + rng.range(-1...1) * 0.00001
                    } else {
                        let metres = profile.speed * 2
                        lat += metres / 111_320
                        lon += 0.000001 * rng.range(-1...1)
                    }
                    if teleportAtEpoch == startIndex + k, j == 30 { lat += 0.02 }  // ≈2.2 km jump
                    locations.append(LocationPoint(t: t, lat: lat, lon: lon, alt: 5, hAcc: 8, vAcc: 6,
                                                   speed: profile.gpsStationary ? 0 : profile.speed, speedAcc: 0.6,
                                                   course: 0, simulated: profile.simulatedGPS, accessory: false))
                }
            }
            let pedometer = PedometerSample(start: s, end: e, steps: steps,
                                            distance: Double(steps) * profile.stride, floorsAscended: 0)
            let activities = [ActivityPoint(t: s.addingTimeInterval(-10), kind: profile.activity, confidence: 2)]
            let motion = profile.live
                ? MotionFeatures(sampleCount: 1500, peakCount: steps,
                                 magnitudeStd: 0.3, peakIntervalCV: profile.rhythmCV * rng.range(0.8...1.2))
                : nil
            let epoch = EpochBuilder.build(index: startIndex + k, start: s, end: e, pedometer: pedometer,
                                           activities: activities, locations: locations, previousLocation: previous,
                                           motion: motion, aliveFraction: profile.live ? 1 : 0,
                                           phase: .background, tracking: config.tracking, rules: config.rules)
            previous = locations.last
            result.append(epoch)
        }
        return result
    }

    static let cleanIntegrity = IntegritySnapshot(isSimulator: false, isJailbroken: false, jailbreakSignals: [],
                                                  debuggerAttached: false, suspiciousLibraries: [],
                                                  appAttestSupported: true, lowPowerMode: false, preciseLocation: true)

    static func report(id: UUID = UUID(), epochs: [Epoch], start: Date, end: Date, origin: Date,
                       clockOffset: Double = 0, endMonoSkew: Double = 0,
                       integrity: IntegritySnapshot = cleanIntegrity, clientFlags: [Flag] = [],
                       deviceId: String = "lab-device", configVersion: Int = 1) -> SessionReport {
        let shifted = epochs.map { e -> Epoch in
            var e = e
            e.start = e.start.addingTimeInterval(clockOffset)
            e.end = e.end.addingTimeInterval(clockOffset)
            return e
        }
        var endAnchor = anchor(end, origin: origin, offset: clockOffset)
        endAnchor.monoNanos = UInt64(Double(endAnchor.monoNanos) + endMonoSkew * 1_000_000_000)
        var events: [LogEntry] = []
        func log(_ type: String, _ t: Date) {
            let prev = events.last?.hash ?? HashChain.genesis
            events.append(HashChain.make(seq: events.count + 1, t: t.addingTimeInterval(clockOffset),
                                         monoNanos: anchor(t, origin: origin).monoNanos, type: type, level: .info,
                                         sessionId: id, data: [:], prevHash: prev))
        }
        log("sessionStarted", start)
        for e in epochs { log("epochClosed", e.end) }
        log("sessionEnded", end)
        return SessionReport(sessionId: id, nonce: id.uuidString, deviceId: deviceId, appVersion: "lab",
                             osVersion: "lab", deviceModel: "lab", configVersion: configVersion,
                             startedAt: start.addingTimeInterval(clockOffset), endedAt: end.addingTimeInterval(clockOffset),
                             endReason: .user,
                             startAnchor: anchor(start, origin: origin, offset: clockOffset), endAnchor: endAnchor,
                             epochs: shifted, routePointCount: 0, routeDistance: 0, routeHash: "",
                             healthKit: nil, integrity: integrity, clientFlags: clientFlags, events: events,
                             createdAt: end.addingTimeInterval(clockOffset))
    }
}

// MARK: - Scenarios

enum Scenario: String, CaseIterable, Identifiable {
    case legitWalk, legitRun, killedAndRecovered, treadmillIndoor
    case carRide, shakingPhoneInCar, bikeRide, phoneShaker, handShakeInPlace, gpsSpoof, teleport
    case cadenceTooHigh, clockTamperDuring, clockOffsetBeforeStart, jailbroken
    case tamperedPayload, replay, overlappingSession, tooShort, dailyCap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .legitWalk: "Đi bộ hợp lệ"
        case .legitRun: "Chạy bộ hợp lệ"
        case .killedAndRecovered: "Kill app giữa chừng → khôi phục"
        case .treadmillIndoor: "Máy chạy bộ (không GPS)"
        case .carRide: "Đi ô tô"
        case .shakingPhoneInCar: "Lắc điện thoại trên ô tô"
        case .bikeRide: "Đạp xe"
        case .phoneShaker: "Máy lắc điện thoại"
        case .handShakeInPlace: "Lắc tay tại chỗ"
        case .gpsSpoof: "Fake GPS (simulated)"
        case .teleport: "GPS nhảy (teleport)"
        case .cadenceTooHigh: "Bước chân bất khả thi"
        case .clockTamperDuring: "Chỉnh giờ trong session"
        case .clockOffsetBeforeStart: "Chỉnh giờ trước khi chạy"
        case .jailbroken: "Thiết bị jailbreak"
        case .tamperedPayload: "Sửa payload sau khi ký"
        case .replay: "Gửi lại report (replay)"
        case .overlappingSession: "2 session trùng thời gian"
        case .tooShort: "Session quá ngắn"
        case .dailyCap: "Vượt giới hạn coin/ngày"
        }
    }

    enum Expectation {
        case credited
        case creditedWith(FlagCode)
        case rejected(FlagCode)
        case zeroCoins(FlagCode)
        case duplicate
        case capped(FlagCode)
    }

    var expectation: Expectation {
        switch self {
        case .legitWalk, .legitRun: .credited
        case .killedAndRecovered: .creditedWith(.recoveredData)
        case .treadmillIndoor: .creditedWith(.noGpsCoverage)
        case .handShakeInPlace: .creditedWith(.stepsWithoutMovement)
        case .carRide, .shakingPhoneInCar: .zeroCoins(.automotiveActivity)
        case .bikeRide: .zeroCoins(.cyclingActivity)
        case .phoneShaker: .zeroCoins(.roboticRhythm)
        case .gpsSpoof: .rejected(.simulatedLocation)
        case .teleport: .rejected(.teleport)
        case .cadenceTooHigh: .zeroCoins(.cadenceTooHigh)
        case .clockTamperDuring, .clockOffsetBeforeStart: .rejected(.clockTampered)
        case .jailbroken: .rejected(.jailbroken)
        case .tamperedPayload: .rejected(.signatureInvalid)
        case .replay: .duplicate
        case .overlappingSession: .zeroCoins(.overlapsCreditedSession)
        case .tooShort: .rejected(.sessionTooShort)
        case .dailyCap: .capped(.dailyCoinCap)
        }
    }
}

struct ScenarioResult: Identifiable {
    var scenario: Scenario
    var receipt: RewardReceipt
    var passed: Bool
    var note: String
    var id: String { scenario.rawValue }
}

/// Runs a scenario against an isolated MockRewardServer (temp storage, own key).
final class ScenarioRunner {
    private let key = SymmetricKey(size: .bits256)
    private let keyId = "lab-key"
    private let serverNow: Date
    private let origin: Date

    init(now: Date = Date()) {
        serverNow = now
        origin = now.addingTimeInterval(-3 * 3600)
    }

    func runAll() -> [ScenarioResult] { Scenario.allCases.map(run) }

    func run(_ scenario: Scenario) -> ScenarioResult {
        var config = RewardConfig.default
        if scenario == .dailyCap { config.limits.dailyCoinCap = 1.0 }
        let server = MockRewardServer(store: .temporary(), config: { config },
                                      keyLookup: { [key, keyId] in $0 == keyId ? key : nil },
                                      now: { [serverNow] in serverNow }, simulateNetwork: false)
        let start = serverNow.addingTimeInterval(-40 * 60)
        let walk = MotionProfile(cadence: 108, cadenceJitter: 0.06, speed: 1.35, activity: .walking)

        func session(_ profile: MotionProfile, count: Int = 20, startAt: Date? = nil, seed: UInt64 = 7,
                     teleportAt: Int? = nil) -> (epochs: [Epoch], start: Date, end: Date) {
            let s = startAt ?? start
            let epochs = SyntheticData.epochs(start: s, count: count, profile: profile, config: config, seed: seed,
                                              teleportAtEpoch: teleportAt)
            return (epochs, s, epochs.last?.end ?? s)
        }

        func submit(_ report: SessionReport, mutate: ((inout SignedReport) -> Void)? = nil,
                    sentOffset: Double = 0) -> RewardReceipt {
            var signed = (try? ReportSigner.sign(report, key: key, keyId: keyId))
                ?? SignedReport(payload: Data(), payloadHash: "", signature: "", keyId: keyId)
            mutate?(&signed)
            let sent = SyntheticData.anchor(serverNow, origin: origin, offset: sentOffset)
            return server.process(Submission.make(signed, anchor: sent, key: key))
        }

        func standard(_ profile: MotionProfile, count: Int = 20, teleportAt: Int? = nil,
                      integrity: IntegritySnapshot = SyntheticData.cleanIntegrity) -> RewardReceipt {
            let s = session(profile, count: count, teleportAt: teleportAt)
            return submit(SyntheticData.report(epochs: s.epochs, start: s.start, end: s.end, origin: origin,
                                               integrity: integrity))
        }

        let receipt: RewardReceipt
        var note = ""
        switch scenario {
        case .legitWalk, .dailyCap:
            receipt = standard(walk)
        case .legitRun:
            receipt = standard(MotionProfile(cadence: 166, cadenceJitter: 0.05, speed: 3.2, activity: .running, stride: 1.15))
        case .killedAndRecovered:
            let live = session(walk, count: 8)
            var dead = walk
            dead.live = false
            let recovered = SyntheticData.epochs(start: live.end, count: 12, profile: dead, startIndex: 8,
                                                 config: config, seed: 9)
            let flags = [Flag(code: .appRelaunched, severity: .info, detail: "userLaunch after 720s gap")]
            receipt = submit(SyntheticData.report(epochs: live.epochs + recovered, start: live.start,
                                                  end: recovered.last!.end, origin: origin, clientFlags: flags))
        case .treadmillIndoor:
            var p = walk
            p.gps = false
            receipt = standard(p)
        case .carRide:
            receipt = standard(MotionProfile(cadence: 4, cadenceJitter: 0.5, speed: 13, activity: .automotive))
        case .shakingPhoneInCar:
            receipt = standard(MotionProfile(cadence: 110, cadenceJitter: 0.05, speed: 12, activity: .automotive))
        case .bikeRide:
            receipt = standard(MotionProfile(cadence: 40, cadenceJitter: 0.2, speed: 5.5, activity: .cycling))
        case .phoneShaker:
            receipt = standard(MotionProfile(cadence: 120, cadenceJitter: 0, speed: 0, activity: .walking,
                                             gpsStationary: true, rhythmCV: 0.004))
        case .handShakeInPlace:
            receipt = standard(MotionProfile(cadence: 100, cadenceJitter: 0.1, speed: 0, activity: .walking,
                                             gpsStationary: true, rhythmCV: 0.08))
        case .gpsSpoof:
            var p = walk
            p.simulatedGPS = true
            receipt = standard(p)
        case .teleport:
            receipt = standard(walk, teleportAt: 10)
        case .cadenceTooHigh:
            receipt = standard(MotionProfile(cadence: 400, cadenceJitter: 0.02, speed: 1.4, activity: .walking, stride: 0.2))
        case .clockTamperDuring:
            let s = session(walk)
            let flags = [Flag(code: .clockTampered, severity: .reject, detail: "wall clock drift 3600s")]
            receipt = submit(SyntheticData.report(epochs: s.epochs, start: s.start, end: s.end, origin: origin,
                                                  endMonoSkew: -3600, clientFlags: flags))
        case .clockOffsetBeforeStart:
            // Device clock set back 1 day before starting: internally consistent, only the server can tell.
            let s = session(walk)
            receipt = submit(SyntheticData.report(epochs: s.epochs, start: s.start, end: s.end, origin: origin,
                                                  clockOffset: -86_400), sentOffset: -86_400)
        case .jailbroken:
            var integrity = SyntheticData.cleanIntegrity
            integrity.isJailbroken = true
            integrity.jailbreakSignals = ["/var/jb"]
            receipt = standard(walk, integrity: integrity)
        case .tamperedPayload:
            let s = session(walk)
            receipt = submit(SyntheticData.report(epochs: s.epochs, start: s.start, end: s.end, origin: origin)) { signed in
                guard var r = try? FileStore.decoder.decode(SessionReport.self, from: signed.payload) else { return }
                for i in r.epochs.indices { r.epochs[i].steps *= 5 }
                signed.payload = (try? FileStore.encoder.encode(r)) ?? signed.payload
                signed.payloadHash = HashChain.sha256Hex(signed.payload)
            }
        case .replay:
            let s = session(walk)
            let report = SyntheticData.report(epochs: s.epochs, start: s.start, end: s.end, origin: origin)
            let first = submit(report)
            let second = submit(report)
            receipt = second
            note = String(format: "lần 1: %.3f coin, lần 2: %@, số dư %.3f", first.coins, second.status.rawValue,
                          server.currentBalance)
            let ok = second.status == .duplicate && server.currentBalance == first.coins && first.coins > 0
            return ScenarioResult(scenario: scenario, receipt: receipt, passed: ok, note: note)
        case .overlappingSession:
            let a = session(walk, seed: 7)
            let first = submit(SyntheticData.report(epochs: a.epochs, start: a.start, end: a.end, origin: origin))
            let b = session(walk, seed: 8)
            receipt = submit(SyntheticData.report(epochs: b.epochs, start: b.start, end: b.end, origin: origin))
            note = String(format: "session A: %.3f coin", first.coins)
        case .tooShort:
            receipt = standard(walk, count: 1)
        }
        let passed = Self.check(receipt, scenario.expectation)
        if note.isEmpty {
            note = receipt.reason ?? String(format: "%.3f coin · %d/%d epoch hợp lệ", receipt.coins,
                                            receipt.breakdown.validEpochs, receipt.verification.verdicts.count)
        }
        return ScenarioResult(scenario: scenario, receipt: receipt, passed: passed, note: note)
    }

    static func check(_ r: RewardReceipt, _ expectation: Scenario.Expectation) -> Bool {
        let codes = Set(r.allFlags.map(\.code))
        switch expectation {
        case .credited:
            return r.status == .credited && r.coins > 0 && !r.allFlags.contains { $0.severity == .reject }
        case .creditedWith(let code):
            return r.status == .credited && r.coins > 0 && codes.contains(code)
        case .rejected(let code):
            return r.status == .rejected && r.coins == 0 && codes.contains(code)
        case .zeroCoins(let code):
            return r.coins == 0 && codes.contains(code)
        case .duplicate:
            return r.status == .duplicate
        case .capped(let code):
            return r.status == .credited && codes.contains(code) && r.coins > 0 && r.coins < r.breakdown.grossCoins
        }
    }
}
