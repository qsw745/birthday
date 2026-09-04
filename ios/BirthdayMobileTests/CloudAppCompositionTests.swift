import BirthdayCore
import Foundation
import SwiftData
import Testing

@testable import BirthdayMobile

private actor CloudCompositionNotificationCenter: NotificationCenterClient {
  func authorization() async -> NotificationAuthorization { .authorized }
  func pendingRequests() async -> [NotificationRequestSnapshot] { [] }
  func remove(identifiers: [String]) async {}
  func add(_ request: NotificationRequestSnapshot) async throws {}
}

@MainActor
private final class FakeCloudSyncRuntime: CloudSyncRuntimeControlling {
  private(set) var startCount = 0
  private(set) var requestCount = 0
  private(set) var enableValues: [Bool] = []
  private(set) var confirmationCount = 0
  private(set) var cancellationCount = 0
  var initialStatus: CloudSyncStatus = .unavailable
  var nextStatus: CloudSyncStatus = .synchronized(
    date: Date(timeIntervalSince1970: 1_800_000_000)
  )

  func start() async -> CloudSyncStatus {
    startCount += 1
    return nextStatus
  }

  func requestSync() async -> CloudSyncStatus {
    requestCount += 1
    return nextStatus
  }

  func setEnabled(_ enabled: Bool) async -> CloudSyncStatus {
    enableValues.append(enabled)
    return enabled ? nextStatus : .disabled
  }

  func confirmAccountChange() async -> CloudSyncStatus {
    confirmationCount += 1
    return nextStatus
  }

  func cancelAccountChange() async -> CloudSyncStatus {
    cancellationCount += 1
    return .disabled
  }
}

@Test func syncModeKeepsReleaseOnCloudKitAndAllowsOnlyExplicitDebugServerDiagnostics() {
  let configured = AppConfiguration(apiBaseURLValue: "https://example.com/api/mobile")
  let missing = AppConfiguration(apiBaseURLValue: nil)
  let networked = SyncRuntimeCompositionPolicy(isUITesting: false, networkDisabled: false)
  let offline = SyncRuntimeCompositionPolicy(isUITesting: true, networkDisabled: true)

  #expect(
    AppSyncMode.resolve(
      configuration: configured,
      policy: networked,
      allowsLegacyServerDiagnostics: false
    ) == .cloudKit
  )
  #expect(
    AppSyncMode.resolve(
      configuration: configured,
      policy: networked,
      allowsLegacyServerDiagnostics: true
    ) == .legacyServer(URL(string: "https://example.com/api/mobile")!)
  )
  #expect(
    AppSyncMode.resolve(
      configuration: missing,
      policy: networked,
      allowsLegacyServerDiagnostics: true
    ) == .cloudKit
  )
  #expect(
    AppSyncMode.resolve(
      configuration: configured,
      policy: offline,
      allowsLegacyServerDiagnostics: true
    ) == .none
  )
}

@Test
@MainActor
func releaseCompositionBuildsCloudRuntimeWithoutConstructingLegacyServerClient() throws {
  let suiteName = "CloudAppCompositionTests.\(UUID().uuidString)"
  let preferences = try #require(UserDefaults(suiteName: suiteName))
  defer { preferences.removePersistentDomain(forName: suiteName) }
  let container = try BirthdayModelContainer.make(
    configuration: BirthdayModelContainer.localConfiguration(isStoredInMemoryOnly: true)
  )
  let fakeRuntime = FakeCloudSyncRuntime()
  var cloudRuntimeConstructionCount = 0
  let factory = ProductionAppModelFactory(
    appConfiguration: AppConfiguration(
      apiBaseURLValue: "https://debug-only.example.com/api/mobile"
    ),
    syncRuntimePolicy: SyncRuntimeCompositionPolicy(
      isUITesting: false,
      networkDisabled: false
    ),
    preferences: preferences,
    notificationCenter: CloudCompositionNotificationCenter(),
    requestNotificationAuthorization: { true },
    makeRemoteClient: { url in
      Issue.record("正式组装不得构造旧服务器客户端：\(url)")
      return MobileAPIClient(baseURL: url)
    },
    allowsLegacyServerDiagnostics: false,
    makeCloudRuntime: { _, _ in
      cloudRuntimeConstructionCount += 1
      return fakeRuntime
    }
  )

  let model = factory.make(container: container)

  #expect(model.syncMode == .cloudKit)
  #expect(model.cloudSyncStatus == .unavailable)
  #expect(!model.isServerBindingAvailable)
  #expect(cloudRuntimeConstructionCount == 1)
  #expect(CloudSyncPreferenceStore(preferences: preferences).isEnabled)
}

@Test
@MainActor
func cloudRuntimeActionsPublishStatusAndReloadOnlyLocalData() async throws {
  let suiteName = "CloudAppCompositionActions.\(UUID().uuidString)"
  let preferences = try #require(UserDefaults(suiteName: suiteName))
  defer { preferences.removePersistentDomain(forName: suiteName) }
  let container = try BirthdayModelContainer.make(
    configuration: BirthdayModelContainer.localConfiguration(isStoredInMemoryOnly: true)
  )
  let model = AppModel(
    store: BirthdayStore(modelContainer: container),
    preferences: preferences,
    syncMode: .cloudKit,
    serverDeviceBinder: OfflineServerDeviceBinder()
  )
  let runtime = FakeCloudSyncRuntime()
  model.configureCloudSyncRuntime(runtime)

  await model.startCloudSync()
  #expect(runtime.startCount == 1)
  #expect(model.cloudSyncStatus == runtime.nextStatus)
  #expect(model.loadState == .loaded)

  await model.setCloudSyncEnabled(false)
  #expect(runtime.enableValues == [false])
  #expect(model.cloudSyncStatus == .disabled)

  await model.setCloudSyncEnabled(true)
  await model.requestCloudSync()
  #expect(runtime.enableValues == [false, true])
  #expect(runtime.requestCount == 1)

  runtime.initialStatus = .accountChangeRequiresConfirmation
  model.configureCloudSyncRuntime(runtime)
  await model.confirmCloudAccountChange()
  await model.cancelCloudAccountChange()
  #expect(runtime.confirmationCount == 1)
  #expect(runtime.cancellationCount == 1)
  #expect(model.cloudSyncStatus == .disabled)
}

@Test func cloudConflictPresentationContainsOnlyCloudKitContractFields() throws {
  let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  let local = try CloudBirthdaySnapshot(
    id: id,
    name: "妈妈",
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    reminderTimeMinutes: 540,
    notifyDayBefore: true,
    notifySameDay: true,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
    deletedAt: nil
  )
  let iCloud = try CloudBirthdaySnapshot(
    id: id,
    name: "母亲",
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    reminderTimeMinutes: 600,
    notifyDayBefore: false,
    notifySameDay: true,
    createdAt: local.createdAt,
    updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
    deletedAt: nil
  )

  let values = CloudConflictPresentation.changedValues(local: local, iCloud: iCloud)
  let visibleCopy = values.joined(separator: " ")

  #expect(values.count == 3)
  #expect(visibleCopy.contains("姓名"))
  #expect(visibleCopy.contains("提醒时间"))
  #expect(visibleCopy.contains("通知"))
  #expect(!visibleCopy.contains("邮件"))
  #expect(!visibleCopy.contains("版本"))
}
