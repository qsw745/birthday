import BirthdayCore
import Foundation
import UIKit

enum AppSyncMode: Equatable, Sendable {
  case cloudKit
  case legacyServer(URL)
  case none

  static var currentBuildAllowsLegacyServerDiagnostics: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  static func resolve(
    configuration: AppConfiguration,
    policy: SyncRuntimeCompositionPolicy,
    allowsLegacyServerDiagnostics: Bool
  ) -> AppSyncMode {
    guard policy.allowsRemoteSyncComposition else { return .none }
    if allowsLegacyServerDiagnostics, let remoteBaseURL = configuration.remoteBaseURL {
      return .legacyServer(remoteBaseURL)
    }
    return .cloudKit
  }
}

@MainActor
protocol CloudSyncRuntimeControlling: AnyObject {
  var initialStatus: CloudSyncStatus { get }
  func start() async -> CloudSyncStatus
  func requestSync() async -> CloudSyncStatus
  func setEnabled(_ enabled: Bool) async -> CloudSyncStatus
  func confirmAccountChange() async -> CloudSyncStatus
  func cancelAccountChange() async -> CloudSyncStatus
}

@MainActor
final class CloudSyncRuntime: CloudSyncRuntimeControlling {
  let initialStatus: CloudSyncStatus

  private let coordinator: CloudSyncCoordinator

  init(coordinator: CloudSyncCoordinator, initialStatus: CloudSyncStatus) {
    self.coordinator = coordinator
    self.initialStatus = initialStatus
  }

  static func live(store: BirthdayStore, preferences: UserDefaults) -> CloudSyncRuntime {
    let preference = CloudSyncPreferenceStore(preferences: preferences)
    let coordinator = CloudSyncCoordinator(
      preference: preference,
      accountProvider: SystemCloudAccountProvider(),
      repository: store,
      engineFactory: {
        try await SystemCloudSyncEngineAdapter(repository: store)
      }
    )
    return CloudSyncRuntime(
      coordinator: coordinator,
      initialStatus: preference.isEnabled ? .unavailable : .disabled
    )
  }

  func start() async -> CloudSyncStatus {
    await coordinator.start()
    return await coordinator.status
  }

  func requestSync() async -> CloudSyncStatus {
    await coordinator.requestSync()
    return await coordinator.status
  }

  func setEnabled(_ enabled: Bool) async -> CloudSyncStatus {
    await coordinator.setEnabled(enabled)
    return await coordinator.status
  }

  func confirmAccountChange() async -> CloudSyncStatus {
    await coordinator.confirmAccountChange()
    return await coordinator.status
  }

  func cancelAccountChange() async -> CloudSyncStatus {
    await coordinator.cancelAccountChange()
    return await coordinator.status
  }
}

@MainActor
final class CloudRemoteNotificationRouter {
  static let shared = CloudRemoteNotificationRouter()

  private var handler: (() async -> Bool)?

  func install(model: AppModel) {
    handler = { [weak model] in
      guard let model, model.syncMode == .cloudKit, model.isCloudSyncEnabled else {
        return false
      }
      let recordsBeforeSync = model.records
      let conflictCountBeforeSync = model.syncConflictCount
      await model.requestCloudSync(isManual: false)
      return model.records != recordsBeforeSync
        || model.syncConflictCount != conflictCountBeforeSync
    }
  }

  func uninstall() {
    handler = nil
  }

  func handleRemoteChange() async -> Bool {
    guard let handler else { return false }
    return await handler()
  }
}

final class CloudRemoteNotificationDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let arguments = ProcessInfo.processInfo.arguments
    let configuration = AppConfiguration(
      apiBaseURLValue: Bundle.main.object(forInfoDictionaryKey: "BirthdayAPIBaseURL")
    )
    let policy = SyncRuntimeCompositionPolicy(
      isUITesting: arguments.contains("-ui-testing"),
      networkDisabled: arguments.contains("-network-disabled")
    )
    let mode = AppSyncMode.resolve(
      configuration: configuration,
      policy: policy,
      allowsLegacyServerDiagnostics: AppSyncMode.currentBuildAllowsLegacyServerDiagnostics
    )
    if mode == .cloudKit {
      application.registerForRemoteNotifications()
    }
    return true
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any]
  ) async -> UIBackgroundFetchResult {
    await CloudRemoteNotificationRouter.shared.handleRemoteChange() ? .newData : .noData
  }
}
