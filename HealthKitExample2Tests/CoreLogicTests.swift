import CryptoKit
import Foundation
import Testing
@testable import HealthKitExample2

struct EpochBuilderTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func activityFractionsUseSampleInEffectAtWindowStart() {
        let points = [ActivityPoint(t: start.addingTimeInterval(-100), kind: .walking, confidence: 2),
                      ActivityPoint(t: start.addingTimeInterval(30), kind: .automotive, confidence: 2)]
        let f = EpochBuilder.activityFractions(points, start: start, end: start.addingTimeInterval(60))
        #expect(abs((f["walking"] ?? 0) - 0.5) < 0.001)
        #expect(abs((f["automotive"] ?? 0) - 0.5) < 0.001)
    }

    @Test func lowConfidenceCountsAsUnknown() {
        let points = [ActivityPoint(t: start, kind: .automotive, confidence: 0)]
        let f = EpochBuilder.activityFractions(points, start: start, end: start.addingTimeInterval(60))
        #expect(f["automotive"] == nil)
        #expect(f["unknown"] == 1)
    }

    @Test func stationaryGpsJitterDoesNotAccumulateDistance() {
        var rng = SeededRandom(seed: 3)
        let points = (0..<60).map { i in
            LocationPoint(t: start.addingTimeInterval(Double(i)), lat: 10.0 + rng.range(-1...1) * 0.00002,
                          lon: 106.0 + rng.range(-1...1) * 0.00002, alt: 0, hAcc: 8, vAcc: 5, speed: 0,
                          speedAcc: 0.5, course: 0, simulated: false, accessory: false)
        }
        let stats = EpochBuilder.gpsStats(points, previous: nil, start: start, end: start.addingTimeInterval(60),
                                          maxAccuracy: 50, rules: VerificationRules())
        #expect(stats.count == 60)
        #expect(stats.distance < 10)
    }

    @Test func detectsTeleportAndInaccurateFixes() {
        var points = (0..<10).map { i in
            LocationPoint(t: start.addingTimeInterval(Double(i) * 2), lat: 10 + Double(i) * 0.00002, lon: 106, alt: 0,
                          hAcc: 8, vAcc: 5, speed: 1.4, speedAcc: 0.5, course: 0, simulated: false, accessory: false)
        }
        points[5].lat += 0.05  // ~5.5km jump in 2s
        points.append(LocationPoint(t: start.addingTimeInterval(25), lat: 0, lon: 0, alt: 0, hAcc: 500, vAcc: 5,
                                    speed: 1, speedAcc: 0.5, course: 0, simulated: false, accessory: false))
        let stats = EpochBuilder.gpsStats(points, previous: nil, start: start, end: start.addingTimeInterval(60),
                                          maxAccuracy: 50, rules: VerificationRules())
        #expect(stats.teleports >= 1)
        #expect(stats.count == 10)
    }

    @Test func aliveFractionAndRecordAlive() {
        var intervals: [DateInterval] = []
        for i in 0...6 { EpochBuilder.recordAlive(&intervals, at: start.addingTimeInterval(Double(i) * 5), maxGap: 15) }
        // gap (app suspended) then alive again
        EpochBuilder.recordAlive(&intervals, at: start.addingTimeInterval(120), maxGap: 15)
        #expect(intervals.count == 2)
        #expect(abs(EpochBuilder.aliveFraction(intervals, start: start, end: start.addingTimeInterval(60)) - 0.5) < 0.01)
        #expect(EpochBuilder.aliveFraction(intervals, start: start.addingTimeInterval(60), end: start.addingTimeInterval(110)) == 0)
    }
}

