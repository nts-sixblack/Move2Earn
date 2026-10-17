//
//  ClockGuard.swift
//  HealthKitExample2
//
//  Detects manual wall-clock changes (e.g. setting the date forward to farm a
//  new daily cap, or backwards to replay a time range) by comparing it against
//  the monotonic clock, which keeps running during sleep and cannot be edited.
//

import Darwin
import Foundation

nonisolated enum ClockCheck: Equatable, Sendable {
    case ok
    case rebooted
    /// Wall clock moved this many seconds more (+) or less (−) than real time.
    case wallShifted(Double)
}

nonisolated enum ClockGuard {
    /// CLOCK_MONOTONIC on Darwin is mach_continuous_time: it includes sleep.
    static func monotonicNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

    static let bootId: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return bootTimeFallback()
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return bootTimeFallback() }
        return String(cString: buffer)
    }()

    static func anchor(now: Date = Date()) -> ClockAnchor {
        ClockAnchor(wall: now, monoNanos: monotonicNanos(), bootId: bootId)
    }

    static func compare(from old: ClockAnchor, to new: ClockAnchor, tolerance: Double) -> ClockCheck {
        guard old.bootId == new.bootId, new.monoNanos >= old.monoNanos else { return .rebooted }
        let monoDelta = Double(new.monoNanos - old.monoNanos) / 1_000_000_000
        let wallDelta = new.wall.timeIntervalSince(old.wall)
        let drift = wallDelta - monoDelta
        return abs(drift) > tolerance ? .wallShifted(drift) : .ok
    }

    private static func bootTimeFallback() -> String {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        sysctl(&mib, 2, &tv, &size, nil, 0)
        return "boot-\(tv.tv_sec)"
    }
}
