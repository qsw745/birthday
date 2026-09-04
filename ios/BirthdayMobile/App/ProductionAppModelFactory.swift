import BirthdayCore
import Foundation
import SwiftData
@preconcurrency import UserNotifications

@MainActor
struct ProductionAppModelFactory {
  private let appConfiguration: AppConfiguration
  private let syncRuntimePolicy: SyncRuntimeCompositionPolicy
  private let preferences: UserDefaults
  private let notificationCenter: any NotificationCenterClient
  private let requestNotificationAuthorization: @MainActor () async throws -> Bool
  private let makeRemoteClient: @MainActor (URL) -> MobileAPIClient
  private let allowsLegacyServerDiagnostics: Bool
  private let makeCloudRuntime:
    @MainActor (BirthdayStore, UserDefaults) -> any CloudSyncRuntimeControlling

  private static var defaultAllowsLegacyServerDiagnostics: Bool {
    AppSyncMode.currentBuildAllowsLegacyServerDiagnostics
  }

  init(
    appConfiguration: AppConfiguration,
    syncRuntimePolicy: SyncRuntimeCompositionPolicy
  ) {
    let center = UNUserNotificationCenter.current()
    self.init(
      appConfiguration: appConfiguration,
      syncRuntimePolicy: syncRuntimePolicy,
      preferences: .standard,
      notificationCenter: SystemNotificationCenterClient(center: center),
      requestNotificationAuthorization: {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
      },
      makeRemoteClient: { MobileAPIClient(baseURL: $0) },
      allowsLegacyServerDiagnostics: Self.defaultAllowsLegacyServerDiagnostics,
      makeCloudRuntime: { store, preferences in
        CloudSyncRuntime.live(store: store, preferences: preferences)
      }
    )
  }

  init(
    appConfiguration: AppConfiguration,
    syncRuntimePolicy: SyncRuntimeCompositionPolicy,
    preferences: UserDefaults,
    notificationCenter: any NotificationCenterClient,
    requestNotificationAuthorization: @escaping @MainActor () async throws -> Bool,
    makeRemoteClient: @escaping @MainActor (URL) -> MobileAPIClient,
    allowsLegacyServerDiagnostics: Bool = Self.defaultAllowsLegacyServerDiagnostics,
    makeCloudRuntime: @escaping @MainActor (BirthdayStore, UserDefaults) ->
      any CloudSyncRuntimeControlling = { store, preferences in
        CloudSyncRuntime.live(store: store, preferences: preferences)
      }
  ) {
    self.appConfiguration = appConfiguration
    self.syncRuntimePolicy = syncRuntimePolicy
    self.preferences = preferences
    self.notificationCenter = notificationCenter
    self.requestNotificationAuthorization = requestNotificationAuthorization
    self.makeRemoteClient = makeRemoteClient
    self.allowsLegacyServerDiagnostics = allowsLegacyServerDiagnostics
    self.makeCloudRuntime = makeCloudRuntime
  }

  func make(container: ModelContainer) -> AppModel {
    let syncMode = AppSyncMode.resolve(
      configuration: appConfiguration,
      policy: syncRuntimePolicy,
      allowsLegacyServerDiagnostics: allowsLegacyServerDiagnostics
    )
    let remoteBaseURL: URL? =
      if case .legacyServer(let url) = syncMode { url } else { nil }
    let composition = ProductionAppRuntimeCompositionFactory.make(
      remoteBaseURL: remoteBaseURL,
      notificationCenter: notificationCenter,
      requestNotificationAuthorization: requestNotificationAuthorization,
      makeRemoteClient: makeRemoteClient
    )
    let store = BirthdayStore(modelContainer: container)
    let reminderPlanner = ReminderPlanner()

    guard case .legacyServer = syncMode, let mobileAPI = composition.remoteClient else {
      let model = AppModel(
        store: store,
        preferences: preferences,
        syncMode: syncMode,
        localOnlyStatusDetail: syncMode == .cloudKit
          ? "生日先保存在本机，并通过你的 iCloud 私有空间同步。"
          : appConfiguration.localOnlyMessage ?? "生日与提醒只保存在这台设备上。",
        isServerBindingAvailable: false,
        authenticator: LocalAuthenticationService(),
        serverDeviceBinder: OfflineServerDeviceBinder(),
        notificationScheduler: composition.notificationScheduler,
        oneShotNotificationScheduler: composition.oneShotNotificationScheduler,
        reminderPlanner: reminderPlanner,
        requestNotificationAuthorization: composition.requestNotificationAuthorization
      )
      if syncMode == .cloudKit {
        model.configureCloudSyncRuntime(makeCloudRuntime(store, preferences))
      }
      return model
    }

    let credentials = DeviceCredentialStore(secure: KeychainStore())
    let remoteAccessGate = RemoteSyncAccessGate()
    let model = AppModel(
      store: store,
      preferences: preferences,
      syncMode: syncMode,
      isServerBindingAvailable: true,
      authenticator: LocalAuthenticationService(),
      serverDeviceBinder: ServerDeviceBinder(api: mobileAPI, credentials: credentials),
      notificationScheduler: composition.notificationScheduler,
      oneShotNotificationScheduler: composition.oneShotNotificationScheduler,
      reminderPlanner: reminderPlanner,
      requestNotificationAuthorization: composition.requestNotificationAuthorization
    )
    let syncEngine = SyncEngine(
      api: mobileAPI,
      store: store,
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )
    let initiallyBound = (try? credentials.load()).map { $0.refreshExpiresAt > Date() } ?? false
    model.configureSyncCoordinator(
      SyncCoordinator(
        syncEngine: syncEngine,
        remoteAccessGate: remoteAccessGate,
        store: store,
        credentials: credentials,
        notificationScheduler: model.notificationScheduler,
        reminderPlanner: reminderPlanner,
        publish: { [weak model] outcome in
          await model?.publishCompletedSync(outcome)
        }
      ),
      initiallyBound: initiallyBound
    )
    model.configureDeviceManagement(
      DeviceManagementService(
        api: mobileAPI,
        credentials: credentials,
        remoteAccessGate: remoteAccessGate
      )
    )
    return model
  }
}
