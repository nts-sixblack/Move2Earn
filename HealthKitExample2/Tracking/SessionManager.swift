//
//  SessionManager.swift
//  HealthKitExample2
//
//  Orchestrates a move-to-earn session across every app state:
//
//  • Foreground / background: GPS (background mode) keeps the process alive,
//    a heartbeat closes 60s epochs, the state is checkpointed every 10s.
//  • Suspended (no "Always"/background location): nothing runs; on resume the
//    heartbeat catches up and closes the missed windows from CMPedometer /
//    CMMotionActivity history → those epochs are `recovered`.
//  • Killed (swipe-up, jetsam, crash, reboot): `active.json` survives. On the
//    next launch — user opening the app, significant-location-change relaunch,
//    HealthKit background delivery or BGAppRefresh — `restoreIfNeeded` reloads
//    the session, flags the relaunch and back-fills the gap (up to
//    `maxRecoveryGapSeconds`, otherwise the session is closed at the cutoff).
//  • Clock changes: every heartbeat compares wall vs monotonic clock.
//

import Foundation
import Combine

final class SessionManager: ObservableObject {
    // MARK: Observable state for UI

    @Published private(set) var session: ActiveSession?
    @Published private(set) var liveSteps = 0
    @Published private(set) var livePedometerDistance: Double?
    @Published private(set) var currentActivity: ActivityPoint?
    @Published private(set) var lastLocation: LocationPoint?
    @Published private(set) var liveVerification: VerificationResult?
    @Published private(set) var liveEstimate: RewardBreakdown = .zero
    @Published private(set) var appPhase: AppPhase = .foreground
    @Published private(set) var isBusy = false
    @Published var message: String?

    var isActive: Bool { session != nil }

    // MARK: Dependencies

    private let steps: StepCounting
    private let activity: ActivitySensing
    let location: LocationTracking
    private let motion: MotionAnalyzing
    private let store: FileStore
    private let logger: EventLogger
    private let configProvider: () -> RewardConfig
    private let now: () -> Date
    private let anchorProvider: (Date) -> ClockAnchor
    private let integrityProvider: (Bool?) -> IntegritySnapshot
    private let healthSummary: @MainActor (Date, Date) async -> HealthKitSummary?
    private let onReportReady: @MainActor (SessionReport) async -> Void
    private let useTimer: Bool
    private let sensorSource: String

    private var heartbeat: Timer?
    private var lastCheckpointAt = Date.distantPast
    private var routeBuffer: [LocationPoint] = []
    private var ticking = false
    private var cachedIntegrity: IntegritySnapshot?
    private var loggedPedometerError = false

    private let activeFile = "active.json"

    init(steps: StepCounting, activity: ActivitySensing, location: LocationTracking, motion: MotionAnalyzing,
         store: FileStore, logger: EventLogger, config: @escaping () -> RewardConfig,
         now: @escaping () -> Date = Date.init,
         anchor: @escaping (Date) -> ClockAnchor = { ClockGuard.anchor(now: $0) },
         integrity: @escaping (Bool?) -> IntegritySnapshot = { DeviceIntegrity.snapshot(preciseLocation: $0) },
         healthSummary: @escaping @MainActor (Date, Date) async -> HealthKitSummary? = { _, _ in nil },
         useTimer: Bool = true,
         sensorSource: String = "coremotion",
         onReportReady: @escaping @MainActor (SessionReport) async -> Void) {
        self.steps = steps
        self.activity = activity
        self.location = location
        self.motion = motion
        self.store = store
        self.logger = logger
        self.configProvider = config
        self.now = now
        self.anchorProvider = anchor
        self.integrityProvider = integrity
        self.healthSummary = healthSummary
        self.useTimer = useTimer
        self.sensorSource = sensorSource
        self.onReportReady = onReportReady
    }

    var hasPersistedSession: Bool { store.exists(activeFile) }

    // MARK: - Start

