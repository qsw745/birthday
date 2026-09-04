import BirthdayCore
import Foundation
import Testing

@testable import BirthdayMobile

@Test func platformServicesProduceNativeLockCopyAndSystemDestinations() throws {
  let settingsURL = try #require(URL(string: "app-settings:test"))
  let phone = PlatformServices(
    platform: .iPhone,
    deviceName: "测试 iPhone",
    systemSettingsURL: settingsURL
  )
  let mac = PlatformServices(
    platform: .macCatalyst,
    deviceName: "测试 Mac",
    systemSettingsURL: settingsURL
  )

  #expect(phone.deviceName == "测试 iPhone")
  #expect(phone.systemSettingsURL == settingsURL)
  #expect(phone.lockPresentation(for: .faceID).title == "Face ID 应用锁")
  #expect(phone.lockPresentation(for: .faceID).credentialName == "设备密码")
  #expect(mac.lockPresentation(for: .touchID).title == "Touch ID 应用锁")
  #expect(mac.lockPresentation(for: .touchID).credentialName == "登录密码")
}

@Test func macLockPolicyIgnoresOrdinaryFocusLossButLocksForSecurityLifecycleEvents() {
  let services = PlatformServices(
    platform: .macCatalyst,
    deviceName: "测试 Mac",
    systemSettingsURL: URL(string: "app-settings:test")!
  )

  #expect(!services.shouldLock(for: .ordinaryFocusLoss))
  #expect(services.shouldLock(for: .enteredBackground))
  #expect(services.shouldLock(for: .systemLocked))
  #expect(services.shouldLock(for: .systemSleep))
  #expect(services.shouldLock(for: .applicationRelaunch))
}

@Test func macDeviceNameUsesAStableMacLabelInsteadOfCatalystsIPadIdentity() {
  #expect(
    PlatformServices.resolveDeviceName(
      platform: .macCatalyst,
      uiDeviceName: "iPad"
    ) == "这台 Mac"
  )
}

@Test func deviceNotificationPreferenceDefaultsOnAndUsesItsOwnLocalKey() throws {
  let suiteName = "PlatformServicesTests.\(UUID().uuidString)"
  let preferences = try #require(UserDefaults(suiteName: suiteName))
  defer { preferences.removePersistentDomain(forName: suiteName) }
  let preference = DeviceNotificationPreference(preferences: preferences)

  #expect(preference.isEnabled)
  #expect(preferences.persistentDomain(forName: suiteName)?.isEmpty != false)

  preference.setEnabled(false)

  #expect(!preference.isEnabled)
  #expect(preferences.object(forKey: DeviceNotificationPreference.key) as? Bool == false)
  #expect(
    Set(preferences.persistentDomain(forName: suiteName).map { Array($0.keys) } ?? [])
      == [DeviceNotificationPreference.key]
  )
}
