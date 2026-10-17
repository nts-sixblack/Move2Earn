//
//  ActivityVerifier.swift
//  HealthKitExample2
//
//  Anti-cheat rules. Runs on the client (live estimate) and again on the
//  server from the raw epochs — the server never trusts client verdicts.
//
//  Cheats covered:
//   • Riding a car / bus / motorbike     → GPS avg speed, CoreMotion automotive, stride vs GPS
//   • Cycling                            → CoreMotion cycling, stride vs GPS
//   • GPS spoofing / joystick apps       → isSimulatedBySoftware, teleport jumps, speed spikes
//   • Phone shaker / pendulum / fan      → robotic rhythm (accelerometer CV, cadence CV), steps w/o displacement
//   • Shaking phone by hand              → steps while CoreMotion says stationary, stride, cadence
//   • Fake HealthKit entries             → pedometer is the source; HK manual/3rd-party flagged
//   • Changing system clock              → wall vs monotonic clock anchors, clock-change events
//   • Replaying / editing reports        → HMAC signature, hash-chained logs, nonce (server)
//   • Jailbreak / hooking (Frida, etc.)  → integrity snapshot
//   • Killing the app to hide data      → back-filled epochs marked recovered, lower multiplier
//

import Foundation

nonisolated struct EpochVerdict: Codable, Hashable, Identifiable, Sendable {
    var index: Int
    var valid: Bool
    var trust: Double
    var rewardSteps: Int
    var verifiedDistance: Double
    var activity: ActivityKind
    var multiplier: Double
    var flags: [Flag]
    var id: Int { index }
}

nonisolated struct VerificationResult: Codable, Hashable, Sendable {
    var verdicts: [EpochVerdict]
    var sessionFlags: [Flag]
    var sessionRejected: Bool

    var validEpochs: Int { verdicts.filter(\.valid).count }
    var allFlags: [Flag] { sessionFlags + verdicts.flatMap(\.flags) }
}

nonisolated struct VerificationInput: Sendable {
    var epochs: [Epoch]
    var startedAt: Date
    var endedAt: Date
    var startAnchor: ClockAnchor
    var endAnchor: ClockAnchor
    var integrity: IntegritySnapshot
    var clientFlags: [Flag]
    var healthKit: HealthKitSummary?
    var sensorSource: String?

    init(report: SessionReport) {
        sensorSource = report.sensorSource
        epochs = report.epochs
        startedAt = report.startedAt
        endedAt = report.endedAt
        startAnchor = report.startAnchor
        endAnchor = report.endAnchor
        integrity = report.integrity
        clientFlags = report.clientFlags
        healthKit = report.healthKit
    }

    init(epochs: [Epoch], startedAt: Date, endedAt: Date, startAnchor: ClockAnchor, endAnchor: ClockAnchor,
         integrity: IntegritySnapshot, clientFlags: [Flag], healthKit: HealthKitSummary?) {
        self.epochs = epochs
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startAnchor = startAnchor
        self.endAnchor = endAnchor
        self.integrity = integrity
        self.clientFlags = clientFlags
        self.healthKit = healthKit
    }
}

