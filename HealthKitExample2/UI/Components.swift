//
//  Components.swift
//  HealthKitExample2
//

import Combine
import CoreMotion
import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            MoveView().tabItem { Label("Move", systemImage: "figure.walk") }
            PassiveSyncView().tabItem { Label("Passive HK", systemImage: "heart.text.square") }
            HistoryView().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            LogsView().tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct FlagRow: View {
    var flag: Flag

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.code.rawValue + (flag.epochIndex.map { " · #\($0)" } ?? ""))
                    .font(.subheadline.weight(.medium))
                Text(flag.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch flag.severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .reject: "xmark.octagon"
        }
    }

    private var color: Color {
        switch flag.severity {
        case .info: .blue
        case .warning: .orange
        case .reject: .red
        }
    }
}

struct StatusBadge: View {
    var status: RecordStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .pending: .orange
        case .credited: .green
        case .rejected: .red
        }
    }
}

enum Format {
    static func coins(_ v: Double) -> String { String(format: "%.3f", v) }
    static func meters(_ v: Double) -> String { v >= 1000 ? String(format: "%.2f km", v / 1000) : String(format: "%.0f m", v) }
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Permissions

final class PermissionCenter: ObservableObject {
    @Published var motion: CMAuthorizationStatus = CorePedometer.authorizationStatus
    @Published var healthRequested = false

    func refresh() async {
        motion = CorePedometer.authorizationStatus
        healthRequested = await HealthKitProvider.shared.hasRequestedAuthorization()
    }

    /// CoreMotion has no explicit request API: the first query triggers the prompt.
    func requestMotion() async {
        _ = try? await CoreActivity().query(from: Date().addingTimeInterval(-60), to: Date())
        _ = try? await CorePedometer().query(from: Date().addingTimeInterval(-60), to: Date())
        await refresh()
    }

    func requestHealth() async {
        try? await HealthKitProvider.shared.requestAuthorization()
        await refresh()
        let env = AppEnvironment.shared
        HealthKitProvider.shared.enableBackgroundDelivery {
            await env.bootstrap(reason: "healthKitWake")
        }
    }
}

// MARK: - iOS 15 compatible building blocks

/// Title/value row (stand-in for iOS 16's LabeledContent).
struct InfoRow<Content: View>: View {
    var title: String
    var content: Content

    init(_ title: String, value: String) where Content == Text {
        self.title = title
        self.content = Text(value)
    }

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            content.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

struct EmptyStateView: View {
    var title: String
    var systemImage: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// Share sheet button (stand-in for iOS 16's ShareLink).
struct ShareButton: View {
    var url: URL
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: { Image(systemName: "square.and.arrow.up") }
            .accessibilityLabel("Chia sẻ")
            .sheet(isPresented: $presented) { ActivityView(items: [url]) }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
