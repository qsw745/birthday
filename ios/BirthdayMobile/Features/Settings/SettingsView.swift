import BirthdayCore
import SwiftUI
import UIKit

struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    List {
      Section {
        Toggle(isOn: lockEnabledBinding) {
          Label {
            VStack(alignment: .leading, spacing: 3) {
              Text(lockTitle)
              Text(lockDetail)
                .font(.caption)
                .foregroundStyle(ModernAirTheme.secondaryInk)
            }
          } icon: {
            Image(systemName: lockIcon)
              .foregroundStyle(ModernAirTheme.tide)
          }
        }
        .tint(ModernAirTheme.tide)
        .frame(minHeight: 44)
        .disabled(model.lockCapability == .unavailable)
        .accessibilityHint(lockAccessibilityHint)
      } header: {
        Text("本地隐私")
      } footer: {
        Text(lockFooter)
      }

      Section("本地通知") {
        notificationStatusRow

        LabeledContent {
          Text(model.notificationHealth.scheduledCount, format: .number)
            .monospacedDigit()
        } label: {
          Label("已安排数量", systemImage: "number.circle")
        }
        .frame(minHeight: 44)

        LabeledContent {
          Text(coverageText)
            .multilineTextAlignment(.trailing)
        } label: {
          Label("覆盖截止", systemImage: "calendar.badge.clock")
        }
        .frame(minHeight: 44)

        Button {
          Task { await model.rebuildReminders() }
        } label: {
          Label(
            model.isRebuildingReminders ? "正在重新安排" : "重新安排本地提醒",
            systemImage: "arrow.clockwise"
          )
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .disabled(
          model.isRebuildingReminders || model.isRequestingNotificationAuthorization)

        if canRequestNotificationAuthorization {
          Button {
            Task { await model.requestNotificationAuthorizationFromSettings() }
          } label: {
            HStack(spacing: 9) {
              if model.isRequestingNotificationAuthorization {
                ProgressView()
                  .accessibilityHidden(true)
              } else {
                Image(systemName: "bell.badge")
                  .accessibilityHidden(true)
              }
              Text(
                model.isRequestingNotificationAuthorization ? "正在请求通知权限" : "开启通知")
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }
          .disabled(
            model.isRequestingNotificationAuthorization || model.isRebuildingReminders)
        }

        if model.notificationHealth.state == .permissionDenied {
          Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
            Label("打开系统设置", systemImage: "gearshape.arrow.triangle.2.circlepath")
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }
        }
      }

      if model.isServerBindingAvailable {
        SyncSettingsView(model: model)
      } else {
        Section {
          Label {
            VStack(alignment: .leading, spacing: 3) {
              Text("仅保存在此 iPhone")
              Text("无需账号，也不依赖服务器")
                .font(.caption)
                .foregroundStyle(ModernAirTheme.secondaryInk)
            }
          } icon: {
            Image(systemName: "iphone.and.arrow.forward")
              .foregroundStyle(ModernAirTheme.tide)
          }
          .frame(minHeight: 44)
          .accessibilityIdentifier("localOnlyStorageRow")
        } header: {
          Text("数据存储")
        } footer: {
          Text("生日资料、提醒设置和农历日期均在本机处理；删除 App 会同时移除本机资料。")
        }
      }

      Section("关于与支持") {
        Link(destination: Self.privacyPolicyURL) {
          Label("隐私政策", systemImage: "hand.raised")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("privacyPolicyLink")

        Link(destination: Self.supportURL) {
          Label("使用支持", systemImage: "questionmark.circle")
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("supportLink")
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(ModernAirTheme.mist.ignoresSafeArea())
    .navigationTitle("设置")
  }

  private var lockEnabledBinding: Binding<Bool> {
    Binding(
      get: { model.lockEnabled },
      set: { model.setLockEnabled($0) }
    )
  }

  private static let privacyPolicyURL = URL(
    string: "https://qisw.top/birthday/privacy.html"
  )!

  private static let supportURL = URL(
    string: "https://qisw.top/birthday/support.html"
  )!

  private var lockAccessibilityHint: String {
    guard model.lockCapability != .unavailable else {
      return "此设备当前无法启用应用锁"
    }
    return model.lockEnabled
      ? "关闭后无需验证即可查看本机生日资料"
      : "开启后会在下次进入后台或重新启动时锁定生日资料"
  }

  private var lockTitle: String {
    switch model.lockCapability {
    case .faceID: "Face ID 应用锁"
    case .devicePasscode: "设备密码应用锁"
    case .unavailable: "应用锁不可用"
    }
  }

  private var lockDetail: String {
    switch model.lockCapability {
    case .faceID: "验证时支持设备密码回退"
    case .devicePasscode: "Face ID 不可用，将使用设备密码"
    case .unavailable: "Face ID 与设备密码当前均不可用"
    }
  }

  private var lockIcon: String {
    model.lockCapability == .faceID ? "faceid" : "lock.shield"
  }

  private var lockFooter: String {
    guard model.lockCapability != .unavailable else {
      return "应用锁保持关闭，避免无法进入本机生日资料。请先在系统中设置设备密码。"
    }
    return "关闭后当前会话会保持打开；重新开启不会打断当前操作，下次进入后台或重新启动时生效。"
  }

  private var notificationStatusRow: some View {
    Label {
      VStack(alignment: .leading, spacing: 3) {
        Text(notificationStatusTitle)
          .foregroundStyle(ModernAirTheme.ink)
        Text(notificationStatusDetail)
          .font(.caption)
          .foregroundStyle(ModernAirTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    } icon: {
      Image(systemName: notificationStatusIcon)
        .foregroundStyle(ModernAirTheme.tide)
    }
    .frame(minHeight: 44)
    .accessibilityElement(children: .combine)
  }

  private var notificationStatusTitle: String {
    switch model.notificationHealth.state {
    case .scheduled:
      "通知已授权"
    case .permissionDenied:
      "通知权限已关闭"
    case .notRequested:
      "尚未请求通知权限"
    case .failed:
      model.notificationHealth.errorCategory == "authorization_request_failed"
        ? "通知权限请求失败" : "本地提醒安排失败"
    }
  }

  private var notificationStatusDetail: String {
    switch model.notificationHealth.state {
    case .scheduled:
      model.notificationHealth.scheduledCount == 0
        ? "当前没有需要安排的生日提醒。"
        : "生日提醒已由这台 iPhone 安排。"
    case .permissionDenied:
      "请在系统设置中允许通知，然后重新安排。"
    case .notRequested:
      "你尚未允许通知；本地生日资料仍可正常使用。"
    case .failed:
      failureDetail
    }
  }

  private var notificationStatusIcon: String {
    switch model.notificationHealth.state {
    case .scheduled:
      "checkmark.circle.fill"
    case .permissionDenied:
      "bell.slash.fill"
    case .notRequested:
      "bell.badge"
    case .failed:
      "exclamationmark.triangle.fill"
    }
  }

  private var failureDetail: String {
    switch model.notificationHealth.errorCategory {
    case "local_read_failed":
      "无法读取最新生日资料，现有提醒没有更改。请稍后重试。"
    case "plan_failed":
      "无法计算提醒日期。请检查生日资料后重试。"
    case "authorization_request_failed":
      "未能完成通知权限请求。请稍后重试。"
    default:
      "系统未能安排提醒，请再次尝试。"
    }
  }

  private var canRequestNotificationAuthorization: Bool {
    if model.notificationHealth.state == .notRequested {
      return true
    }
    return model.notificationHealth.state == .failed
      && model.notificationHealth.errorCategory == "authorization_request_failed"
  }

  private var coverageText: String {
    guard let coverageEnd = model.notificationHealth.coverageEnd else {
      return "暂无"
    }
    return coverageEnd.formatted(
      Date.FormatStyle()
        .year()
        .month(.abbreviated)
        .day()
        .locale(Locale(identifier: "zh_CN"))
    )
  }
}
