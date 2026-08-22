import BirthdayCore
import SwiftUI

struct SyncSettingsView: View {
  @Bindable var model: AppModel

  @State private var isPresentingBinding = false
  @State private var revokeTarget: ManagedDevice?
  @State private var typedUsername = ""
  @State private var isConfirmingStop = false
  @State private var isConfirmingLocalStop = false

  var body: some View {
    Group {
      Section {
        statusCard
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)

        if !model.conflicts.isEmpty {
          Button {
            model.selectedTab = .conflicts
          } label: {
            Label("查看并解决冲突", systemImage: "arrow.triangle.branch")
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }
          .accessibilityIdentifier("openSyncConflictsButton")
        }

        if showsBindingAction {
          Button {
            isPresentingBinding = true
          } label: {
            Label("绑定服务器", systemImage: "link.badge.plus")
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }
          .accessibilityIdentifier("bindFromSettingsButton")
        } else {
          Button {
            Task { await model.requestSync(.manual) }
          } label: {
            HStack(spacing: 10) {
              if model.isManualSyncing {
                ProgressView()
                  .accessibilityHidden(true)
              } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                  .accessibilityHidden(true)
              }
              Text(model.isManualSyncing ? "正在同步" : "立即同步")
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }
          .disabled(model.isManualSyncing || model.isManagingDevice)
          .accessibilityIdentifier("manualSyncButton")
        }
      } header: {
        Text("同步")
      } footer: {
        Text("本地提醒独立运行；服务器同步失败、暂停或停止时，已保存的生日仍保留在本机。")
      }

      if !model.managedDevices.isEmpty || model.isLoadingManagedDevices {
        Section("已绑定设备") {
          if model.isLoadingManagedDevices, model.managedDevices.isEmpty {
            HStack(spacing: 10) {
              ProgressView()
              Text("正在读取设备列表")
                .foregroundStyle(ModernAirTheme.secondaryInk)
            }
            .frame(minHeight: 44)
          }

          ForEach(model.managedDevices, id: \.device.deviceId) { managed in
            deviceRow(managed)
          }
        }
      }

      if showsStopSync {
        Section {
          if let message = model.deviceManagementMessage {
            Label(message, systemImage: "exclamationmark.shield.fill")
              .font(.footnote)
              .foregroundStyle(ModernAirTheme.ink)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("deviceManagementMessage")
          }

          if isRevokedCredentialCleanupRequired {
            Button {
              Task { _ = await model.confirmLocalStopSync() }
            } label: {
              Label("重试清理本机凭据", systemImage: "key.slash")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(deviceActionsDisabled)
            .accessibilityIdentifier("retryCredentialCleanupButton")
          } else {
            Button(role: .destructive) {
              isConfirmingStop = true
            } label: {
              Label("停止同步", systemImage: "icloud.slash")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(deviceActionsDisabled)
            .accessibilityIdentifier("stopSyncButton")
          }
        } header: {
          Text("同步边界")
        } footer: {
          Text("停止同步只撤销设备并清除同步凭据，不会删除本机生日、待同步修改、冲突或同步元数据。")
        }
      }
    }
    .task {
      await model.refreshSyncSettings()
    }
    .refreshable {
      await model.refreshSyncSettings()
    }
    .sheet(isPresented: $isPresentingBinding) {
      NavigationStack {
        ScrollView {
          ServerBindingView(
            model: model,
            presentsSnapshotPreview: false,
            onSkip: { isPresentingBinding = false },
            onBound: {
              isPresentingBinding = false
              Task { await model.refreshSyncSettings() }
            }
          )
          .padding(20)
        }
        .background(ModernAirTheme.mist.ignoresSafeArea())
        .navigationTitle("绑定服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { isPresentingBinding = false }
          }
        }
      }
    }
    .sheet(item: $revokeTarget) { managed in
      RevokeDeviceConfirmationView(
        deviceName: managed.device.deviceName,
        typedUsername: $typedUsername,
        isWorking: model.isManagingDevice,
        message: model.deviceManagementMessage,
        onCancel: { dismissRevokeConfirmation() },
        onConfirm: {
          Task {
            if await model.revokeManagedDevice(managed.device, typedUsername: typedUsername) {
              dismissRevokeConfirmation()
            }
          }
        }
      )
      .presentationDetents([.medium])
      .interactiveDismissDisabled(deviceActionsDisabled)
    }
    .alert("停止本机同步？", isPresented: $isConfirmingStop) {
      Button("取消", role: .cancel) {}
      Button("撤销此设备并停止", role: .destructive) {
        Task {
          if case .needsLocalConfirmation = await model.beginStopSync() {
            isConfirmingLocalStop = true
          }
        }
      }
    } message: {
      Text("将先联系服务器撤销这台设备，再清除本机同步凭据。本机生日资料不会删除。")
    }
    .alert("服务器暂时不可达", isPresented: $isConfirmingLocalStop) {
      Button("保留同步", role: .cancel) {
        Task { await model.cancelPendingLocalStopSync() }
      }
      Button("仍要停止本机同步", role: .destructive) {
        Task { _ = await model.confirmLocalStopSync() }
      }
    } message: {
      Text(DeviceManagementService.localUnlinkWarning)
    }
  }

