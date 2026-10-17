//
//  ReplaySensors.swift
//  HealthKitExample2
//
//  DEBUG-only sensor source for devices without a motion coprocessor (the
//  Simulator). Like CMPedometer, its step history is a pure function of wall
//  time, so it "keeps counting" while the app is suspended or killed and the
//  recovery path can be exercised end to end. Reports produced with it carry
//  `sensorSource = "replay"` and are flagged by the verifier.
//

import Foundation

nonisolated enum SensorMode {
    static let replayKey = "m2e.debug.replaySensors"
    static let cadenceKey = "m2e.debug.replayCadence"

    static var replayEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: replayKey)
        #else
        false
        #endif
    }

    static var replayCadence: Double {
        let v = UserDefaults.standard.double(forKey: cadenceKey)
        return v > 0 ? v : 108
    }
}

#if DEBUG
nonisolated final class ReplayPedometer: StepCounting, @unchecked Sendable {
    private let cadence: Double
    private var timer: DispatchSourceTimer?

    init(cadence: Double = SensorMode.replayCadence) { self.cadence = cadence }

    var isAvailable: Bool { true }

    /// Cumulative steps since 1970 with a ±6% cadence drift over 5 minutes
    /// (humans are not metronomes). floor(F(b)) − floor(F(a)) is additive, so
    /// adjacent epochs never double count.
    func cumulative(_ t: Date) -> Double {
        let s = t.timeIntervalSince1970
        let omega = 2 * Double.pi / 300
        return cadence / 60 * s - (cadence * 0.06 / 60) * cos(omega * s) / omega
    }

    func steps(from: Date, to: Date) -> Int {
        guard to > from else { return 0 }
        return Int(cumulative(to).rounded(.down) - cumulative(from).rounded(.down))
    }

    func query(from: Date, to: Date) async throws -> PedometerSample {
        let n = steps(from: from, to: min(to, Date()))
        return PedometerSample(start: from, end: to, steps: n, distance: Double(n) * 0.75, floorsAscended: 0)
    }

    func startLive(from: Date, handler: @escaping @Sendable (PedometerSample) -> Void) {
        stopLive()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            let n = self.steps(from: from, to: now)
            handler(PedometerSample(start: from, end: now, steps: n, distance: Double(n) * 0.75, floorsAscended: 0))
        }
        t.resume()
        timer = t
    }

    func stopLive() {
        timer?.cancel()
        timer = nil
    }
}

nonisolated final class ReplayActivity: ActivitySensing, @unchecked Sendable {
    var isAvailable: Bool { true }
    func query(from: Date, to: Date) async throws -> [ActivityPoint] {
        [ActivityPoint(t: from, kind: .walking, confidence: 2)]
    }
    func startLive(handler: @escaping @Sendable (ActivityPoint) -> Void) {
        handler(ActivityPoint(t: Date(), kind: .walking, confidence: 2))
    }
    func stopLive() {}
}
#endif
