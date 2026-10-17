//
//  MoveView.swift
//  HealthKitExample2
//

import CoreMotion
import SwiftUI

struct MoveView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var wallet: WalletStore
    @EnvironmentObject private var sync: SyncService
    @EnvironmentObject private var config: ConfigStore
    private var env: AppEnvironment { .shared }
    @StateObject private var permissions = PermissionCenter()
    @State private var locationAuth: LocationAuth = .notDetermined

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    walletCard
                    permissionCard
                    if let session = session.session {
                        activeCard(session)
                    } else {
                        startCard
                    }
                }
                .padding()
            }
            .navigationTitle("Move to Earn")
            .task {
                await permissions.refresh()
                locationAuth = env.location.authorization
                await wallet.refresh()
            }
            .refreshable {
                await sync.syncPending()
                await permissions.refresh()
                locationAuth = env.location.authorization
            }
        }
    }

    // MARK: Wallet

    private var walletCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Số dư (server)").font(.caption).foregroundStyle(.secondary)
            Text(Format.coins(wallet.balance) + " coin").font(.largeTitle.weight(.bold).monospacedDigit())
            HStack {
                Text("Hôm nay: \(Format.coins(wallet.todayCoins())) / \(Format.coins(config.config.limits.dailyCoinCap))")
                Spacer()
                if sync.isSyncing {
                    ProgressView().controlSize(.small)
                } else if sync.pendingCount > 0 {
                    Button("Gửi lại \(sync.pendingCount)") { Task { await sync.syncPending() } }
                        .font(.caption)
                }
            }
            .font(.footnote)
            if let error = sync.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Permissions

    @ViewBuilder
    private var permissionCard: some View {
        let motionOK = permissions.motion == .authorized
        let locationOK = locationAuth == .always
        if !motionOK || !locationOK || !permissions.healthRequested {
            VStack(alignment: .leading, spacing: 10) {
                Text("Quyền truy cập").font(.headline)
                permissionRow("Chuyển động & thể chất", ok: motionOK, detail: "Nguồn đếm bước chính (CMPedometer)") {
                    Task { await permissions.requestMotion() }
                }
                permissionRow("Vị trí: \(locationAuth.rawValue)", ok: locationOK,
                              detail: "\"Luôn luôn\" để tiếp tục tracking & khôi phục khi app bị kill") {
                    if locationAuth == .notDetermined { env.location.requestWhenInUse() } else { env.location.requestAlways() }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        locationAuth = env.location.authorization
                    }
                }
                permissionRow("Apple Health", ok: permissions.healthRequested,
                              detail: "Đối chiếu & đánh thức app ở background") {
                    Task { await permissions.requestHealth() }
                }
            }
            .padding()
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func permissionRow(_ title: String, ok: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Cấp", action: action).buttonStyle(.bordered).controlSize(.small) }
        }
    }

    // MARK: Session

    private var startCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.walk").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Bắt đầu một phiên di chuyển. App tiếp tục tracking ở background; nếu bị kill, dữ liệu bước được khôi phục từ CoreMotion khi mở lại.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                Task {
                    // Ask for Motion first: CoreMotion queries made before the prompt is
                    // answered return errors, and those epochs would record 0 steps.
                    if permissions.motion == .notDetermined { await permissions.requestMotion() }
                    guard permissions.motion != .denied, permissions.motion != .restricted else {
                        session.message = "Cần quyền Chuyển động & thể chất để đếm bước."
                        return
                    }
                    if locationAuth == .notDetermined { env.location.requestWhenInUse() }
                    session.message = nil
                    await session.start()
                }
            } label: {
                Label("Bắt đầu", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let message = session.message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
    }

    private func activeCard(_ s: ActiveSession) -> some View {
        let result = session.liveVerification
        let warnings = result?.allFlags.filter { $0.severity != .info } ?? []
        let live = s.epochs.filter { $0.source == .live }.count
        return VStack(spacing: 12) {
            TimelineView(.periodic(from: s.startedAt, by: 1)) { context in
                Text(Format.duration(context.date.timeIntervalSince(s.startedAt)))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(title: "Bước", value: "\(session.liveSteps)", systemImage: "figure.walk")
                StatTile(title: "Quãng đường GPS", value: Format.meters(s.routeDistance), systemImage: "location.fill")
                StatTile(title: "Pedometer", value: Format.meters(session.livePedometerDistance ?? 0), systemImage: "ruler")
                StatTile(title: "Hoạt động", value: session.currentActivity?.kind.rawValue ?? "-", systemImage: "figure.run")
                StatTile(title: "GPS ±", value: session.lastLocation.map { String(format: "%.0f m", $0.hAcc) } ?? "-",
                         systemImage: "scope")
                StatTile(title: "Epoch live/khôi phục", value: "\(live)/\(s.epochs.count - live)", systemImage: "square.stack.3d.up")
                StatTile(title: "Ước tính", value: Format.coins(session.liveEstimate.coins), systemImage: "bitcoinsign.circle")
                StatTile(title: "App relaunch", value: "\(s.relaunchCount)", systemImage: "arrow.clockwise")
            }
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cảnh báo xác minh").font(.headline)
                    ForEach(Array(Set(warnings)).sorted { $0.id < $1.id }.suffix(6)) { FlagRow(flag: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Số coin cuối cùng do server quyết định sau khi xác minh lại.")
                .font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) {
                Task { await session.stop() }
            } label: {
                Label(session.isBusy ? "Đang kết thúc…" : "Kết thúc", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.isBusy)
        }
    }
}
