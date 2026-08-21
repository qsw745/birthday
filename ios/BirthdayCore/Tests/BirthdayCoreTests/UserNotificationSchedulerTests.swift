import Foundation
import Testing
import UserNotifications

@testable import BirthdayCore

private enum FakeNotificationError: Error {
  case addFailed
}

private actor FakeNotificationCenterClient: NotificationCenterClient {
  let configuredAuthorization: NotificationAuthorization
  let configuredPendingIdentifiers: [String]
  let failOnAddIndex: Int?
  private var removedIdentifiers: [String] = []
  private var addedCandidates: [ReminderCandidate] = []

  init(
    authorization: NotificationAuthorization,
    pendingIdentifiers: [String],
    failOnAddIndex: Int? = nil
  ) {
    configuredAuthorization = authorization
    configuredPendingIdentifiers = pendingIdentifiers
    self.failOnAddIndex = failOnAddIndex
  }

  func authorization() async -> NotificationAuthorization {
    configuredAuthorization
  }

  func pendingIdentifiers() async -> [String] {
    configuredPendingIdentifiers
  }

  func remove(identifiers: [String]) async {
    removedIdentifiers = identifiers
  }

  func add(_ candidate: ReminderCandidate) async throws {
    if addedCandidates.count == failOnAddIndex {
      throw FakeNotificationError.addFailed
    }
    addedCandidates.append(candidate)
  }

  func capturedRemoved() -> [String] {
    removedIdentifiers
  }

  func capturedAdded() -> [ReminderCandidate] {
    addedCandidates
  }
}

private let notificationPlanStart = Date(timeIntervalSince1970: 1_800_000_000)

private func notificationCandidate(identifier: String, minuteOffset: Int) -> ReminderCandidate {
  ReminderCandidate(
    identifier: identifier,
    birthdayId: UUID(),
    kind: .sameDay,
    triggerDate: notificationPlanStart.addingTimeInterval(TimeInterval(minuteOffset * 60)),
    title: "生日提醒",
    body: "记得送上祝福。"
  )
}

private func makeReminderPlan(count: Int) -> ReminderPlan {
  let items = (0..<count).map { index in
    notificationCandidate(identifier: "birthday.\(index)", minuteOffset: index)
  }
  let maintenance = ReminderCandidate(
    identifier: "birthday.maintenance",
    birthdayId: nil,
    kind: .maintenance,
    triggerDate: notificationPlanStart.addingTimeInterval(86_400),
    title: "请更新生日提醒",
    body: "打开岁时继续安排。"
  )
  return ReminderPlan(
    birthdayNotifications: items,
    maintenanceNotification: maintenance,
    coverageEnd: items.last?.triggerDate
  )
}

@Test func removesOnlyBirthdayNamespaceAfterAddingPlan() async throws {
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingIdentifiers: ["other.app", "birthday.old"]
  )

  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 2))

  #expect(await center.capturedRemoved() == ["birthday.old"])
  #expect(await center.capturedAdded().count == 3)
  #expect(health.state == .scheduled)
  #expect(health.scheduledCount == 3)
  #expect(health.coverageEnd == notificationPlanStart.addingTimeInterval(60))
}

@Test func emptyPlanClearsOnlyBirthdayNamespace() async throws {
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingIdentifiers: ["birthday.first", "other.app", "birthday.second"]
  )
  let plan = ReminderPlan(birthdayNotifications: [], maintenanceNotification: nil, coverageEnd: nil)

  let health = try await UserNotificationScheduler(center: center).apply(plan)

  #expect(await center.capturedRemoved() == ["birthday.first", "birthday.second"])
  #expect(await center.capturedAdded().isEmpty)
  #expect(health.state == .scheduled)
  #expect(health.scheduledCount == 0)
  #expect(health.coverageEnd == nil)
}

@Test(arguments: [NotificationAuthorization.denied, .notDetermined])
func unavailableAuthorizationDoesNotSchedule(_ authorization: NotificationAuthorization) async throws {
  let center = FakeNotificationCenterClient(
    authorization: authorization,
    pendingIdentifiers: ["birthday.old"]
  )

  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 2))

  #expect(health.state == (authorization == .denied ? .permissionDenied : .notRequested))
  #expect(health.scheduledCount == 0)
  #expect(health.coverageEnd == nil)
  #expect(await center.capturedAdded().isEmpty)
  #expect(await center.capturedRemoved().isEmpty)
}

@Test func provisionalAuthorizationSchedulesPlan() async throws {
  let center = FakeNotificationCenterClient(authorization: .provisional, pendingIdentifiers: [])

  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 1))

  #expect(health.state == .scheduled)
  #expect(health.scheduledCount == 2)
  #expect(health.coverageEnd == notificationPlanStart)
}

@Test func addFailurePreservesExistingBirthdayNotifications() async throws {
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingIdentifiers: ["birthday.old", "other.app"],
    failOnAddIndex: 1
  )

  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 2))

  #expect(health.state == .failed)
  #expect(health.scheduledCount == 0)
  #expect(health.coverageEnd == nil)
  #expect(health.errorCategory == "schedule_failed")
  #expect(await center.capturedAdded().count == 1)
  #expect(await center.capturedRemoved().isEmpty)
}

@Test func rejectsCandidatesOutsideBirthdayNamespace() async throws {
  let center = FakeNotificationCenterClient(authorization: .authorized, pendingIdentifiers: ["birthday.old"])
  let plan = ReminderPlan(
    birthdayNotifications: [notificationCandidate(identifier: "other.app", minuteOffset: 0)],
    maintenanceNotification: nil,
    coverageEnd: notificationPlanStart
  )

  let health = try await UserNotificationScheduler(center: center).apply(plan)

  #expect(health.state == .failed)
  #expect(health.errorCategory == "invalid_identifier")
  #expect(await center.capturedAdded().isEmpty)
  #expect(await center.capturedRemoved().isEmpty)
}

@Test func systemRequestUsesCurrentWallClockComponentsAndDoesNotRepeat() {
  let candidate = notificationCandidate(identifier: "birthday.date-components", minuteOffset: 123)

  let request = SystemNotificationCenterClient.request(for: candidate)
  let trigger = try! #require(request.trigger as? UNCalendarNotificationTrigger)
  let expected = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: candidate.triggerDate)

  #expect(trigger.dateComponents.year == expected.year)
  #expect(trigger.dateComponents.month == expected.month)
  #expect(trigger.dateComponents.day == expected.day)
  #expect(trigger.dateComponents.hour == expected.hour)
  #expect(trigger.dateComponents.minute == expected.minute)
  #expect(trigger.repeats == false)
}
