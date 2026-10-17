//
//  LogsView.swift
//  HealthKitExample2
//

import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var logger: EventLogger
    private var env: AppEnvironment { .shared }
    @State private var hideDebug = true
    @State private var brokenAt: Int?
    @State private var verified = false

    var body: some View {
        let entries = logger.recent.reversed().filter { !hideDebug || $0.level != .debug }
        NavigationView {
            List {
                Section {
                    HStack {
                        Image(systemName: logger.chainIntact ? "lock.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(logger.chainIntact ? .green : .red)
                        Text(logger.chainIntact ? "Hash chain nguyên vẹn" : "Hash chain bị phá vỡ")
                        Spacer()
                        Button("Kiểm tra") {
                            brokenAt = logger.verifyAll()
                            verified = true
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    if verified {
                        Text(brokenAt.map { "Hỏng tại seq \($0)" } ?? "Toàn bộ log hợp lệ")
                            .font(.caption).foregroundStyle(brokenAt == nil ? .green : .red)
                    }
                    Toggle("Ẩn log debug (epochClosed…)", isOn: $hideDebug)
                }
                Section("\(entries.count) sự kiện gần đây") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("#\(entry.seq)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Text(entry.type).font(.subheadline.weight(.medium)).foregroundStyle(color(entry.level))
                                Spacer()
                                Text(Format.time.string(from: entry.t)).font(.caption2.monospacedDigit())
                            }
                            if !entry.data.isEmpty {
                                Text(entry.data.keys.sorted().map { "\($0)=\(entry.data[$0] ?? "")" }.joined(separator: "  "))
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Event log")
            .toolbar {
                ShareButton(url: logger.exportFile())
            }
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}
