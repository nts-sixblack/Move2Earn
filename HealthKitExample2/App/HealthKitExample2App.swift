//
//  HealthKitExample2App.swift
//  HealthKitExample2
//
//  Created by Thanh Sau on 17/10/26.
//

import SwiftUI

@main
struct HealthKitExample2App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                let env = AppEnvironment.shared
                RootView()
                    .environmentObject(env.session)
                    .environmentObject(env.wallet)
                    .environmentObject(env.sync)
                    .environmentObject(env.history)
                    .environmentObject(env.logger)
                    .environmentObject(env.config)
                    .environmentObject(env.passiveSync)
            }
        }
        .onChange(of: scenePhase) { phase in
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            let env = AppEnvironment.shared
            switch phase {
            case .active:
                env.session.setPhase(.foreground)
                Task { await env.sync.syncPending() }
            case .background:
                env.session.setPhase(.background)
            default:
                break
            }
        }
    }
}
