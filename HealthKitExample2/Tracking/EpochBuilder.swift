//
//  EpochBuilder.swift
//  HealthKitExample2
//
//  Turns raw sensor data for a time window into an `Epoch`. Pure / deterministic
//  so the server can rebuild the same numbers and tests can feed synthetic data.
//

import Foundation

nonisolated enum EpochBuilder {
    struct GPSStats: Equatable {
        var count = 0
        var distance = 0.0
        var displacement = 0.0
        var avgAccuracy: Double?
        var maxSpeed = 0.0
        var avgSpeed: Double?
        var simulated = 0
        var teleports = 0
    }

    static func build(index: Int, start: Date, end: Date,
                      pedometer: PedometerSample?, activities: [ActivityPoint],
                      locations: [LocationPoint], previousLocation: LocationPoint?,
                      motion: MotionFeatures?, aliveFraction: Double, phase: AppPhase,
                      tracking: TrackingConfig, rules: VerificationRules) -> Epoch {
        let gps = gpsStats(locations, previous: previousLocation, start: start, end: end,
                           maxAccuracy: tracking.gpsMaxAccuracy, rules: rules)
        let fractions = activityFractions(activities, start: start, end: end)
        let dominant = fractions.max { $0.value < $1.value }.flatMap { ActivityKind(rawValue: $0.key) } ?? .unknown
        let live = aliveFraction >= 0.5
        return Epoch(index: index, start: start, end: end,
                     source: live ? .live : .recovered,
                     phase: live ? phase : .notRunning,
                     aliveFraction: aliveFraction,
                     steps: pedometer?.steps ?? 0,
                     pedometerDistance: pedometer?.distance,
                     floorsAscended: pedometer?.floorsAscended,
                     gpsPoints: gps.count, gpsDistance: gps.distance, gpsDisplacement: gps.displacement,
                     gpsAvgAccuracy: gps.avgAccuracy, gpsMaxSpeed: gps.maxSpeed, gpsAvgSpeed: gps.avgSpeed,
                     simulatedPoints: gps.simulated, teleports: gps.teleports,
                     activity: fractions, dominantActivity: dominant,
                     motion: live ? motion : nil)
    }

    // MARK: Activity

    /// Each CMMotionActivity sample is in effect until the next one.
    static func activityFractions(_ points: [ActivityPoint], start: Date, end: Date) -> [String: Double] {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return [:] }
        let sorted = points.sorted { $0.t < $1.t }
        var seconds: [String: Double] = [:]
        // portion before the first known activity is unknown
        let effective = sorted.lastIndex { $0.t <= start }.map { Array(sorted[$0...]) } ?? sorted
        if let first = effective.first, first.t > start {
            seconds[ActivityKind.unknown.rawValue, default: 0] += min(first.t, end).timeIntervalSince(start)
        }
        for (i, p) in effective.enumerated() {
            let segStart = max(p.t, start)
            let segEnd = i + 1 < effective.count ? min(effective[i + 1].t, end) : end
            guard segEnd > segStart, segStart < end else { continue }
            let kind = p.confidence >= 1 ? p.kind : .unknown
            seconds[kind.rawValue, default: 0] += segEnd.timeIntervalSince(segStart)
        }
        if effective.isEmpty { seconds[ActivityKind.unknown.rawValue] = total }
        return seconds.mapValues { min(1, $0 / total) }
    }

    // MARK: GPS

    static func gpsStats(_ points: [LocationPoint], previous: LocationPoint?, start: Date, end: Date,
                         maxAccuracy: Double, rules: VerificationRules) -> GPSStats {
        let inWindow = points.filter { $0.t >= start && $0.t < end }.sorted { $0.t < $1.t }
        var stats = GPSStats()
        stats.simulated = inWindow.filter(\.simulated).count
        let accepted = inWindow.filter { $0.hAcc >= 0 && $0.hAcc <= maxAccuracy }
        stats.count = accepted.count
        guard !accepted.isEmpty else { return stats }

        stats.avgAccuracy = accepted.map(\.hAcc).reduce(0, +) / Double(accepted.count)
        stats.maxSpeed = accepted.filter { $0.speed >= 0 && $0.speedAcc >= 0 && $0.speedAcc <= 5 }
            .map(\.speed).max() ?? 0

        var chain = accepted
        if let previous, previous.hAcc >= 0, previous.hAcc <= maxAccuracy, previous.t < accepted[0].t,
           accepted[0].t.timeIntervalSince(previous.t) < 120 {
            chain.insert(previous, at: 0)
        }
        // Jitter-robust path length: only advance once we are clearly away from the
        // last anchor (≥ accuracy), so a phone lying still does not "walk".
        var anchor = chain[0]
        for (a, b) in zip(chain, chain.dropFirst()) {
            let d = haversine(a.lat, a.lon, b.lat, b.lon)
            let dt = b.t.timeIntervalSince(a.t)
            if d >= rules.teleportMinDistance, d / max(dt, 0.001) > rules.teleportSpeedMps {
                stats.teleports += 1
                anchor = b
                continue
            }
            let fromAnchor = haversine(anchor.lat, anchor.lon, b.lat, b.lon)
            if fromAnchor >= max(5, min(b.hAcc, 20)) {
                stats.distance += fromAnchor
                anchor = b
            }
        }
        if let first = accepted.first, let last = accepted.last {
            stats.displacement = haversine(first.lat, first.lon, last.lat, last.lon)
            let span = last.t.timeIntervalSince(chain[0].t)
            if span >= 10 { stats.avgSpeed = stats.distance / span }
        }
        return stats
    }

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    // MARK: Liveness

    static func aliveFraction(_ intervals: [DateInterval], start: Date, end: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let window = DateInterval(start: start, end: end)
        let covered = intervals.compactMap { $0.intersection(with: window)?.duration }.reduce(0, +)
        return min(1, covered / total)
    }

    /// Extends the last interval when the gap since it is small, otherwise opens a new one.
    static func recordAlive(_ intervals: inout [DateInterval], at t: Date, maxGap: TimeInterval) {
        if let last = intervals.last, t >= last.end, t.timeIntervalSince(last.end) <= maxGap {
            intervals[intervals.count - 1] = DateInterval(start: last.start, end: t)
        } else if let last = intervals.last, t < last.end {
            return
        } else {
            intervals.append(DateInterval(start: t, duration: 0))
        }
    }
}