    func start() async {
        guard session == nil, !isBusy else { return }
        let cfg = configProvider()
        let t = now()
        let id = UUID()
        let integrity = integrityProvider(location.preciseLocation)
        cachedIntegrity = integrity
        let entry = logger.log("sessionStarted", session: id, [
            "location": location.authorization.rawValue,
            "pedometer": String(steps.isAvailable),
            "activity": String(activity.isAvailable),
            "jailbroken": String(integrity.isJailbroken),
            "simulator": String(integrity.isSimulator),
            "configVersion": String(cfg.version),
            "sensors": sensorSource,
        ])
        session = ActiveSession(id: id, nonce: Self.randomNonce(), startedAt: t, startAnchor: anchorProvider(t),
                                lastTick: anchorProvider(t), nextEpochStart: t, nextEpochIndex: 0,
                                aliveIntervals: [DateInterval(start: t, duration: 0)], pendingLocations: [],
                                epochs: [], clientFlags: [], firstLogSeq: entry.seq, relaunchCount: 0,
                                routePointCount: 0, routeDistance: 0)
        session?.phaseMarks = [PhaseMark(t: t, phase: appPhase)]
        liveSteps = 0
        livePedometerDistance = nil
        liveEstimate = .zero
        liveVerification = nil
        checkpoint()
        startSensors()
    }

    // MARK: - Recovery after kill / relaunch

    /// Call on every launch (foreground or background). Safe to call repeatedly.
    func restoreIfNeeded(reason: String) async {
        guard session == nil, !isBusy else {
            if session != nil { await tick() }
            return
        }
        guard store.exists(activeFile) else { return }
        guard var s = try? store.load(ActiveSession.self, from: activeFile) else {
            logger.log("sessionRestoreFailed", level: .error, ["reason": "decode"])
            store.delete(activeFile)
            return
        }
        let cfg = configProvider()
        let t = now()
        let current = anchorProvider(t)
        let gap = t.timeIntervalSince(s.lastTick.wall)
        s.relaunchCount += 1
        s.clientFlags.append(Flag(code: .appRelaunched, severity: .info,
                                  detail: String(format: "%@ after %.0fs gap", reason, gap)))
        appendClockFlags(&s, from: s.lastTick, to: current, tolerance: cfg.rules.clockToleranceSeconds)
        logger.log("sessionRestored", level: .warning, session: s.id, [
            "reason": reason, "gapSeconds": String(format: "%.0f", gap),
            "epochs": String(s.epochs.count), "relaunch": String(s.relaunchCount),
        ])
        s.phaseMarks = (s.phaseMarks ?? []) + [PhaseMark(t: t, phase: appPhase)]
        session = s
        cachedIntegrity = integrityProvider(location.preciseLocation)

        if gap > cfg.limits.maxRecoveryGapSeconds {
            let cutoff = s.lastTick.wall.addingTimeInterval(cfg.limits.maxRecoveryGapSeconds)
            session?.clientFlags.append(Flag(code: .gapExceeded, severity: .info,
                                             detail: String(format: "gap %.0fs > %.0fs", gap, cfg.limits.maxRecoveryGapSeconds)))
            await finish(reason: .gapExceeded, endAt: cutoff)
            return
        }
        startSensors()
        await tick()
    }

    // MARK: - Heartbeat