nonisolated enum ActivityVerifier {

    // MARK: Session

    static func verify(_ input: VerificationInput, config: RewardConfig, requireMinDuration: Bool = true) -> VerificationResult {
        let rules = config.rules
        var sessionFlags: [Flag] = []

        // Device integrity
        let i = input.integrity
        if i.isJailbroken {
            sessionFlags.append(Flag(code: .jailbroken, severity: rules.rejectJailbreak ? .reject : .warning,
                                     detail: i.jailbreakSignals.joined(separator: ",")))
        }
        if !i.suspiciousLibraries.isEmpty {
            sessionFlags.append(Flag(code: .hookingLibrary, severity: rules.rejectHookingLibraries ? .reject : .warning,
                                     detail: i.suspiciousLibraries.joined(separator: ",")))
        }
        if i.debuggerAttached {
            sessionFlags.append(Flag(code: .debuggerAttached, severity: rules.rejectDebugger ? .reject : .info, detail: "P_TRACED"))
        }
        if i.isSimulator {
            sessionFlags.append(Flag(code: .simulatorDevice, severity: rules.rejectSimulator ? .reject : .info, detail: "simulator"))
        }

        if input.sensorSource == "replay" {
            sessionFlags.append(Flag(code: .replaySensors, severity: rules.rejectReplaySensors ? .reject : .info,
                                     detail: "debug replay sensors"))
        }

        // Observations recorded by the client while tracking (clock changes, reboots, relaunches…)
        for flag in input.clientFlags {
            var f = flag
            if [.clockTampered, .clockMovedBackwards].contains(f.code) {
                f.severity = rules.rejectOnClockTamper ? .reject : .warning
            }
            sessionFlags.append(f)
        }

        // Wall clock vs monotonic clock between start and end
        switch ClockGuard.compare(from: input.startAnchor, to: input.endAnchor, tolerance: rules.clockToleranceSeconds) {
        case .ok: break
        case .rebooted:
            sessionFlags.append(Flag(code: .deviceRebooted, severity: .info, detail: "boot session changed"))
        case .wallShifted(let drift):
            sessionFlags.append(Flag(code: .clockTampered, severity: rules.rejectOnClockTamper ? .reject : .warning,
                                     detail: String(format: "wall clock drift %.0fs", drift)))
        }

        let duration = input.endedAt.timeIntervalSince(input.startedAt)
        if requireMinDuration, duration < config.limits.sessionMinSeconds {
            sessionFlags.append(Flag(code: .sessionTooShort, severity: .reject,
                                     detail: String(format: "%.0fs < %.0fs", duration, config.limits.sessionMinSeconds)))
        }

        // Epoch structure: ordered, contiguous, inside the session
        let epochs = input.epochs.sorted { $0.index < $1.index }
        var structural: [Int: [Flag]] = [:]
        for (prev, e) in zip(epochs, epochs.dropFirst()) where e.start < prev.end.addingTimeInterval(-0.5) {
            sessionFlags.append(Flag(code: .epochOverlap, severity: .reject, epochIndex: e.index,
                                     detail: "epoch \(e.index) overlaps \(prev.index)"))
        }
        for e in epochs {
            if e.start < input.startedAt.addingTimeInterval(-1) || e.end > input.endedAt.addingTimeInterval(1)
                || e.duration <= 0 || e.duration > config.tracking.epochSeconds + 1 {
                structural[e.index, default: []].append(Flag(code: .epochOutOfBounds, severity: .reject, epochIndex: e.index,
                                                             detail: String(format: "%.0fs window", e.duration)))
            }
            if e.start >= input.startedAt.addingTimeInterval(config.limits.sessionMaxSeconds) {
                structural[e.index, default: []].append(Flag(code: .beyondSessionMax, severity: .reject, epochIndex: e.index,
                                                             detail: "after session max duration"))
            }
        }

        // HealthKit cross-check (informational: HK writes lag behind CoreMotion)
        if let hk = input.healthKit {
            let pedometerSteps = epochs.reduce(0) { $0 + $1.steps }
            if hk.manualSteps > 0 {
                sessionFlags.append(Flag(code: .manualHealthEntry, severity: .info, detail: "\(hk.manualSteps) manual steps ignored"))
            }
            if hk.thirdPartySteps > 0 {
                sessionFlags.append(Flag(code: .thirdPartyHealthSteps, severity: .info,
                                         detail: "\(hk.thirdPartySteps) from \(hk.thirdPartySources.joined(separator: ","))"))
            }
            if hk.iPhoneSteps > 0, pedometerSteps > 200 {
                let ratio = abs(Double(pedometerSteps - hk.iPhoneSteps)) / Double(pedometerSteps)
                if ratio > rules.healthKitMismatchRatio {
                    sessionFlags.append(Flag(code: .healthKitMismatch, severity: .info,
                                             detail: "pedometer \(pedometerSteps) vs HK \(hk.iPhoneSteps)"))
                }
            }
        }

        let robotic = roboticCadenceEpochs(epochs, rules: rules)
        let sessionRejected = sessionFlags.contains { $0.severity == .reject }
        let sessionWarnings = sessionFlags.filter { $0.severity == .warning }.count

        let verdicts = epochs.map { e -> EpochVerdict in
            var extra = structural[e.index] ?? []
            if robotic.contains(e.index) {
                extra.append(Flag(code: .roboticRhythm, severity: .warning, epochIndex: e.index,
                                  detail: "cadence constant across epochs"))
            }
            return verifyEpoch(e, config: config, extraFlags: extra, sessionWarnings: sessionWarnings,
                               sessionRejected: sessionRejected)
        }
        // Location spoofing anywhere in the session shows intent → void the whole session.
        let spoofed = verdicts.flatMap(\.flags).filter { [.simulatedLocation, .teleport].contains($0.code) && $0.severity == .reject }
        if rules.rejectSessionOnSpoofing, !spoofed.isEmpty, !sessionRejected {
            sessionFlags.append(Flag(code: spoofed[0].code, severity: .reject,
                                     detail: "location spoofing in \(Set(spoofed.compactMap(\.epochIndex)).count) epoch(s)"))
            let voided = verdicts.map { v -> EpochVerdict in
                var v = v
                v.valid = false
                v.rewardSteps = 0
                v.verifiedDistance = 0
                return v
            }
            return VerificationResult(verdicts: voided, sessionFlags: sessionFlags, sessionRejected: true)
        }
        return VerificationResult(verdicts: verdicts, sessionFlags: sessionFlags, sessionRejected: sessionRejected)
    }

    // MARK: Epoch

    static func verifyEpoch(_ e: Epoch, config: RewardConfig, extraFlags: [Flag] = [], sessionWarnings: Int = 0,
                            sessionRejected: Bool = false) -> EpochVerdict {
        let rules = config.rules
        var flags = extraFlags
        func add(_ code: FlagCode, _ severity: FlagSeverity, _ detail: String) {
            flags.append(Flag(code: code, severity: severity, epochIndex: e.index, detail: detail))
        }
        let minutes = max(e.duration / 60, 1.0 / 60)
        let hasGPS = e.gpsPoints >= rules.minGpsPointsForCoverage

        // Steps rate
        if Double(e.steps) > rules.cadenceMax * minutes * 1.05 {
            add(.cadenceTooHigh, .reject, String(format: "%.0f spm", e.cadence))
        }

        // CoreMotion activity classifier
        let automotive = e.activityFraction(.automotive)
        if automotive >= rules.automotiveFractionReject {
            add(.automotiveActivity, .reject, String(format: "automotive %.0f%%", automotive * 100))
        }
        let cycling = e.activityFraction(.cycling)
        if cycling >= rules.cyclingFractionReject {
            add(.cyclingActivity, .reject, String(format: "cycling %.0f%%", cycling * 100))
        }
        if e.steps >= rules.stepsWithoutMovementMinSteps, e.activityFraction(.stationary) >= rules.stationaryFractionWarn {
            add(.stationaryWithSteps, .warning, "\(e.steps) steps while stationary")
        }

        // GPS
        if e.simulatedPoints > 0 {
            add(.simulatedLocation, rules.rejectSimulatedLocation ? .reject : .warning, "\(e.simulatedPoints) simulated fixes")
        }
        if e.teleports > 0 {
            add(.teleport, .reject, "\(e.teleports) impossible jumps")
        }
        if hasGPS {
            if let avg = e.gpsAvgSpeed, avg > rules.vehicleSpeedMps {
                add(.vehicleSpeed, .reject, String(format: "avg %.1f m/s", avg))
            }
            if e.gpsMaxSpeed > rules.maxInstantSpeedMps {
                add(.instantSpeedSpike, .warning, String(format: "max %.1f m/s", e.gpsMaxSpeed))
            }
            if e.steps >= rules.stepsWithoutMovementMinSteps,
               e.gpsDisplacement < rules.stepsWithoutMovementMaxDisplacement,
               e.gpsDistance < rules.stepsWithoutMovementMaxDisplacement * 2 {
                add(.stepsWithoutMovement, .warning, String(format: "%d steps, %.0fm moved", e.steps, e.gpsDistance))
            }
            if e.gpsDistance > 30 {
                if e.steps < config.reward.minEpochSteps {
                    if e.gpsDistance > 150 { add(.strideImplausible, .reject, String(format: "%.0fm with %d steps", e.gpsDistance, e.steps)) }
                } else {
                    let stride = e.gpsDistance / Double(e.steps)
                    if stride > rules.strideMax * 2 {
                        add(.strideImplausible, .reject, String(format: "GPS stride %.2fm", stride))
                    } else if stride > rules.strideMax || stride < rules.strideMin {
                        add(.strideImplausible, .warning, String(format: "GPS stride %.2fm", stride))
                    }
                }
            }
            if let pd = e.pedometerDistance, pd > 50, e.gpsDistance > 50 {
                let ratio = max(pd, e.gpsDistance) / min(pd, e.gpsDistance)
                if ratio > rules.gpsPedometerMismatchRatio {
                    add(.gpsPedometerMismatch, .warning, String(format: "GPS %.0fm vs pedometer %.0fm", e.gpsDistance, pd))
                }
            }
        } else {
            if e.source == .live { add(.noGpsCoverage, .info, "\(e.gpsPoints) fixes") }
            if let pd = e.pedometerDistance, e.steps >= rules.stepsWithoutMovementMinSteps {
                let stride = pd / Double(e.steps)
                if stride > rules.strideMax || stride < rules.strideMin {
                    add(.strideImplausible, .warning, String(format: "pedometer stride %.2fm", stride))
                }
            }
        }

        // Accelerometer rhythm (shaker machines are far more regular than humans)
        if let m = e.motion, let cv = m.peakIntervalCV, m.peakCount >= rules.roboticMinPeaks, cv < rules.roboticRhythmCV {
            add(.roboticRhythm, .warning, String(format: "step interval CV %.3f", cv))
        }

        // Several independent "machine" indicators together → shaker / pendulum / fan rig.
        let machineIndicators = Set(flags.filter { [.roboticRhythm, .stepsWithoutMovement, .stationaryWithSteps].contains($0.code) }
            .map { "\($0.code.rawValue)-\($0.detail.hasPrefix("cadence") ? "session" : "epoch")" })
        if machineIndicators.count >= 2 {
            add(.roboticRhythm, .reject, "machine-like motion (\(machineIndicators.count) indicators)")
        }

        if e.source == .recovered { add(.recoveredData, .info, "back-filled from CoreMotion history") }

        let rejected = flags.contains { $0.severity == .reject } || sessionRejected
        let warnings = flags.filter { $0.severity == .warning }.count + sessionWarnings
        let trust = max(0, 1 - Double(warnings) * rules.warningPenalty)
        let valid = !rejected && trust >= config.reward.minTrustToReward
        let multiplier = e.source == .recovered ? config.reward.recoveredMultiplier
            : (hasGPS ? 1 : config.reward.noGpsMultiplier)
        let activity: ActivityKind = (e.dominantActivity == .running || e.cadence >= rules.runningCadence) ? .running : .walking
        let rewardSteps = valid && e.steps >= config.reward.minEpochSteps ? e.steps : 0
        let distance = valid && hasGPS ? min(e.gpsDistance, Double(e.steps) * rules.strideMax) : 0

        return EpochVerdict(index: e.index, valid: valid, trust: trust, rewardSteps: rewardSteps,
                            verifiedDistance: distance, activity: activity, multiplier: multiplier, flags: flags)
    }

    /// Humans drift in cadence minute to minute; a machine does not.
    static func roboticCadenceEpochs(_ epochs: [Epoch], rules: VerificationRules) -> Set<Int> {
        let n = rules.roboticSessionMinEpochs
        guard n >= 2, epochs.count >= n else { return [] }
        var result = Set<Int>()
        for startIdx in 0...(epochs.count - n) {
            let window = Array(epochs[startIdx..<(startIdx + n)])
            guard window.allSatisfy({ $0.steps >= 60 && $0.duration >= 30 }) else { continue }
            let cadences = window.map(\.cadence)
            let mean = cadences.reduce(0, +) / Double(n)
            let sd = (cadences.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n)).squareRoot()
            if mean > 0, sd / mean < rules.roboticSessionCadenceCV {
                window.forEach { result.insert($0.index) }
            }
        }
        return result
    }
}
