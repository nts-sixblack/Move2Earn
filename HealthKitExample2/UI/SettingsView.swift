//
//  SettingsView.swift
//  HealthKitExample2
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var config: ConfigStore
    private var env: AppEnvironment { .shared }
    @State private var integrity: IntegritySnapshot?
    @State private var confirmWipe = false

    var body: some View {
        NavigationView {
            List {
                Section("Cấu hình") {
                    NavigationLink("Reward & anti-cheat config (v\(config.config.version))", destination: ConfigEditorView())
                    NavigationLink("Scenario Lab — kiểm thử gian lận", destination: ScenarioLabView())
                }
                #if DEBUG
                Section {
                    Toggle("Cảm biến replay (debug)", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: SensorMode.replayKey) },
                        set: { UserDefaults.standard.set($0, forKey: SensorMode.replayKey) }))
                } footer: {
                    Text("Dùng cho Simulator (không có pedometer). Có hiệu lực sau khi mở lại app. Report bị gắn cờ replaySensors.")
                }
                #endif
                Section("Thiết bị") {
                    InfoRow("Install ID", value: String(DeviceIdentity.installId.prefix(8)))
                    InfoRow("Signing key", value: DeviceIdentity.keyId)
                    InfoRow("Model", value: DeviceIdentity.deviceModel)
                    InfoRow("OS", value: DeviceIdentity.osVersion)
                    InfoRow("App", value: DeviceIdentity.appVersion)
                }
                if let i = integrity {
                    Section("Integrity") {
                        InfoRow("Simulator", value: i.isSimulator ? "Có" : "Không")
                        InfoRow("Jailbreak", value: i.isJailbroken ? i.jailbreakSignals.joined(separator: ", ") : "Không")
                        InfoRow("Debugger", value: i.debuggerAttached ? "Đang gắn" : "Không")
                        InfoRow("Hook libraries", value: i.suspiciousLibraries.isEmpty ? "Không" : i.suspiciousLibraries.joined(separator: ", "))
                        InfoRow("App Attest", value: i.appAttestSupported ? "Hỗ trợ" : "Không")
                        InfoRow("Low Power Mode", value: i.lowPowerMode ? "Bật" : "Tắt")
                        InfoRow("Vị trí chính xác", value: (i.preciseLocation ?? false) ? "Có" : "Không")
                    }
                }
                Section("Mock server") {
                    InfoRow("Số dư", value: Format.coins(env.server.currentBalance))
                    InfoRow("Report đã xử lý", value: "\(env.server.state.receipts.count)")
                    InfoRow("Outbox chờ gửi", value: "\(sync.pendingCount)")
                    if let last = sync.lastSyncAt {
                        InfoRow("Sync gần nhất", value: Format.time.string(from: last))
                    }
                }
                Section {
                    if session.isActive {
                        Button("Huỷ phiên đang chạy (không gửi)", role: .destructive) { session.discard() }
                    }
                    Button("Xoá toàn bộ dữ liệu local + mock server", role: .destructive) { confirmWipe = true }
                }
            }
            .navigationTitle("Cài đặt")
            .task { integrity = DeviceIntegrity.snapshot(preciseLocation: env.location.preciseLocation) }
            .confirmationDialog("Xoá toàn bộ lịch sử, ví và outbox?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Xoá", role: .destructive) { env.wipeAll() }
            }
        }
    }
}

struct ScenarioLabView: View {
    @State private var results: [ScenarioResult] = []

    var body: some View {
        List {
            Section {
                Button("Chạy tất cả kịch bản") { results = ScenarioRunner().runAll() }
                if !results.isEmpty {
                    let passed = results.filter(\.passed).count
                    Text("\(passed)/\(results.count) kịch bản cho kết quả đúng như kỳ vọng")
                        .foregroundStyle(passed == results.count ? .green : .red)
                }
            } footer: {
                Text("Mỗi kịch bản tạo dữ liệu cảm biến tổng hợp, ký HMAC và gửi qua một mock server riêng (không ảnh hưởng ví thật).")
            }
            ForEach(results) { result in
                NavigationLink(destination:
                    List {
                        Section("Kết quả") {
                            InfoRow("Trạng thái", value: result.receipt.status.rawValue)
                            InfoRow("Coin", value: Format.coins(result.receipt.coins))
                            Text(result.note).font(.caption)
                        }
                        Section("Cờ") {
                            ForEach(Array(Set(result.receipt.allFlags)).sorted { $0.id < $1.id }) { FlagRow(flag: $0) }
                        }
                    }
                    .navigationTitle(result.scenario.title)
                ) {
                    HStack {
                        Image(systemName: result.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(result.passed ? .green : .red)
                        VStack(alignment: .leading) {
                            Text(result.scenario.title)
                            Text(result.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(Format.coins(result.receipt.coins)).font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .navigationTitle("Scenario Lab")
    }
}
