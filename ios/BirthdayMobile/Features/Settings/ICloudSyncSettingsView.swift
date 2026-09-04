import BirthdayCore
import SwiftUI

struct ICloudSyncSettingsView: View {
  @Bindable var model: AppModel
  @State private var isConfirmingAccountChange = false

  var body: some View {
    Section {
      Toggle(isOn: enabledBinding) {
        Label {
          VStack(alignment: .leading, spacing: 3) {
            Text("使用 iCloud 同步")
            Text("此开关只保存在“\(model.platformServices.deviceName)”上")
              .font(.caption)
              .foregroundStyle(ModernAirTheme.secondaryInk)
          }
        } icon: {
          Image(systemName: "icloud")
            .foregroundStyle(ModernAirTheme.tide)
        }
      }
      .tint(ModernAirTheme.tide)
      .frame(minHeight: 44)
      .disabled(model.cloudSyncStatus == .syncing)
      .accessibilityIdentifier("icloudSyncToggle")

      Label {
        VStack(alignment: .leading, spacing: 3) {
          Text(statusTitle)
            .foregroundStyle(ModernAirTheme.ink)
          Text(statusDetail)
            .font(.caption)
            .foregroundStyle(ModernAirTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
      } icon: {
        Image(systemName: statusIcon)
          .foregroundStyle(statusTint)
      }
      .frame(minHeight: 44)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("icloudSyncStatus")

      if model.cloudSyncStatus == .accountChangeRequiresConfirmation {
        Label(
          "检测到 iCloud 账号变化。确认后会保留全部本机生日，再与新账号的私有数据安全合并。",
          systemImage: "person.crop.circle.badge.exclamationmark"
        )
        .font(.footnote)
        .foregroundStyle(ModernAirTheme.ink)
        .fixedSize(horizontal: false, vertical: true)

        Button("确认使用新 iCloud 账号") {
          isConfirmingAccountChange = true
        }
        .accessibilityIdentifier("confirmCloudAccountChangeButton")

        Button("保持仅本机使用", role: .destructive) {
          Task { await model.cancelCloudAccountChange() }
        }
        .accessibilityIdentifier("cancelCloudAccountChangeButton")
      } else {
        Button {
          Task { await model.requestCloudSync() }
        } label: {
          HStack(spacing: 9) {
            if model.isManualSyncing {
              ProgressView()
                .accessibilityHidden(true)
            } else {
              Image(systemName: "arrow.triangle.2.circlepath.icloud")
                .accessibilityHidden(true)
            }
            Text(model.isManualSyncing ? "正在刷新" : "立即刷新")
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .disabled(!model.isCloudSyncEnabled || model.cloudSyncStatus == .syncing)
        .accessibilityIdentifier("manualCloudSyncButton")
      }

      if model.hasSyncConflicts {
        Button {
          model.selectedTab = .conflicts
        } label: {
          Label("处理 \(model.syncConflictCount) 项冲突", systemImage: "arrow.triangle.branch")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("openCloudConflictsButton")
      }
    } header: {
      Text("iCloud 同步")
    } footer: {
      Text("生日始终先保存到本机；同步使用你自己的 iCloud 私有数据库。关闭或暂时失败不会影响离线查看和编辑。")
    }
    .confirmationDialog(
      "使用新的 iCloud 账号？",
      isPresented: $isConfirmingAccountChange,
      titleVisibility: .visible
    ) {
      Button("保留本机数据并安全合并") {
        Task { await model.confirmCloudAccountChange() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("不会删除本机生日。旧账号的同步状态会清除，本机资料随后与新账号的私有数据进行首次合并。")
    }
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { model.isCloudSyncEnabled },
      set: { enabled in
        Task { await model.setCloudSyncEnabled(enabled) }
      }
    )
  }

  private var statusTitle: String {
    switch model.cloudSyncStatus {
    case .disabled: "同步已关闭"
    case .unavailable: "iCloud 未登录"
    case .syncing: "正在同步"
    case .pending(let count): "本地有 \(count) 项待同步修改"
    case .synchronized: "已同步"
    case .accountChangeRequiresConfirmation: "需要确认 iCloud 账号变化"
    case .conflicts(let count): "有 \(count) 项需要处理的冲突"
    case .failed(let category): failureTitle(category)
    }
  }

  private var statusDetail: String {
    switch model.cloudSyncStatus {
    case .disabled:
      "当前仅使用本机数据，可随时重新开启。"
    case .unavailable:
      "请先在系统中登录 iCloud；本机功能不受影响。"
    case .syncing:
      "正在合并本机与 iCloud 私有数据。"
    case .pending:
      "修改已安全保存在本机，将在条件允许时继续上传。"
    case .synchronized(let date):
      "最近完成：\(date.formatted(date: .abbreviated, time: .shortened))"
    case .accountChangeRequiresConfirmation:
      "同步已暂停，等待你决定是否与新账号安全合并。"
    case .conflicts:
      "双方版本都已保留，请选择需要使用的内容。"
    case .failed(let category):
      failureDetail(category)
    }
  }

  private var statusIcon: String {
    switch model.cloudSyncStatus {
    case .synchronized: "checkmark.icloud.fill"
    case .syncing: "arrow.triangle.2.circlepath.icloud.fill"
    case .pending: "clock.arrow.circlepath"
    case .disabled: "icloud.slash"
    case .unavailable: "person.crop.circle.badge.exclamationmark"
    case .accountChangeRequiresConfirmation, .conflicts: "exclamationmark.icloud.fill"
    case .failed: "wifi.exclamationmark"
    }
  }

  private var statusTint: Color {
    switch model.cloudSyncStatus {
    case .failed, .accountChangeRequiresConfirmation, .conflicts:
      ModernAirTheme.dusk
    default:
      ModernAirTheme.tide
    }
  }

  private func failureTitle(_ category: CloudErrorCategory) -> String {
    switch category {
    case .quotaExceeded: "iCloud 空间不足"
    case .offline: "当前离线"
    case .notSignedIn: "iCloud 未登录"
    case .accountRestricted: "iCloud 暂不可用"
    case .rateLimited, .serviceUnavailable: "iCloud 服务暂不可用"
    case .recordConflict: "需要处理冲突"
    case .permissionOrConfiguration: "iCloud 配置不可用"
    case .cancelled: "同步已取消"
    case .unknown: "同步遇到问题"
    }
  }

  private func failureDetail(_ category: CloudErrorCategory) -> String {
    switch category {
    case .quotaExceeded:
      "请释放 iCloud 空间后重试；本机修改不会丢失。"
    case .offline:
      "网络恢复后可再次刷新；本机修改不会丢失。"
    case .notSignedIn:
      "请先登录 iCloud，然后再次刷新。"
    case .accountRestricted:
      "账号当前受限或暂时不可用，请稍后重试。"
    case .rateLimited, .serviceUnavailable:
      "服务恢复后会继续，当前无需重复操作。"
    case .recordConflict:
      "双方版本都已保留，请前往冲突页选择。"
    case .permissionOrConfiguration:
      "同步配置暂不可用，本机功能仍可正常使用。"
    case .cancelled:
      "没有更改本机数据，需要时可再次刷新。"
    case .unknown:
      "未能完成同步，本机数据与待同步修改均已保留。"
    }
  }
}