struct AccelerometerTests {
    func signal(stepInterval: Double, jitter: Double, seconds: Double = 60, hz: Double = 25, seed: UInt64 = 1) -> [(t: Double, magnitude: Double)] {
        var rng = SeededRandom(seed: seed)
        var beats: [Double] = []
        var t = 0.3
        while t < seconds { beats.append(t); t += stepInterval * (1 + jitter * rng.range(-1...1)) }
        return stride(from: 0.0, to: seconds, by: 1 / hz).map { time in
            let nearest = beats.min { abs($0 - time) < abs($1 - time) } ?? 0
            let d = time - nearest
            return (time, 1 + 0.6 * exp(-d * d / (2 * 0.06 * 0.06)) + rng.range(-0.01...0.01))
        }
    }

    @Test func machineRhythmHasVeryLowCV() throws {
        let f = try #require(AccelerometerAnalyzer.analyze(signal(stepInterval: 0.5, jitter: 0)))
        #expect(f.peakCount > 100)
        #expect(try #require(f.peakIntervalCV) < VerificationRules().roboticRhythmCV)
    }

    @Test func humanRhythmIsNotRobotic() throws {
        let f = try #require(AccelerometerAnalyzer.analyze(signal(stepInterval: 0.55, jitter: 0.08)))
        #expect(try #require(f.peakIntervalCV) > VerificationRules().roboticRhythmCV)
    }

    @Test func stillPhoneHasNoPeaks() throws {
        let still = (0..<1500).map { (Double($0) / 25, 1.0) }
        let f = try #require(AccelerometerAnalyzer.analyze(still))
        #expect(f.peakCount == 0)
    }
}

struct SecurityTests {
    @Test func hashChainDetectsEditsDeletionsAndReordering() {
        var entries: [LogEntry] = []
        for i in 1...5 {
            entries.append(HashChain.make(seq: i, t: Date(timeIntervalSince1970: Double(i)), monoNanos: UInt64(i),
                                          type: "e\(i)", level: .info, sessionId: nil, data: ["k": "\(i)"],
                                          prevHash: entries.last?.hash ?? HashChain.genesis))
        }
        #expect(HashChain.firstBreak(in: entries) == nil)

        var edited = entries
        edited[2].data["k"] = "999"
        #expect(HashChain.firstBreak(in: edited) == 3)

        var deleted = entries
        deleted.remove(at: 2)
        #expect(HashChain.firstBreak(in: deleted) == 4)

        #expect(HashChain.firstBreak(in: [entries[0], entries[2], entries[1]]) != nil)
    }

    @Test func eventLoggerPersistsChainAcrossRelaunch() {
        let store = FileStore.temporary()
        let a = EventLogger(store: store)
        a.log("one")
        a.log("two", ["x": "1"])
        let b = EventLogger(store: store)  // "relaunch"
        b.log("three")
        #expect(b.chainIntact)
        #expect(b.verifyAll() == nil)
        #expect(b.allEntries().map(\.seq) == [1, 2, 3])
    }

