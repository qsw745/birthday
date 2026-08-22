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
      makeRemoteClient: { MobileAPIClient(baseURL: $0) }
    )
  }

  init(
    appConfiguration: AppConfiguration,
    syncRuntimePolicy: SyncRuntimeCompositionPolicy,
    preferences: UserDefaults,
    notificationCenter: any NotificationCenterClient,
    requestNotificationAuthorization: @escaping @MainActor () async throws -> Bool,
    makeRemoteClient: @escaping @MainActor (URL) -> MobileAPIClient
  ) {
    self.appConfiguration = appConfiguration
    self.syncRuntimePolicy = syncRuntimePolicy
    self.preferences = preferences
    self.notificationCenter = notificationCenter
    self.requestNotificationAuthorization = requestNotificationAuthorization
    self.makeRemoteClient = makeRemoteClient
  }

  func make(container: ModelContainer) -> AppModel {
    let remoteBaseURL =
      syncRuntimePolicy.allowsRemoteSyncComposition ? appConfiguration.remoteBaseURL : nil
    let composition = ProductionAppRuntimeCompositionFactory.make(
      remoteBaseURL: remoteBaseURL,
      notificationCenter: notificationCenter,
      requestNotificationAuthorization: requestNotificationAuthorization,
      makeRemoteClient: makeRemoteClient
    )
    let store = BirthdayStore(modelContainer: container)
    let reminderPlanner = ReminderPlanner()

    guard let mobileAPI = composition.remoteClient else {
      return AppModel(
        store: store,
        preferences: preferences,
        localOnlyStatusDetail: appConfiguration.localOnlyMessage
          ?? "生日与提醒只保存在这台设备上。",
        isServerBindingAvailable: false,
        authenticator: LocalAuthenticationService(),
        serverDeviceBinder: OfflineServerDeviceBinder(),
        notificationScheduler: composition.notificationScheduler,
        oneShotNotificationScheduler: composition.oneShotNotificationScheduler,
        reminderPlanner: reminderPlanner,
        requestNotificationAuthorization: composition.requestNotificationAuthorization
      )
    }

    let credentials = DeviceCredentialStore(secure: KeychainStore())
    let remoteAccessGate = RemoteSyncAccessGate()
    let model = AppModel(
      store: store,
      preferences: preferences,
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
        notificationScheduler: composition.notificationScheduler,
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
