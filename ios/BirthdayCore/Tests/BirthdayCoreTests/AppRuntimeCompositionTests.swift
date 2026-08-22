import Foundation
import Testing

@testable import BirthdayCore

private actor CompositionNotificationCenter: NotificationCenterClient {
  private var requests: [String: NotificationRequestSnapshot] = [:]

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

private struct CompositionRemoteClient: Sendable {}

@Test
@MainActor
func productionWithoutRemoteConfigurationStillSchedulesLocalNotifications() async throws {
  let center = CompositionNotificationCenter()
  let configuration = AppConfiguration(apiBaseURLValue: nil)
  let composition = ProductionAppRuntimeCompositionFactory.make(
    remoteBaseURL: configuration.remoteBaseURL,
    notificationCenter: center,
    requestNotificationAuthorization: { true },
    makeRemoteClient: { _ in
      Issue.record("无远程配置时不得构造 remote client")
      return CompositionRemoteClient()
    }
  )
  let birthdayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let plan = ReminderPlan(
    birthdayNotifications: [
      ReminderCandidate(
        identifier: "birthday.11111111-1111-4111-8111-111111111111.sameDay.1800000060",
        birthdayId: birthdayID,
        kind: .sameDay,
        triggerDate: now.addingTimeInterval(60),
        title: "今天是妈妈的生日",
        body: "别忘了送上生日祝福。"
      )
    ],
    maintenanceNotification: nil,
    coverageEnd: now.addingTimeInterval(60)
  )

  #expect(composition.remoteClient == nil)
  #expect(try await composition.requestNotificationAuthorization())
  let health = try await composition.notificationScheduler.apply(plan)
  let immediate = await composition.oneShotNotificationScheduler.schedule(
    birthdayID: birthdayID,
    name: "妈妈",
    now: now
  )

  #expect(health.state == .scheduled)
  #expect(immediate == .scheduled)
  #expect(
    await center.pendingRequests().map(\.identifier) == [
      "birthday.11111111-1111-4111-8111-111111111111.sameDay.1800000060",
      "birthday.immediate.11111111-1111-4111-8111-111111111111.1800000000000",
    ]
  )
}
