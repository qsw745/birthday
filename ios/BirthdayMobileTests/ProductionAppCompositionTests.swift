import BirthdayCore
import Foundation
import SwiftData
import Testing

@testable import BirthdayMobile

private actor ProductionCompositionNotificationCenter: NotificationCenterClient {
  private var requests: [String: NotificationRequestSnapshot]

  init(pending: [NotificationRequestSnapshot]) {
    requests = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
  }

  func authorization() async -> NotificationAuthorization { .authorized }

  func pendingRequests() async -> [NotificationRequestSnapshot] {
    requests.values.sorted { $0.identifier < $1.identifier }
  }

  func remove(identifiers: [String]) async {
    for identifier in identifiers { requests.removeValue(forKey: identifier) }
  }

  func add(_ request: NotificationRequestSnapshot) async throws {
    requests[request.identifier] = request
  }
}

@Test
@MainActor
func productionAppWithoutRemoteConfigurationUsesSystemNotificationPipeline() async throws {
  let oldRequest = NotificationRequestSnapshot(
    identifier: "birthday.old",
    triggerDate: Date(timeIntervalSince1970: 1_800_000_000),
    title: "旧提醒",
    body: "应由滚动计划移除"
  )
  let notificationCenter = ProductionCompositionNotificationCenter(pending: [oldRequest])
  let suiteName = "top.qisw.birthday.production-composition-tests.\(UUID().uuidString)"
  let preferences = try #require(UserDefaults(suiteName: suiteName))
  defer { preferences.removePersistentDomain(forName: suiteName) }
  let container = try BirthdayModelContainer.make(
    configuration: ModelConfiguration(isStoredInMemoryOnly: true)
  )
  let factory = ProductionAppModelFactory(
    appConfiguration: AppConfiguration(apiBaseURLValue: nil),
    syncRuntimePolicy: SyncRuntimeCompositionPolicy(isUITesting: false, networkDisabled: true),
    preferences: preferences,
    notificationCenter: notificationCenter,
    requestNotificationAuthorization: { true },
    makeRemoteClient: { url in
      Issue.record("无远程配置时不得构造 remote client")
      return MobileAPIClient(baseURL: url)
    }
  )

  let model = factory.make(container: container)
  #expect(model.isSyncRuntimeEnabled == false)
  await model.reload()
  #expect(model.notificationHealth.state == .scheduled)
  #expect(await notificationCenter.pendingRequests().isEmpty)

  let birthdayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  let immediate = await model.oneShotNotificationScheduler.schedule(
    birthdayID: birthdayID,
    name: "妈妈",
    now: Date(timeIntervalSince1970: 1_800_000_000)
  )
  #expect(immediate == .scheduled)
  #expect(
    await notificationCenter.pendingRequests().map(\.identifier) == [
      "birthday.immediate.11111111-1111-4111-8111-111111111111.1800000000000"
    ]
  )

  try await notificationCenter.add(
    NotificationRequestSnapshot(
      identifier: "other.app",
      triggerDate: Date(timeIntervalSince1970: 1_900_000_000),
      title: "其他通知",
      body: "必须保留"
    )
  )
  await model.setNotificationsEnabled(false)
  #expect(!model.notificationsEnabled)
  #expect(await notificationCenter.pendingRequests().map(\.identifier) == ["other.app"])
  #expect(
    await model.oneShotNotificationScheduler.schedule(
      birthdayID: birthdayID,
      name: "妈妈",
      now: Date(timeIntervalSince1970: 1_800_000_100)
    ) == .notAuthorized
  )

  _ = try await model.store.save(
    BirthdayDraft(
      name: "爸爸",
      lunarBirthday: LunarBirthday(month: 1, day: 1, isLeapMonth: false),
      reminder: .defaults
    ),
    id: nil,
    now: Date(),
    timeZone: .current
  )
  await model.setNotificationsEnabled(true)
  let restoredIdentifiers = await notificationCenter.pendingRequests().map(\.identifier)
  #expect(model.notificationsEnabled)
  #expect(restoredIdentifiers.contains("other.app"))
  #expect(restoredIdentifiers.contains { $0.hasPrefix("birthday.") })
}
