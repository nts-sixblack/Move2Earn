//
//  PassiveSyncView.swift
//  HealthKitExample2
//
//  Dedicated screen for Trường hợp 2: Passive Background HealthKit Sync.
//  Displays all synced records from `passive_records.json`, filter details,
//  server submission timestamps, roundtrip latency, and manual/simulation test triggers.
//

import SwiftUI

struct PassiveSyncView: View {
    @EnvironmentObject private var passiveSync: PassiveSyncService
    @State private var selectedRecord: PassiveSyncRecord?
    @State private var showingClearAlert = false
    @State private var showingLldbHelp = false
    @State private var hasHealthAuth = true

    var body: some View {
        NavigationView {
            List {
                conceptBanner
                if !hasHealthAuth {
                    permissionBanner
                }
                metricsSection
                triggerControlsSection
                lldbHelpSection
                recordsListSection
            }
            .navigationTitle("Passive HealthKit")
            .task {
                hasHealthAuth = await HealthKitProvider.shared.hasRequestedAuthorization()
            }
            .refreshable {
                await passiveSync.sync(trigger: .manualTest)
                hasHealthAuth = await HealthKitProvider.shared.hasRequestedAuthorization()
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if let url = prepareExportURL() {
                        ShareButton(url: url)
                    }
                    Button(role: .destructive) {
                        showingClearAlert = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Xoá logs")
                }
            }
            .alert("Xoá toàn bộ log passive sync?", isPresented: $showingClearAlert) {
                Button("Xoá", role: .destructive) { passiveSync.clearLogs() }
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("File `passive_records.json` sẽ được làm sạch.")
            }
            .sheet(item: $selectedRecord) { record in
                PassiveRecordDetailSheet(record: record)
            }
        }
    }

    // MARK: - Subviews