    @Test func eventLoggerDetectsTruncatedFile() throws {
        let store = FileStore.temporary()
        let a = EventLogger(store: store)
        a.log("one")
        a.log("two")
        let file = try #require(store.list().first { $0.hasPrefix("events-") })
        let lines = String(decoding: try #require(store.read(file)), as: UTF8.self).split(separator: "\n")
        try store.write(Data((lines.first! + "\n").utf8), to: file)  // attacker drops last line
        let b = EventLogger(store: store)
        #expect(!b.chainIntact)
    }

    @Test func signatureRejectsModifiedPayloadAndWrongKey() throws {
        let key = SymmetricKey(size: .bits256)
        let signed = ReportSigner.sign(payload: Data("hello".utf8), key: key, keyId: "k")
        #expect(ReportSigner.isValid(signed, key: key))
        var tampered = signed
        tampered.payload = Data("hellO".utf8)
        #expect(!ReportSigner.isValid(tampered, key: key))
        #expect(!ReportSigner.isValid(signed, key: SymmetricKey(size: .bits256)))
    }

    @Test func clockGuard() {
        let a = ClockAnchor(wall: Date(timeIntervalSince1970: 1000), monoNanos: 1_000_000_000_000, bootId: "b")
        var b = ClockAnchor(wall: Date(timeIntervalSince1970: 1060), monoNanos: 1_060_000_000_000, bootId: "b")
        #expect(ClockGuard.compare(from: a, to: b, tolerance: 30) == .ok)
        b.wall = b.wall.addingTimeInterval(3600)
        #expect(ClockGuard.compare(from: a, to: b, tolerance: 30) == .wallShifted(3600))
        b.bootId = "other"
        #expect(ClockGuard.compare(from: a, to: b, tolerance: 30) == .rebooted)
        #expect(ClockGuard.monotonicNanos() > 0)
        #expect(!ClockGuard.bootId.isEmpty)
    }
}

struct RewardTests {
    @Test func dailyStepCapLimitsRewardedSteps() {
        var config = RewardConfig.default
        config.limits.dailyStepCap = 500
        let epochs = SyntheticData.epochs(start: Date(), count: 10,
                                          profile: MotionProfile(cadence: 100, cadenceJitter: 0.05, speed: 1.3, activity: .walking))
        let input = VerificationInput(epochs: epochs, startedAt: epochs[0].start, endedAt: epochs.last!.end,
                                      startAnchor: SyntheticData.anchor(epochs[0].start, origin: epochs[0].start),
                                      endAnchor: SyntheticData.anchor(epochs.last!.end, origin: epochs[0].start),
                                      integrity: SyntheticData.cleanIntegrity, clientFlags: [], healthKit: nil)
        let result = ActivityVerifier.verify(input, config: config)
        let b = RewardCalculator.calculate(epochs: epochs, result: result, config: config, todaySteps: 200)
        #expect(b.rewardedSteps == 300)
        #expect(b.cappedBy.contains(.dailyStepCap))
    }

    @Test func roundingNeverOverpays() {
        #expect(RewardCalculator.round(1.23999, 3) == 1.239)
    }

    @Test func configRoundTripsAndBumpsVersion() throws {
        let store = ConfigStore(store: .temporary())
        var c = store.config
        c.reward.coinsPerVerifiedKm = 9
        store.update(c)
        #expect(store.config.version == 2)
        let json = store.exportJSON()
        let other = ConfigStore(store: .temporary())
        try other.importJSON(json)
        #expect(other.config.reward.coinsPerVerifiedKm == 9)
    }
}

struct ReplaySensorTests {
    @Test func replayHistoryIsAdditiveAndHumanLike() async throws {
        let p = ReplayPedometer(cadence: 108)
        let t0 = Date().addingTimeInterval(-3600)
        let whole = p.steps(from: t0, to: t0.addingTimeInterval(600))
        let parts = (0..<10).map { p.steps(from: t0.addingTimeInterval(Double($0) * 60), to: t0.addingTimeInterval(Double($0 + 1) * 60)) }
        #expect(parts.reduce(0, +) == whole)
        #expect(abs(Double(whole) - 1080) < 30)
        let mean = Double(whole) / 10
        let sd = (parts.map { pow(Double($0) - mean, 2) }.reduce(0, +) / 10).squareRoot()
        #expect(sd / mean > VerificationRules().roboticSessionCadenceCV)
    }

    @Test func replayReportsAreFlagged() {
        var config = RewardConfig.default
        let epochs = SyntheticData.epochs(start: Date().addingTimeInterval(-900), count: 5,
                                          profile: MotionProfile(cadence: 108, cadenceJitter: 0.05, speed: 1.3, activity: .walking))
        var report = SyntheticData.report(epochs: epochs, start: epochs[0].start, end: epochs.last!.end, origin: epochs[0].start)
        report.sensorSource = "replay"
        #expect(ActivityVerifier.verify(VerificationInput(report: report), config: config).sessionRejected)
        config.rules.rejectReplaySensors = false
        #expect(!ActivityVerifier.verify(VerificationInput(report: report), config: config).sessionRejected)
    }
}
