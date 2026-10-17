//
//  AppDelegate.swift
//  HealthKitExample2
//
//  Entry point for every launch path: user tap, location relaunch after
//  termination, HealthKit background delivery, BGAppRefresh.
//

import BackgroundTasks
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTaskId = "com.sixpilot.HealthKitExample.refresh"
    static let processingTaskId = "com.sixpilot.HealthKitExample.processing"

    private var isRunningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard !isRunningTests else { return true }
        let env = AppEnvironment.shared
        let reason: String
        if launchOptions?[UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsLocationKey")] != nil { reason = "locationRelaunch" }
        else if application.applicationState == .background { reason = "backgroundLaunch" }
        else { reason = "userLaunch" }

        env.logger.log("appLaunched", ["reason": reason, "state": String(application.applicationState.rawValue),
                                       "pendingSession": String(env.session.hasPersistedSession),
                                       "version": DeviceIdentity.appVersion])

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                AppDelegate.scheduleRefresh()
                _ = env.logger.log("backgroundRefresh")
                await env.bootstrap(reason: "bgRefresh")
                await env.passiveSync.sync(trigger: .bgAppRefresh)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                Task { @MainActor in env.session.checkpoint() }
            }
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskId, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in
                AppDelegate.scheduleProcessing()
                _ = env.logger.log("backgroundProcessing")
                await env.passiveSync.sync(trigger: .bgProcessing)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                // Background processing expired
            }
        }

        HealthKitProvider.shared.enableBackgroundDelivery {
            await MainActor.run { _ = env.logger.log("healthKitWake") }
            await env.bootstrap(reason: "healthKitWake")
            await env.passiveSync.sync(trigger: .healthKitWake)
        }

        let center = NotificationCenter.default
        center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { env.session.recordClockChangeNotification("systemClockChanged") }
        }
        center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { env.session.recordClockChangeNotification("timezoneChanged") }
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                env.logger.log("memoryWarning", level: .warning, session: env.session.session?.id)
                env.session.checkpoint()
            }
        }
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                _ = env.logger.log("lowPowerMode", session: env.session.session?.id,
                               ["enabled": String(ProcessInfo.processInfo.isLowPowerModeEnabled)])
            }
        }

        if application.applicationState == .background { env.session.setPhase(.background) }
        Task { await env.bootstrap(reason: reason) }
        Self.scheduleRefresh()
        Self.scheduleProcessing()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        guard !isRunningTests else { return }
        AppEnvironment.shared.session.prepareForTermination()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Self.scheduleRefresh()
        Self.scheduleProcessing()
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