    func tick() async {
        guard var s = session, !ticking, !isBusy else { return }
        ticking = true
        defer { ticking = false }
        let cfg = configProvider()
        let t = now()
        let a = anchorProvider(t)
        appendClockFlags(&s, from: s.lastTick, to: a, tolerance: cfg.rules.clockToleranceSeconds)
        EpochBuilder.recordAlive(&s.aliveIntervals, at: t, maxGap: cfg.tracking.heartbeatSeconds * 3)
        s.lastTick = a
        session = s

        await closeEpochs(upTo: t, config: cfg)

        guard let current = session else { return }
        if t.timeIntervalSince(current.startedAt) >= cfg.limits.sessionMaxSeconds {
            ticking = false
            await finish(reason: .maxDuration, endAt: current.startedAt.addingTimeInterval(cfg.limits.sessionMaxSeconds))
            return
        }
        let idleEpochs = Int(cfg.limits.autoEndIdleMinutes * 60 / cfg.tracking.epochSeconds)
        if idleEpochs > 0, current.epochs.count >= idleEpochs,
           current.epochs.suffix(idleEpochs).allSatisfy({ $0.steps < cfg.reward.minEpochSteps }) {
            ticking = false
            await finish(reason: .idle, endAt: nil)
            return
        }
        if t.timeIntervalSince(lastCheckpointAt) >= cfg.tracking.checkpointSeconds { checkpoint() }
        updateEstimate()
    }

    // MARK: - Stop

    func stop() async { await finish(reason: .user, endAt: nil) }

    func finish(reason: EndReason, endAt: Date?) async {
        guard session != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        heartbeat?.invalidate()
        heartbeat = nil
        let cfg = configProvider()
        let end = min(endAt ?? now(), now())
        await closeEpochs(upTo: end, config: cfg, includePartial: true)
        stopSensors()
        flushRoute()
        guard let s = session else { return }

        let endEntry = logger.log("sessionEnded", session: s.id, [
            "reason": reason.rawValue, "epochs": String(s.epochs.count),
            "steps": String(s.epochs.reduce(0) { $0 + $1.steps }),
            "relaunches": String(s.relaunchCount),
        ])
        let hk = await healthSummary(s.startedAt, end)
        let routeData = store.read(routeFile(s.id)) ?? Data()
        let report = SessionReport(
            sessionId: s.id, nonce: s.nonce, deviceId: DeviceIdentity.installId,
            appVersion: DeviceIdentity.appVersion, osVersion: DeviceIdentity.osVersion,
            deviceModel: DeviceIdentity.deviceModel, configVersion: cfg.version,
            startedAt: s.startedAt, endedAt: end, endReason: reason,
            startAnchor: s.startAnchor, endAnchor: anchorProvider(now()),
            epochs: s.epochs, routePointCount: s.routePointCount, routeDistance: s.routeDistance,
            routeHash: HashChain.sha256Hex(routeData), healthKit: hk,
            integrity: integrityProvider(location.preciseLocation),
            clientFlags: s.clientFlags,
            events: logger.entries(fromSeq: s.firstLogSeq, toSeq: endEntry.seq),
            createdAt: now(), sensorSource: sensorSource)
        session = nil
        store.delete(activeFile)
        await onReportReady(report)
    }

    /// Discards the in-flight session without reporting it.
    func discard() {
        guard let s = session else { return }
        heartbeat?.invalidate()
        heartbeat = nil
        stopSensors()
        logger.log("sessionDiscarded", level: .warning, session: s.id)
        session = nil
        store.delete(activeFile)
    }

    // MARK: - App lifecycle hooks

    func setPhase(_ phase: AppPhase) {
        guard phase != appPhase else { return }
        appPhase = phase
        if var s = session {
            s.phaseMarks = (s.phaseMarks ?? []) + [PhaseMark(t: now(), phase: phase)]
            session = s
        }
        logger.log("appPhase", session: session?.id, ["phase": phase.rawValue])
        if phase == .background { checkpoint() }
        if phase == .foreground { Task { await tick() } }
    }

    func prepareForTermination() {
        logger.log("appWillTerminate", level: .warning, session: session?.id)
        checkpoint()
    }

    func recordClockChangeNotification(_ name: String) {
        guard var s = session else {
            logger.log(name, level: .warning)
            return
        }
        let code: FlagCode = name == "timezoneChanged" ? .timezoneChanged : .clockTampered
        let severity: FlagSeverity = code == .timezoneChanged ? .info : .reject
        s.clientFlags.append(Flag(code: code, severity: severity, detail: "system notification \(name)"))
        session = s
        logger.log(name, level: .warning, session: s.id)
        checkpoint()
    }

