import Foundation
import Testing
@testable import HealthKitExample2

/// End-to-end lifecycle with fake sensors and a controllable clock:
/// foreground/background, suspension, kill + relaunch, long gaps, clock tampering, idle.
struct SessionLifecycleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func liveSessionProducesLiveEpochsAndIntactLog() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        await h.manager.start()
        #expect(h.location.started)
        await h.runAlive(seconds: 185)
        await h.manager.stop()

        let report = try #require(h.reports.first)
        #expect(report.epochs.count == 4)  // 3 full + 5s partial
        #expect(report.epochs.allSatisfy { $0.source == .live })
        #expect(report.epochs.prefix(3).allSatisfy { $0.steps == 110 })
        #expect(HashChain.firstBreak(in: report.events) == nil)
        #expect(report.events.first?.type == "sessionStarted")
        #expect(report.events.last?.type == "sessionEnded")
        #expect(!h.manager.isActive)
        #expect(!h.manager.hasPersistedSession)

        let (server, key) = h.server()
        let receipt = h.submit(report, to: server, key: key)
        #expect(receipt.status == .credited)
        #expect(receipt.coins > 0)
    }

    @Test func suspendedAppBackfillsFromPedometerAsRecovered() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        await h.manager.start()
        await h.runAlive(seconds: 120)
        h.clock.advance(300)  // suspended: no heartbeats for 5 minutes
        await h.runAlive(seconds: 120)
        await h.manager.stop()

        let report = try #require(h.reports.first)
        let recovered = report.epochs.filter { $0.source == .recovered }
        #expect(recovered.count >= 4)
        #expect(recovered.allSatisfy { $0.steps == 110 && $0.phase == .notRunning })
        #expect(report.totalSteps == 110 * 9)
        // contiguous, no overlap, no gap
        for (a, b) in zip(report.epochs, report.epochs.dropFirst()) { #expect(a.end == b.start) }
    }

    @Test func killedAppRestoresAndBackfillsOnRelaunch() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        await h.manager.start()
        await h.runAlive(seconds: 125)
        let id = try #require(h.manager.session?.id)

        // swipe-kill: in-memory state lost; 10 minutes later the user opens the app
        h.clock.advance(600)
        h.launch()
        #expect(!h.manager.isActive)
        #expect(h.manager.hasPersistedSession)
        await h.manager.restoreIfNeeded(reason: "userLaunch")
        #expect(h.manager.session?.id == id)
        #expect(h.manager.session?.relaunchCount == 1)
        #expect(h.location.started)

        await h.runAlive(seconds: 60)
        await h.manager.stop()
        let report = try #require(h.reports.first)
        #expect(report.sessionId == id)
        #expect(report.clientFlags.contains { $0.code == .appRelaunched })
        #expect(report.epochs.filter { $0.source == .recovered }.count >= 9)
        #expect(report.totalSteps >= 110 * 13)
        #expect(HashChain.firstBreak(in: report.events) == nil)
        #expect(report.events.contains { $0.type == "sessionRestored" })

        let (server, key) = h.server()
        let receipt = h.submit(report, to: server, key: key)
        #expect(receipt.status == .credited)
        #expect(receipt.verification.allFlags.contains { $0.code == .recoveredData })
    }

    @Test func gapLongerThanLimitClosesSessionAtCutoff() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        h.config.limits.maxRecoveryGapSeconds = 600
        await h.manager.start()
        await h.runAlive(seconds: 60)
        let lastTick = h.clock.wall
        h.clock.advance(3 * 3600)
        h.launch()
        await h.manager.restoreIfNeeded(reason: "locationRelaunch")

        let report = try #require(h.reports.first)
        #expect(report.endReason == .gapExceeded)
        #expect(abs(report.endedAt.timeIntervalSince(lastTick.addingTimeInterval(600))) < 1)
        #expect(report.epochs.last.map { $0.end <= report.endedAt } == true)
        #expect(report.clientFlags.contains { $0.code == .gapExceeded })
        #expect(!h.manager.isActive)
        #expect(!h.manager.hasPersistedSession)
    }

    @Test func clockChangeDuringSessionIsFlaggedAndRejected() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        await h.manager.start()
        await h.runAlive(seconds: 120)
        h.clock.shiftWall(3600)  // user moves the date forward
        await h.runAlive(seconds: 60)
        await h.manager.stop()

        let report = try #require(h.reports.first)
        #expect(report.clientFlags.contains { $0.code == .clockTampered })
        let (server, key) = h.server()
        let receipt = h.submit(report, to: server, key: key)
        #expect(receipt.status == .rejected)
        #expect(receipt.coins == 0)
    }

    @Test func clockMovedBackwardsNeverDuplicatesEpochs() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        await h.manager.start()
        await h.runAlive(seconds: 180)
        let before = h.manager.session?.epochs.count ?? 0
        h.clock.shiftWall(-1800)
        await h.runAlive(seconds: 60)
        #expect(h.manager.session?.epochs.count == before)
        #expect(h.manager.session?.clientFlags.contains { $0.code == .clockMovedBackwards } == true)
    }

    @Test func rebootDuringSessionIsRecordedAndStillRecovers() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        await h.manager.start()
        await h.runAlive(seconds: 60)
        h.clock.advance(120)
        h.clock.reboot()
        h.launch()
        await h.manager.restoreIfNeeded(reason: "userLaunch")
        await h.runAlive(seconds: 30)
        await h.manager.stop()
        let report = try #require(h.reports.first)
        #expect(report.clientFlags.contains { $0.code == .deviceRebooted })
        #expect(report.totalSteps > 110 * 3)
    }

    @Test func idleSessionAutoEnds() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        h.config.limits.autoEndIdleMinutes = 3
        h.pedometer.stepsPerMinute = 0
        await h.manager.start()
        await h.runAlive(seconds: 240)
        let report = try #require(h.reports.first)
        #expect(report.endReason == .idle)
    }

    @Test func maxDurationEndsSession() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        h.config.limits.sessionMaxSeconds = 300
        await h.manager.start()
        await h.runAlive(seconds: 400)
        let report = try #require(h.reports.first)
        #expect(report.endReason == .maxDuration)
        #expect(report.endedAt.timeIntervalSince(report.startedAt) <= 300.5)
    }

    @Test func checkpointKeepsPendingGpsAcrossKill() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        await h.manager.start()
        h.clock.advance(20)
        let points = (0..<10).map { i in
            LocationPoint(t: h.clock.wall.addingTimeInterval(Double(i) - 10), lat: 10 + Double(i) * 0.00002, lon: 106,
                          alt: 0, hAcc: 6, vAcc: 4, speed: 1.4, speedAcc: 0.4, course: 0, simulated: false, accessory: false)
        }
        h.manager.handle(points: points)
        h.manager.checkpoint()
        h.launch()
        await h.manager.restoreIfNeeded(reason: "userLaunch")
        #expect(h.manager.session?.pendingLocations.count == 10)
        #expect(h.manager.session?.routePointCount == 10)
    }

    @Test func spoofedLocationDuringLiveSessionVoidsReward() async throws {
        let h = Harness(clock: FakeClock(start: t0))
        await h.manager.start()
        for _ in 0..<6 {
            h.clock.advance(10)
            let p = LocationPoint(t: h.clock.wall, lat: 10, lon: 106, alt: 0, hAcc: 5, vAcc: 5, speed: 1.4,
                                  speedAcc: 0.5, course: 0, simulated: true, accessory: false)
            h.manager.handle(points: [p])
            await h.manager.tick()
        }
        await h.runAlive(seconds: 120)
        await h.manager.stop()
        let (server, key) = h.server()
        let receipt = h.submit(try #require(h.reports.first), to: server, key: key)
        #expect(receipt.status == .rejected)
        #expect(receipt.allFlags.contains { $0.code == .simulatedLocation })
    }
}

struct PhaseTrackingTests {
    @Test func epochsKeepThePhaseTheyWereObservedIn() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let h = Harness(clock: FakeClock(start: t0))
        await h.manager.start()
        await h.runAlive(seconds: 60)
        h.manager.setPhase(.background)
        await h.runAlive(seconds: 115)
        // killed while in background; relaunched later in the foreground
        h.clock.advance(120)
        h.launch()
        await h.manager.restoreIfNeeded(reason: "userLaunch")
        await h.manager.stop()
        let report = try #require(h.reports.first)
        #expect(report.epochs[0].phase == .foreground)
        #expect(report.epochs[1].phase == .background)
        #expect(report.epochs[2].phase == .background)
        #expect(report.epochs[3].source == .recovered)
        #expect(report.epochs[3].phase == .notRunning)
    }
}