    private var conceptBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "leaf.fill").foregroundStyle(.green)
                    Text("Trường hợp 2: Passive HealthKit Sync").font(.subheadline.weight(.semibold))
                }
                Text("Không bật GPS, không cần Start session. Dữ liệu lấy từ HealthKit của chip Apple, "
                     + "tự động đánh thức qua Background Delivery / BGTasks, lọc bỏ 100% bước nhập tay & app bên thứ 3, "
                     + "sau đó gửi lên server kèm timestamp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var permissionBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Chưa cấp quyền Apple Health").font(.subheadline.weight(.semibold))
                }
                Text("App cần quyền đọc 'Số bước' để kiểm tra bước chân từ chip thiết bị. Hãy bấm nút dưới đây để cấp quyền.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    Task {
                        await passiveSync.requestHealthKitPermission()
                        hasHealthAuth = await HealthKitProvider.shared.hasRequestedAuthorization()
                    }
                } label: {
                    Text("Cấp quyền đọc Apple Health ngay")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    private var metricsSection: some View {
        Section("Thống kê hôm nay") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(title: "Bước máy hôm nay", value: "\(passiveSync.todayDeviceSteps)", systemImage: "applelogo")
                StatTile(title: "Bước rác bị lọc",
                         value: "\(passiveSync.todayManualStepsFiltered + passiveSync.todayThirdPartyStepsFiltered)",
                         systemImage: "xmark.bin")
                StatTile(title: "Tổng bản ghi", value: "\(passiveSync.records.count)", systemImage: "doc.text")
                StatTile(title: "Lần sync cuối",
                         value: passiveSync.lastSyncDate.map { Format.time.string(from: $0) } ?? "--:--",
                         systemImage: "clock")
            }
            .padding(.vertical, 4)

            if let msg = passiveSync.lastStatusMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var triggerControlsSection: some View {
        Section("Kiểm thử & Kích hoạt") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Phạm vi quét HealthKit:").font(.caption).foregroundStyle(.secondary)
                Picker("Phạm vi", selection: $passiveSync.selectedScope) {
                    ForEach(QueryWindowScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 2)

            Button {
                Task {
                    await passiveSync.sync(trigger: .manualTest)
                    hasHealthAuth = await HealthKitProvider.shared.hasRequestedAuthorization()
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Đồng bộ HealthKit ngay")
                    Spacer()
                    if passiveSync.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(passiveSync.isSyncing)

            Menu {
                Button {
                    Task { await passiveSync.sync(trigger: .bgAppRefresh) }
                } label: {
                    Label("Giả lập BGAppRefreshTask", systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    Task { await passiveSync.sync(trigger: .bgProcessing) }
                } label: {
                    Label("Giả lập BGProcessingTask", systemImage: "gearshape.2")
                }

                Button {
                    Task { await passiveSync.sync(trigger: .healthKitWake) }
                } label: {
                    Label("Giả lập HealthKit Background Delivery", systemImage: "heart.fill")
                }

                Divider()

                Button {
                    Task {
                        await passiveSync.simulateScenario(
                            trigger: .simulated,
                            deviceSteps: 450,
                            manualSteps: 200,
                            thirdPartySteps: 1200,
                            thirdPartyName: "FakeStepsApp"
                        )
                    }
                } label: {
                    Label("Test phát hiện cheat (450 máy, 200 nhập tay, 1200 app ngoài)", systemImage: "shield.lefthalf.filled.triangle")
                }
            } label: {
                HStack {
                    Image(systemName: "play.circle")
                    Text("Menu giả lập kịch bản test...")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var lldbHelpSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showingLldbHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Để test Background Task thật từ Xcode, cắm máy hoặc chạy Simulator, bấm Pause Execution (⏸) trong Xcode debugger, sau đó dán một trong hai lệnh sau vào console:")
                        .font(.caption).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Test BGAppRefreshTask:").font(.caption.weight(.semibold))
                        Text("e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@\"com.sixpilot.HealthKitExample.refresh\"]")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(6)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("2. Test BGProcessingTask:").font(.caption.weight(.semibold))
                        Text("e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@\"com.sixpilot.HealthKitExample.processing\"]")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(6)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Text("Sau đó bấm Resume (▶️) để iOS kích hoạt task ngay lập tức.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } label: {
                HStack {
                    Image(systemName: "terminal.fill").foregroundStyle(.blue)
                    Text("Lệnh LLDB test chạy nền Xcode")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
    }

    private var recordsListSection: some View {
        Section("Bản ghi trong file (\(passiveSync.records.count))") {
            if passiveSync.records.isEmpty {
                EmptyStateView(
                    title: "Chưa có bản ghi nào",
                    systemImage: "heart.text.square",
                    message: "Nhấn 'Đồng bộ HealthKit ngay' hoặc dùng menu giả lập để bắt đầu ghi log."
                )
            } else {
                ForEach(passiveSync.records) { record in
                    Button {
                        selectedRecord = record
                    } label: {
                        recordRow(record)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func recordRow(_ record: PassiveSyncRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                triggerBadge(record.trigger)
                Text(record.queryScope)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Format.time.string(from: record.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("+\(record.deviceSteps) bước mới")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if record.cumulativeStepsToday > 0 {
                    Text("(Hôm nay: \(record.cumulativeStepsToday))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if record.rejectedSteps > 0 {
                    Text("(Loại: \(record.rejectedSteps))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                serverStatusBadge(record.serverStatus)
            }

            if let note = record.notes, record.deviceSteps == 0 {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack {
                Text("Khoảng: \(Format.time.string(from: record.queryStart)) → \(Format.time.string(from: record.queryEnd))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let receipt = record.serverReceipt {
                    Text(String(format: "Latency: %.0fms", receipt.latencyMs))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func triggerBadge(_ trigger: PassiveTriggerSource) -> some View {
        HStack(spacing: 4) {
            Image(systemName: trigger.icon)
            Text(trigger.shortTag)
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(triggerColor(trigger).opacity(0.18), in: Capsule())
        .foregroundStyle(triggerColor(trigger))
    }

    private func triggerColor(_ trigger: PassiveTriggerSource) -> Color {
        switch trigger {
        case .healthKitWake: .red
        case .bgAppRefresh: .blue
        case .bgProcessing: .purple
        case .foreground: .teal
        case .manualTest: .orange
        case .simulated: .green
        }
    }

    private func serverStatusBadge(_ status: PassiveServerStatus) -> some View {
        HStack(spacing: 3) {
            Image(systemName: status.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            Text(status.statusTitle)
        }
        .font(.caption2)
        .foregroundStyle(status.isSuccess ? .green : .red)
    }

    private func prepareExportURL() -> URL? {
        let json = passiveSync.exportJSONString()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("passive_records_export.json")
        try? json.data(using: .utf8)?.write(to: url)
        return url
    }
}

// MARK: - Detail Sheet

private struct PassiveRecordDetailSheet: View {
    var record: PassiveSyncRecord
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationView {
            List {
                Section("Thông tin cơ bản") {
                    InfoRow("Mã bản ghi", value: record.id.uuidString.prefix(8) + "...")
                    InfoRow("Thời gian ghi log", value: Format.dateTime.string(from: record.timestamp))
                    InfoRow("Nguồn kích hoạt", value: record.trigger.displayName)
                    InfoRow("Phạm vi quét", value: record.queryScope)
                    InfoRow("Khoảng bắt đầu", value: Format.dateTime.string(from: record.queryStart))
                    InfoRow("Khoảng kết thúc", value: Format.dateTime.string(from: record.queryEnd))
                }

                Section("Phân loại bước chân") {
                    InfoRow("Bước phần cứng mới", value: "\(record.deviceSteps)")
                    InfoRow(" • iPhone", value: "\(record.iPhoneSteps)")
                    InfoRow(" • Apple Watch", value: "\(record.watchSteps)")
                    InfoRow("Tổng tích luỹ trong phạm vi", value: "\(record.cumulativeStepsToday)")
                    InfoRow("Bước nhập tay (Bị loại)", value: "\(record.manualSteps)")
                    InfoRow("Bước App thứ 3 (Bị loại)", value: "\(record.thirdPartySteps)")
                    if !record.thirdPartySources.isEmpty {
                        InfoRow("Nguồn app bên thứ 3", value: record.thirdPartySources.joined(separator: ", "))
                    }
                    InfoRow("Số mẫu HealthKit", value: "\(record.sampleCount)")
                    if record.rawHealthKitTotalSteps > 0 {
                        InfoRow("HealthKit DB Statistics", value: "\(record.rawHealthKitTotalSteps) bước")
                    }
                }

                Section("Thông tin gửi Server") {
                    InfoRow("Trạng thái", value: record.serverStatus.statusTitle)
                    if let sent = record.clientSentAt {
                        InfoRow("Client gửi lúc", value: Format.time.string(from: sent))
                    }
                    if let receipt = record.serverReceipt {
                        InfoRow("Server nhận lúc", value: Format.time.string(from: receipt.serverReceivedAt))
                        InfoRow("Độ trễ khứ hồi", value: String(format: "%.1f ms", receipt.latencyMs))
                        InfoRow("Ghi chú Server", value: receipt.serverNote)
                    }
                }

                if let note = record.notes {
                    Section("Ghi chú & Chẩn đoán") {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !record.samples.isEmpty {
                    Section("Danh sách mẫu chi tiết (\(record.samples.count))") {
                        ForEach(record.samples) { sample in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(sample.steps) bước").font(.subheadline.weight(.semibold))
                                    Spacer()
                                    sampleTypeBadge(sample)
                                }
                                Text("Nguồn: \(sample.sourceName) (\(sample.sourceBundle))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let model = sample.deviceModel, !model.isEmpty {
                                    Text("Thiết bị: \(model)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Text("Thời gian: \(Format.time.string(from: sample.startDate)) → \(Format.time.string(from: sample.endDate))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Raw JSON") {
                    if let json = recordJSON {
                        Text(json)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = json
                            copied = true
                        } label: {
                            Label(copied ? "Đã copy!" : "Copy JSON", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
            }
            .navigationTitle("Chi tiết bản ghi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }

    private func sampleTypeBadge(_ sample: PassiveSampleItem) -> some View {
        let (title, color): (String, Color) = {
            if sample.isUserEntered { return ("Nhập tay", .red) }
            if sample.isDeviceHardware { return ("Apple Device", .green) }
            return ("App ngoài", .orange)
        }()

        return Text(title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var recordJSON: String? {
        guard let data = try? FileStore.prettyEncoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
