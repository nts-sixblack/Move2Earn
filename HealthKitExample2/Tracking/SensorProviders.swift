//
//  SensorProviders.swift
//  HealthKitExample2
//
//  Sensor abstractions. SessionManager only talks to these protocols, so unit
//  tests (and the Scenario Lab) can inject fakes for kill/recovery scenarios.
//
//  Source of truth for steps is CMPedometer (M-series coprocessor). It keeps
//  ~7 days of history even while the app is suspended or killed, and — unlike
//  HealthKit — third-party apps cannot write into it.
//

import CoreMotion
import Foundation

nonisolated protocol StepCounting: AnyObject {
    var isAvailable: Bool { get }
    func query(from: Date, to: Date) async throws -> PedometerSample
    func startLive(from: Date, handler: @escaping @Sendable (PedometerSample) -> Void)
    func stopLive()
}

nonisolated protocol ActivitySensing: AnyObject {
    var isAvailable: Bool { get }
    func query(from: Date, to: Date) async throws -> [ActivityPoint]
    func startLive(handler: @escaping @Sendable (ActivityPoint) -> Void)
    func stopLive()
}

nonisolated protocol MotionAnalyzing: AnyObject {
    func start(hz: Double)
    func stop()
    func features(from: Date, to: Date) -> MotionFeatures?
}

// MARK: - CMPedometer

nonisolated final class CorePedometer: StepCounting, @unchecked Sendable {
    private let pedometer = CMPedometer()

    var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }

    static var authorizationStatus: CMAuthorizationStatus { CMPedometer.authorizationStatus() }

    func query(from: Date, to: Date) async throws -> PedometerSample {
        guard isAvailable, to > from else {
            return PedometerSample(start: from, end: to, steps: 0, distance: nil, floorsAscended: nil)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pedometer.queryPedometerData(from: from, to: to) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: PedometerSample(
                    start: from, end: to,
                    steps: data?.numberOfSteps.intValue ?? 0,
                    distance: data?.distance?.doubleValue,
                    floorsAscended: data?.floorsAscended?.intValue))
            }
        }
    }

    func startLive(from: Date, handler: @escaping @Sendable (PedometerSample) -> Void) {
        guard isAvailable else { return }
        pedometer.startUpdates(from: from) { data, _ in
            guard let data else { return }
            handler(PedometerSample(start: data.startDate, end: data.endDate, steps: data.numberOfSteps.intValue,
                                    distance: data.distance?.doubleValue,
                                    floorsAscended: data.floorsAscended?.intValue))
        }
    }

    func stopLive() { pedometer.stopUpdates() }
}

// MARK: - CMMotionActivityManager

nonisolated final class CoreActivity: ActivitySensing, @unchecked Sendable {
    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "m2e.activity"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    func query(from: Date, to: Date) async throws -> [ActivityPoint] {
        guard isAvailable, to > from else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            manager.queryActivityStarting(from: from, to: to, to: queue) { activities, error in
                if let error {
                    // CMErrorMotionActivityNotAvailable etc. → treat as "no data"
                    if (error as NSError).domain == CMErrorDomain {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: (activities ?? []).map(Self.point))
            }
        }
    }

    func startLive(handler: @escaping @Sendable (ActivityPoint) -> Void) {
        guard isAvailable else { return }
        manager.startActivityUpdates(to: queue) { activity in
            guard let activity else { return }
            handler(Self.point(activity))
        }
    }

    func stopLive() { manager.stopActivityUpdates() }

    /// Several flags can be true at once (e.g. automotive + stationary at a red
    /// light); the most "cheat relevant" one wins.
    static func point(_ a: CMMotionActivity) -> ActivityPoint {
        let kind: ActivityKind
        if a.automotive { kind = .automotive }
        else if a.cycling { kind = .cycling }
        else if a.running { kind = .running }
        else if a.walking { kind = .walking }
        else if a.stationary { kind = .stationary }
        else { kind = .unknown }
        return ActivityPoint(t: a.startDate, kind: kind, confidence: a.confidence.rawValue)
    }
}

// MARK: - Accelerometer rhythm analysis

nonisolated final class AccelerometerAnalyzer: MotionAnalyzing, @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "m2e.accelerometer"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private let lock = NSLock()
    private var samples: [(t: Date, magnitude: Double)] = []

    func start(hz: Double) {
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = 1 / max(hz, 1)
        // Sensor timestamps are seconds since boot (uptime); convert once to wall time.
        let bootDate = Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            let a = data.acceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            self.lock.lock()
            self.samples.append((bootDate.addingTimeInterval(data.timestamp), magnitude))
            // keep at most ~5 minutes in memory
            if self.samples.count > 25 * 300 { self.samples.removeFirst(self.samples.count - 25 * 300) }
            self.lock.unlock()
        }
    }

    func stop() {
        manager.stopAccelerometerUpdates()
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    func features(from: Date, to: Date) -> MotionFeatures? {
        lock.lock()
        let window = samples.filter { $0.t >= from && $0.t < to }
        samples.removeAll { $0.t < to }
        lock.unlock()
        return Self.analyze(window.map { ($0.t.timeIntervalSince1970, $0.magnitude) })
    }

    /// Pure function so it can be unit tested with synthetic signals.
    static func analyze(_ window: [(t: Double, magnitude: Double)]) -> MotionFeatures? {
        guard window.count >= 20 else { return nil }
        let values = window.map(\.magnitude)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let std = variance.squareRoot()
        guard std > 0.02 else {
            return MotionFeatures(sampleCount: window.count, peakCount: 0, magnitudeStd: std, peakIntervalCV: nil)
        }
        // Peak detection: local maxima above mean + 0.5σ, ≥ 0.25s apart (max 240 spm).
        let threshold = mean + 0.5 * std
        var peaks: [Double] = []
        for i in 1..<(window.count - 1) {
            let (y0, y1, y2) = (window[i - 1].magnitude, window[i].magnitude, window[i + 1].magnitude)
            guard y1 > threshold, y1 >= y0, y1 > y2 else { continue }
            // Parabolic interpolation of the peak time removes most of the sampling
            // quantisation error (40ms at 25Hz), which would otherwise mask a machine.
            let denom = y0 - 2 * y1 + y2
            let dt = (window[i + 1].t - window[i - 1].t) / 2
            let offset = denom != 0 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / denom)) * dt : 0
            let t = window[i].t + offset
            if let last = peaks.last, t - last < 0.25 { continue }
            peaks.append(t)
        }
        var cv: Double?
        if peaks.count >= 4 {
            let intervals = zip(peaks.dropFirst(), peaks).map { $0 - $1 }
            let m = intervals.reduce(0, +) / Double(intervals.count)
            let sd = (intervals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(intervals.count)).squareRoot()
            cv = m > 0 ? sd / m : nil
        }
        return MotionFeatures(sampleCount: window.count, peakCount: peaks.count, magnitudeStd: std, peakIntervalCV: cv)
    }
}
