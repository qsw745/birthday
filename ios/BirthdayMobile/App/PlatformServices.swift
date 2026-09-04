import BirthdayCore
import Foundation
import UIKit

enum AppleRuntimePlatform: Equatable, Sendable {
  case iPhone
  case macCatalyst
}

enum AppLockLifecycleEvent: Equatable, Sendable {
  case ordinaryFocusLoss
  case enteredBackground
  case systemLocked
  case systemSleep
  case applicationRelaunch
}

struct AppLockPresentation: Equatable, Sendable {
  let title: String
  let detail: String
  let credentialName: String
  let iconName: String
  let lockedDescription: String
  let unlockHint: String
  let unavailableFooter: String
}

struct PlatformServices: Equatable, Sendable {
  let platform: AppleRuntimePlatform
  let deviceName: String
  let systemSettingsURL: URL

  @MainActor static var live: PlatformServices {
    #if targetEnvironment(macCatalyst)
      let platform = AppleRuntimePlatform.macCatalyst
    #else
      let platform = AppleRuntimePlatform.iPhone
    #endif

    return PlatformServices(
      platform: platform,
      deviceName: resolveDeviceName(
        platform: platform,
        uiDeviceName: UIDevice.current.name
      ),
      systemSettingsURL: URL(string: UIApplication.openSettingsURLString)!
    )
  }

  static func resolveDeviceName(
    platform: AppleRuntimePlatform,
    uiDeviceName: String
  ) -> String {
    platform == .macCatalyst ? "这台 Mac" : uiDeviceName
  }

  var deviceKindName: String {
    switch platform {
    case .iPhone: "iPhone"
    case .macCatalyst: "Mac"
    }
  }

  var localStorageIconName: String {
    switch platform {
    case .iPhone: "iphone.and.arrow.forward"
    case .macCatalyst: "desktopcomputer"
    }
  }

  func lockPresentation(for capability: AppLockCapability) -> AppLockPresentation {
    let credentialName = platform == .macCatalyst ? "登录密码" : "设备密码"

    switch capability {
    case .faceID:
      return AppLockPresentation(
        title: "Face ID 应用锁",
        detail: "验证时支持\(credentialName)回退",
        credentialName: credentialName,
        iconName: "faceid",
        lockedDescription: "使用 Face ID 或\(credentialName)继续。验证只会在你轻点下方按钮后开始。",
        unlockHint: "开始 Face ID 或\(credentialName)验证",
        unavailableFooter: unavailableFooter(credentialName: credentialName)
      )
    case .touchID:
      return AppLockPresentation(
        title: "Touch ID 应用锁",
        detail: "验证时支持\(credentialName)回退",
        credentialName: credentialName,
        iconName: "touchid",
        lockedDescription: "使用 Touch ID 或\(credentialName)继续。验证只会在你轻点下方按钮后开始。",
        unlockHint: "开始 Touch ID 或\(credentialName)验证",
        unavailableFooter: unavailableFooter(credentialName: credentialName)
      )
    case .devicePasscode:
      return AppLockPresentation(
        title: "\(credentialName)应用锁",
        detail: "生物识别不可用，将使用\(credentialName)",
        credentialName: credentialName,
        iconName: "lock.shield",
        lockedDescription: "使用\(credentialName)继续。验证只会在你轻点下方按钮后开始。",
        unlockHint: "开始\(credentialName)验证",
        unavailableFooter: unavailableFooter(credentialName: credentialName)
      )
    case .unavailable:
      return AppLockPresentation(
        title: "应用锁不可用",
        detail: "生物识别与\(credentialName)当前均不可用",
        credentialName: credentialName,
        iconName: "lock.slash",
        lockedDescription: "此设备当前无法验证身份，应用锁会自动保持关闭。",
        unlockHint: "此设备当前无法验证身份",
        unavailableFooter: unavailableFooter(credentialName: credentialName)
      )
    }
  }

  func shouldLock(for event: AppLockLifecycleEvent) -> Bool {
    switch event {
    case .ordinaryFocusLoss:
      false
    case .enteredBackground, .systemLocked, .systemSleep, .applicationRelaunch:
      true
    }
  }

  private func unavailableFooter(credentialName: String) -> String {
    "应用锁保持关闭，避免无法进入本机生日资料。请先在系统中设置\(credentialName)。"
  }
}

struct DeviceNotificationPreference: @unchecked Sendable {
  static let key = "top.qisw.birthday.notificationsEnabled"

  private let preferences: UserDefaults

  init(preferences: UserDefaults) {
    self.preferences = preferences
  }

  var isEnabled: Bool {
    preferences.object(forKey: Self.key) as? Bool ?? true
  }

  func setEnabled(_ isEnabled: Bool) {
    preferences.set(isEnabled, forKey: Self.key)
  }
}

struct DeviceNotificationScheduler: NotificationScheduling {
  private let base: any NotificationScheduling
  private let preference: DeviceNotificationPreference

  init(base: any NotificationScheduling, preference: DeviceNotificationPreference) {
    self.base = base
    self.preference = preference
  }

  func apply(_ plan: ReminderPlan) async throws -> NotificationHealth {
    guard preference.isEnabled else { return Self.disabledHealth }
    return try await base.apply(plan)
  }

  func removeAllBirthdayNotifications() async -> NotificationHealth {
    await base.removeAllBirthdayNotifications()
  }

  private static let disabledHealth = NotificationHealth(
    state: .notRequested,
    scheduledCount: 0,
    coverageEnd: nil,
    errorCategory: "disabled_on_device"
  )
}

struct DeviceNotificationOneShotScheduler: OneShotNotificationScheduling {
  private let base: any OneShotNotificationScheduling
  private let preference: DeviceNotificationPreference

  init(base: any OneShotNotificationScheduling, preference: DeviceNotificationPreference) {
    self.base = base
    self.preference = preference
  }

  func schedule(
    birthdayID: UUID,
    name: String,
    now: Date
  ) async -> OneShotNotificationResult {
    guard preference.isEnabled else { return .notAuthorized }
    return await base.schedule(birthdayID: birthdayID, name: name, now: now)
  }
}
