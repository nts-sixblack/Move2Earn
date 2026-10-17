//
//  ConfigEditorView.swift
//  HealthKitExample2
//

import SwiftUI

struct ConfigEditorView: View {
    @EnvironmentObject private var config: ConfigStore
    private var env: AppEnvironment { .shared }
    @State private var draft = RewardConfig.default
    @State private var json = ""
    @State private var showJSON = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Phần thưởng") {
                number("Coin / 1000 bước (đi bộ)", $draft.reward.coinsPer1000StepsWalking)
                number("Coin / 1000 bước (chạy)", $draft.reward.coinsPer1000StepsRunning)
                number("Coin / km GPS xác minh", $draft.reward.coinsPerVerifiedKm)
                number("Hệ số epoch khôi phục", $draft.reward.recoveredMultiplier)
                number("Hệ số không có GPS", $draft.reward.noGpsMultiplier)
                integer("Số bước tối thiểu / epoch", $draft.reward.minEpochSteps)
                number("Trust tối thiểu để thưởng", $draft.reward.minTrustToReward)
            }
            Section("Giới hạn") {
                number("Coin tối đa / ngày", $draft.limits.dailyCoinCap)
                integer("Bước tối đa / ngày", $draft.limits.dailyStepCap)
                integer("Số phiên tối đa / ngày", $draft.limits.maxSessionsPerDay)
                number("Thời lượng tối thiểu (s)", $draft.limits.sessionMinSeconds)
                number("Thời lượng tối đa (s)", $draft.limits.sessionMaxSeconds)
                number("Khoảng khôi phục tối đa (s)", $draft.limits.maxRecoveryGapSeconds)
                number("Tự kết thúc khi đứng yên (phút)", $draft.limits.autoEndIdleMinutes)
            }
            Section("Anti-cheat") {
                number("Tốc độ xe (m/s, TB epoch)", $draft.rules.vehicleSpeedMps)
                number("Tốc độ tức thời tối đa (m/s)", $draft.rules.maxInstantSpeedMps)
                number("Tốc độ teleport (m/s)", $draft.rules.teleportSpeedMps)
                number("Cadence tối đa (bước/phút)", $draft.rules.cadenceMax)
                number("Sải chân min (m)", $draft.rules.strideMin)
                number("Sải chân max (m)", $draft.rules.strideMax)
                number("Tỉ lệ lệch GPS/pedometer", $draft.rules.gpsPedometerMismatchRatio)
                number("CV nhịp bước 'máy móc'", $draft.rules.roboticRhythmCV)
                number("Tỉ lệ automotive để loại", $draft.rules.automotiveFractionReject)
                number("Tỉ lệ cycling để loại", $draft.rules.cyclingFractionReject)
                number("Dung sai đồng hồ (s)", $draft.rules.clockToleranceSeconds)
                number("Phạt trust / cảnh báo", $draft.rules.warningPenalty)
                Toggle("Loại khi fake GPS", isOn: $draft.rules.rejectSimulatedLocation)
                Toggle("Huỷ cả phiên khi spoof GPS", isOn: $draft.rules.rejectSessionOnSpoofing)
                Toggle("Loại khi chỉnh giờ", isOn: $draft.rules.rejectOnClockTamper)
                Toggle("Loại thiết bị jailbreak", isOn: $draft.rules.rejectJailbreak)
                Toggle("Loại khi có hook library", isOn: $draft.rules.rejectHookingLibraries)
                Toggle("Loại khi gắn debugger", isOn: $draft.rules.rejectDebugger)
                Toggle("Loại khi chạy simulator", isOn: $draft.rules.rejectSimulator)
            }
            Section("Tracking") {
                number("Độ dài epoch (s)", $draft.tracking.epochSeconds)
                number("Chu kỳ checkpoint (s)", $draft.tracking.checkpointSeconds)
                number("Heartbeat (s)", $draft.tracking.heartbeatSeconds)
                number("Độ chính xác GPS tối đa (m)", $draft.tracking.gpsMaxAccuracy)
                number("Tần số accelerometer (Hz)", $draft.tracking.motionSampleHz)
            }
            Section("Mock server") {
                integer("Độ trễ (ms)", $draft.mockServer.latencyMs)
                number("Tỉ lệ lỗi mạng (0-1)", $draft.mockServer.failureRate)
            }
            Section {
                Button("Lưu") {
                    config.update(draft)
                    draft = config.config
                }
                Button("Khôi phục mặc định", role: .destructive) {
                    config.reset()
                    draft = config.config
                }
                Button("Sửa dạng JSON") {
                    json = config.exportJSON()
                    showJSON = true
                }
            }
        }
        .navigationTitle("Config v\(config.config.version)")
        .onAppear { draft = config.config }
        .sheet(isPresented: $showJSON) {
            NavigationView {
                TextEditor(text: $json)
                    .font(.caption.monospaced())
                    .padding(.horizontal)
                    .navigationTitle("config.json")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Đóng") { showJSON = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Áp dụng") {
                                do {
                                    try config.importJSON(json)
                                    draft = config.config
                                    showJSON = false
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                    }
                    .alert("JSON không hợp lệ", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                        Button("OK") { error = nil }
                    } message: { Text(error ?? "") }
            }
        }
    }

    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        InfoRow(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
        }
    }

    private func integer(_ title: String, _ value: Binding<Int>) -> some View {
        InfoRow(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
        }
    }
}