    // MARK: - Sensors

    private func startSensors() {
        guard let s = session else { return }
        let cfg = configProvider()
        location.onPoints = { [weak self] points in self?.handle(points: points) }
        location.onAuthorizationChange = { [weak self] auth in self?.handleAuthorization(auth) }
        location.start(config: cfg.tracking)
        let onSteps: @MainActor (PedometerSample) -> Void = { [weak self] sample in
            self?.liveSteps = sample.steps
            self?.livePedometerDistance = sample.distance
        }
        let onActivity: @MainActor (ActivityPoint) -> Void = { [weak self] point in self?.currentActivity = point }
        steps.startLive(from: s.startedAt) { sample in Task { @MainActor in onSteps(sample) } }
        activity.startLive { point in Task { @MainActor in onActivity(point) } }
        motion.start(hz: cfg.tracking.motionSampleHz)
        if useTimer {
            heartbeat?.invalidate()
            let beat: @MainActor () -> Void = { [weak self] in Task { await self?.tick() } }
            let timer = Timer(timeInterval: cfg.tracking.heartbeatSeconds, repeats: true) { _ in
                Task { @MainActor in beat() }
            }
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
        }
    }

    private func stopSensors() {
        location.stop()
        steps.stopLive()
        activity.stopLive()
        motion.stop()
    }

    func handle(points: [LocationPoint]) {
        guard var s = session else { return }
        let cfg = configProvider()
        for p in points where p.t >= s.startedAt && p.t >= s.nextEpochStart.addingTimeInterval(-1) {
            s.pendingLocations.append(p)
            routeBuffer.append(p)
            s.routePointCount += 1
            if p.hAcc >= 0, p.hAcc <= cfg.tracking.gpsMaxAccuracy {
                if let prev = s.lastRouteLocation {
                    let d = EpochBuilder.haversine(prev.lat, prev.lon, p.lat, p.lon)
                    let dt = max(p.t.timeIntervalSince(prev.t), 0.001)
                    if d / dt <= cfg.rules.teleportSpeedMps { s.routeDistance += d }
                }
                s.lastRouteLocation = p
            }
            lastLocation = p
        }
        session = s
    }

    private func handleAuthorization(_ auth: LocationAuth) {
        logger.log("locationAuthorization", session: session?.id, ["status": auth.rawValue])
        guard var s = session, !auth.canTrack else { return }
        s.clientFlags.append(Flag(code: .permissionRevoked, severity: .info, detail: "location \(auth.rawValue)"))
        session = s
    }

    // MARK: - Epochs

    private func closeEpochs(upTo t: Date, config: RewardConfig, includePartial: Bool = false) async {
        let length = config.tracking.epochSeconds
        while let s = session, s.nextEpochStart.addingTimeInterval(length) <= t {
            await closeEpoch(start: s.nextEpochStart, end: s.nextEpochStart.addingTimeInterval(length), config: config)
        }
        if includePartial, let s = session, t.timeIntervalSince(s.nextEpochStart) >= 5 {
            await closeEpoch(start: s.nextEpochStart, end: t, config: config)
        }
    }