  private var statusCard: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: statusIcon)
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(statusTint)
        .frame(width: 42, height: 42)
        .background(statusTint.opacity(0.13), in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text(statusTitle)
          .font(.headline)
          .foregroundStyle(ModernAirTheme.ink)
        Text(statusDetail)
          .font(.subheadline)
          .foregroundStyle(ModernAirTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)

        if model.syncPendingCount > 0, !showsBindingAction {
          Label("\(model.syncPendingCount) 项等待同步", systemImage: "clock.arrow.circlepath")
            .font(.caption.weight(.semibold))
            .foregroundStyle(ModernAirTheme.dusk)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ModernAirTheme.glacier, in: Capsule())
        }
      }
      Spacer(minLength: 0)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [ModernAirTheme.surface, ModernAirTheme.glacier.opacity(0.72)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 22, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(ModernAirTheme.outline.opacity(0.7), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("syncStatusCard")
  }

  @ViewBuilder
  private func deviceRow(_ managed: ManagedDevice) -> some View {
    HStack(spacing: 12) {
      Image(systemName: managed.isCurrent ? "iphone.gen3" : "laptopcomputer.and.iphone")
        .foregroundStyle(ModernAirTheme.tide)
        .frame(width: 30)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(managed.device.deviceName)
            .foregroundStyle(ModernAirTheme.ink)
          if managed.isCurrent {
            Text("当前设备")
              .font(.caption2.weight(.bold))
              .foregroundStyle(ModernAirTheme.dusk)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(ModernAirTheme.glacier, in: Capsule())
              .accessibilityIdentifier("currentDeviceBadge")
          }
        }
        Text(lastUsedText(managed.device))
          .font(.caption)
          .foregroundStyle(ModernAirTheme.secondaryInk)
      }
      Spacer(minLength: 8)

      if !managed.isCurrent {
        Button("撤销") {
          typedUsername = ""
          revokeTarget = managed
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(deviceActionsDisabled)
        .accessibilityIdentifier("revokeDeviceButton")
        .accessibilityLabel("撤销设备 \(managed.device.deviceName)")
      }
    }
    .frame(minHeight: 54)
  }

  private var showsBindingAction: Bool {
    switch model.syncPresentation {
    case .localOnly, .rebindRequired:
      true
    default:
      false
    }
  }

  private var showsStopSync: Bool {
    (model.isSyncRuntimeEnabled && model.syncPresentation != .localOnly)
      || isRevokedCredentialCleanupRequired
  }

  private var deviceActionsDisabled: Bool {
    model.isManagingDevice || model.syncPresentation == .syncing
  }

  private var isRevokedCredentialCleanupRequired: Bool {
    model.needsRevokedCredentialCleanup
  }

  private var statusTitle: String {
    switch model.syncPresentation {
    case .localOnly: "仅本地使用"
    case .idle: "同步已连接"
    case .syncing: "正在同步"
    case .offline: "离线使用，稍后同步"
    case .failed: "同步遇到问题"
    case .rebindRequired: "需要重新绑定"
    case .conflicts(let count): "有 \(count) 项同步冲突"
    }
  }

  private var statusDetail: String {
    switch model.syncPresentation {
    case .localOnly:
      "生日与提醒只保存在这台设备上。"
    case .idle(let lastSuccess):
      lastSuccess.map { "上次同步：\($0.formatted(date: .abbreviated, time: .shortened))" }
        ?? "尚无成功同步记录。"
    case .syncing:
      "正在安全合并本机与服务器资料。"
    case .offline(let pendingCount):
      pendingCount == 0 ? "网络恢复后可再次同步。" : "已有 \(pendingCount) 项修改安全保存在本机。"
    case .failed(let message, _):
      message
    case .rebindRequired:
      "需要重新绑定，同步已暂停；本地数据仍可使用。"
    case .conflicts:
      "请选择保留本机版本或使用服务器版本。"
    }
  }

  private var statusIcon: String {
    switch model.syncPresentation {
    case .localOnly: "iphone"
    case .idle: "checkmark.icloud.fill"
    case .syncing: "arrow.triangle.2.circlepath.icloud.fill"
    case .offline: "wifi.slash"
    case .failed: "exclamationmark.icloud.fill"
    case .rebindRequired: "person.crop.circle.badge.exclamationmark"
    case .conflicts: "arrow.triangle.branch"
    }
  }

  private var statusTint: Color {
    switch model.syncPresentation {
    case .failed, .rebindRequired, .conflicts:
      ModernAirTheme.dusk
    default:
      ModernAirTheme.tide
    }
  }

  private func lastUsedText(_ device: MobileDevice) -> String {
    guard let lastUsedAt = device.lastUsedAt else { return "尚无最近活动记录" }
    return "最近活动 \(lastUsedAt.formatted(date: .abbreviated, time: .shortened))"
  }

  private func dismissRevokeConfirmation() {
    typedUsername = ""
    revokeTarget = nil
  }
}

private struct RevokeDeviceConfirmationView: View {
  let deviceName: String
  @Binding var typedUsername: String
  let isWorking: Bool
  let message: String?
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 7) {
        Text("撤销“\(deviceName)”？")
          .font(.title2.bold())
          .foregroundStyle(ModernAirTheme.ink)
        Text("请输入管理员用户名进行确认。大小写与字符必须完全一致。")
          .font(.subheadline)
          .foregroundStyle(ModernAirTheme.secondaryInk)
      }

      TextField("管理员用户名", text: $typedUsername)
        .textContentType(.username)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("revokeUsernameField")

      if let message {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
      }

      HStack(spacing: 12) {
        Button("取消", action: onCancel)
          .buttonStyle(.bordered)
          .disabled(isWorking)
        Button("确认撤销", role: .destructive, action: onConfirm)
          .buttonStyle(.borderedProminent)
          .disabled(isWorking || typedUsername.isEmpty)
          .accessibilityIdentifier("confirmRevokeDeviceButton")
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(24)
    .background(ModernAirTheme.mist.ignoresSafeArea())
  }
}
