//
//  HistoryView.swift
//  HealthKitExample2
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var history: HistoryStore
    private var env: AppEnvironment { .shared }

    var body: some View {
        NavigationView {
            List {
                if history.records.isEmpty {
                    EmptyStateView(title: "Chưa có phiên nào", systemImage: "figure.walk", message: "Các phiên đã kết thúc sẽ hiển thị ở đây.")
                }
                ForEach(history.records) { record in
                    NavigationLink(destination: SessionDetailView(id: record.id)) { row(record) }
                }
            }
            .navigationTitle("Lịch sử")
            .refreshable { await sync.syncPending() }
        }
    }

    private func row(_ r: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Format.dateTime.string(from: r.startedAt)).font(.subheadline.weight(.medium))
                Spacer()
                StatusBadge(status: r.status)
            }
            HStack {
                Text("\(r.steps) bước · \(Format.meters(r.distance)) · \(Format.duration(r.endedAt.timeIntervalSince(r.startedAt)))")
                Spacer()
                Text((r.receipt.map { Format.coins($0.coins) } ?? "~" + Format.coins(r.estimate)) + " coin")
                    .monospacedDigit()
            }
            .font(.caption)
            if !r.localFlags.isEmpty || r.recoveredEpochs > 0 {
                Text((r.recoveredEpochs > 0 ? ["\(r.recoveredEpochs) epoch khôi phục"] : []) + r.localFlags.map(\.rawValue))
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }
}

private extension Text {
    init(_ parts: [String]) { self.init(parts.joined(separator: " · ")) }
}

struct SessionDetailView: View {
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var history: HistoryStore
    private var env: AppEnvironment { .shared }
    var id: UUID
    @State private var report: SessionReport?

    var body: some View {
        let record = history.record(id)
        let receipt = record?.receipt
        List {
            if let record {
                Section("Tóm tắt") {
                    InfoRow("Trạng thái") { StatusBadge(status: record.status) }
                    InfoRow("Coin", value: receipt.map { Format.coins($0.coins) } ?? "~" + Format.coins(record.estimate))
                    InfoRow("Lý do kết thúc", value: record.endReason.rawValue)
                    InfoRow("Bước", value: "\(record.steps)")
                    InfoRow("Epoch", value: "\(record.epochCount) (\(record.recoveredEpochs) khôi phục)")
                    InfoRow("App relaunch", value: "\(record.relaunches)")
                    if let reason = receipt?.reason { Text(reason).font(.caption).foregroundStyle(.red) }
                    if let error = record.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                    if record.status == .pending {
                        Button("Gửi lại lên server") { Task { await sync.syncPending() } }
                    }
                }
            }
            if let b = receipt?.breakdown {
                Section("Chi tiết tính coin (server)") {
                    InfoRow("Bước được thưởng", value: "\(b.rewardedSteps) / \(b.totalSteps)")
                    InfoRow("Quãng đường xác minh", value: Format.meters(b.verifiedDistance))
                    InfoRow("Coin từ bước", value: Format.coins(b.stepCoins))
                    InfoRow("Coin từ quãng đường", value: Format.coins(b.distanceCoins))
                    InfoRow("Tổng trước giới hạn", value: Format.coins(b.grossCoins))
                    InfoRow("Epoch hợp lệ", value: "\(b.validEpochs) / \(b.validEpochs + b.invalidEpochs)")
                    if !b.cappedBy.isEmpty { InfoRow("Bị giới hạn", value: b.cappedBy.map(\.rawValue).joined(separator: ", ")) }
                }
            }
            if let receipt, !(receipt.serverFlags + receipt.verification.sessionFlags).isEmpty {
                Section("Cờ cấp session") {
                    ForEach(receipt.serverFlags + receipt.verification.sessionFlags) { FlagRow(flag: $0) }
                }
            }
            if let report {
                Section("Epoch (\(report.epochs.count))") {
                    ForEach(report.epochs) { epoch in
                        EpochRow(epoch: epoch, verdict: receipt?.verification.verdicts.first { $0.index == epoch.index },
                                 coins: receipt?.breakdown.perEpoch.first { $0.index == epoch.index }?.coins)
                    }
                }
                Section("Thiết bị") {
                    InfoRow("Model", value: report.deviceModel)
                    InfoRow("OS", value: report.osVersion)
                    InfoRow("App", value: report.appVersion)
                    InfoRow("Jailbreak", value: report.integrity.isJailbroken ? "Có" : "Không")
                    InfoRow("Simulator", value: report.integrity.isSimulator ? "Có" : "Không")
                    InfoRow("Log entries", value: "\(report.events.count)")
                    if let hk = report.healthKit {
                        InfoRow("HealthKit iPhone/Watch", value: "\(hk.iPhoneSteps) / \(hk.watchSteps)")
                        InfoRow("HealthKit thủ công/3rd", value: "\(hk.manualSteps) / \(hk.thirdPartySteps)")
                    }
                }
            }
        }
        .navigationTitle("Chi tiết phiên")
        .toolbar {
            ShareButton(url: history.reportFileURL(id))
        }
        .task { report = history.report(id) }
    }
}

struct EpochRow: View {
    var epoch: Epoch
    var verdict: EpochVerdict?
    var coins: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: verdict.map { $0.valid ? "checkmark.circle.fill" : "xmark.circle.fill" } ?? "circle")
                    .foregroundStyle(verdict.map { $0.valid ? Color.green : .red } ?? .secondary)
                Text("#\(epoch.index) \(Format.time.string(from: epoch.start))").font(.subheadline.monospacedDigit())
                Text(epoch.source.rawValue).font(.caption2)
                    .padding(.horizontal, 5).background(Color(.tertiarySystemFill), in: Capsule())
                Spacer()
                if let coins { Text(Format.coins(coins)).font(.caption.monospacedDigit()) }
            }
            Text(String(format: "%d bước · %.0f spm · GPS %d điểm %.0fm · %@ · trust %.2f",
                        epoch.steps, epoch.cadence, epoch.gpsPoints, epoch.gpsDistance,
                        epoch.dominantActivity.rawValue, verdict?.trust ?? 0))
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(verdict?.flags.filter { $0.severity != .info } ?? []) { FlagRow(flag: $0) }
        }
    }
}