    private func closeEpoch(start: Date, end: Date, config: RewardConfig) async {
        var sample: PedometerSample?
        do {
            sample = try await steps.query(from: start, to: end)
        } catch {
            if !loggedPedometerError {
                loggedPedometerError = true
                logger.log("pedometerError", level: .error, session: session?.id, ["error": error.localizedDescription])
            }
        }
        let activities = (try? await activity.query(from: start.addingTimeInterval(-300), to: end)) ?? []
        guard var s = session, s.nextEpochStart == start else { return }

        let locations = s.pendingLocations.filter { $0.t < end }
        s.pendingLocations.removeAll { $0.t < end }
        let alive = EpochBuilder.aliveFraction(s.aliveIntervals, start: start, end: end)
        let features = alive >= 0.5 ? motion.features(from: start, to: end) : nil
        let epoch = EpochBuilder.build(index: s.nextEpochIndex, start: start, end: end, pedometer: sample,
                                       activities: activities, locations: locations,
                                       previousLocation: s.lastEpochLocation, motion: features,
                                       aliveFraction: alive,
                                       phase: Self.phase(at: start.addingTimeInterval(end.timeIntervalSince(start) / 2),
                                                         marks: s.phaseMarks, fallback: appPhase),
                                       tracking: config.tracking, rules: config.rules)
        if let last = locations.last(where: { $0.hAcc >= 0 && $0.hAcc <= config.tracking.gpsMaxAccuracy }) {
            s.lastEpochLocation = last
        }
        s.epochs.append(epoch)
        s.nextEpochStart = end
        s.nextEpochIndex += 1
        let keepAfter = end.addingTimeInterval(-config.tracking.epochSeconds * 2)
        s.aliveIntervals.removeAll { $0.end < keepAfter }
        session = s
        logger.log("epochClosed", level: .debug, session: s.id, [
            "i": String(epoch.index), "steps": String(epoch.steps), "src": epoch.source.rawValue,
            "gps": String(epoch.gpsPoints), "act": epoch.dominantActivity.rawValue,
            "alive": String(format: "%.2f", alive),
        ])
    }

    // MARK: - Persistence

    func checkpoint() {
        guard let s = session else { return }
        do {
            try store.save(s, to: activeFile)
            flushRoute()
            lastCheckpointAt = now()
        } catch {
            logger.log("checkpointFailed", level: .error, session: s.id, ["error": error.localizedDescription])
        }
    }

    private func flushRoute() {
        guard let s = session, !routeBuffer.isEmpty else { return }
        for p in routeBuffer {
            if let line = try? FileStore.encoder.encode(p) { try? store.append(line: line, to: routeFile(s.id)) }
        }
        routeBuffer.removeAll()
    }

    func routeFile(_ id: UUID) -> String { "route-\(id.uuidString).jsonl" }

    // MARK: - Helpers

    private func appendClockFlags(_ s: inout ActiveSession, from old: ClockAnchor, to new: ClockAnchor, tolerance: Double) {
        switch ClockGuard.compare(from: old, to: new, tolerance: tolerance) {
        case .ok:
            break
        case .rebooted:
            s.clientFlags.append(Flag(code: .deviceRebooted, severity: .info, detail: "boot session changed"))
            logger.log("deviceRebooted", level: .warning, session: s.id)
        case .wallShifted(let drift):
            let code: FlagCode = drift < 0 ? .clockMovedBackwards : .clockTampered
            s.clientFlags.append(Flag(code: code, severity: .reject, detail: String(format: "wall clock drift %.0fs", drift)))
            logger.log("clockTampered", level: .error, session: s.id, ["drift": String(format: "%.0f", drift)])
        }
    }

    private func updateEstimate() {
        guard let s = session else { return }
        let cfg = configProvider()
        let integrity = cachedIntegrity ?? integrityProvider(location.preciseLocation)
        let input = VerificationInput(epochs: s.epochs, startedAt: s.startedAt, endedAt: s.lastTick.wall,
                                      startAnchor: s.startAnchor, endAnchor: s.lastTick, integrity: integrity,
                                      clientFlags: s.clientFlags, healthKit: nil)
        let result = ActivityVerifier.verify(input, config: cfg, requireMinDuration: false)
        liveVerification = result
        liveEstimate = RewardCalculator.calculate(epochs: s.epochs, result: result, config: cfg)
    }

    static func phase(at t: Date, marks: [PhaseMark]?, fallback: AppPhase) -> AppPhase {
        guard let marks, !marks.isEmpty else { return fallback }
        return marks.last { $0.t <= t }?.phase ?? marks[0].phase
    }

    private static func randomNonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
