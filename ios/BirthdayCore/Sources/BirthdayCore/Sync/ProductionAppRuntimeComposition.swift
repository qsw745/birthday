import Foundation

public struct ProductionAppRuntimeComposition<RemoteClient> {
  public let notificationScheduler: UserNotificationScheduler
  public let oneShotNotificationScheduler: OneShotNotificationScheduler
  public let requestNotificationAuthorization: @MainActor () async throws -> Bool
  public let remoteClient: RemoteClient?

  fileprivate init(
    notificationScheduler: UserNotificationScheduler,
    oneShotNotificationScheduler: OneShotNotificationScheduler,
    requestNotificationAuthorization: @escaping @MainActor () async throws -> Bool,
    remoteClient: RemoteClient?
  ) {
    self.notificationScheduler = notificationScheduler
    self.oneShotNotificationScheduler = oneShotNotificationScheduler
    self.requestNotificationAuthorization = requestNotificationAuthorization
    self.remoteClient = remoteClient
  }
}

public enum ProductionAppRuntimeCompositionFactory {
  @MainActor
  public static func make<RemoteClient>(
    remoteBaseURL: URL?,
    notificationCenter: any NotificationCenterClient,
    requestNotificationAuthorization: @escaping @MainActor () async throws -> Bool,
    makeRemoteClient: @MainActor (URL) -> RemoteClient
  ) -> ProductionAppRuntimeComposition<RemoteClient> {
    ProductionAppRuntimeComposition(
      notificationScheduler: UserNotificationScheduler(center: notificationCenter),
      oneShotNotificationScheduler: OneShotNotificationScheduler(center: notificationCenter),
      requestNotificationAuthorization: requestNotificationAuthorization,
      remoteClient: remoteBaseURL.map(makeRemoteClient)
    )
  }
}
