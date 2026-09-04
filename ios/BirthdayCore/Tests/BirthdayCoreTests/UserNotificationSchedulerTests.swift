import Foundation
import Testing
import UserNotifications

@testable import BirthdayCore

private enum FakeNotificationError: Error {
  case addFailed
  case capacityExceeded
}

private actor FakeNotificationCenterClient: NotificationCenterClient {
  let configuredAuthorization: NotificationAuthorization
  let failOnAddAttempt: Int?
  let capacity: Int
  let silentlyDroppedIdentifiers: Set<String>
  private var removedIdentifiers: [String] = []
  private var addedRequests: [NotificationRequestSnapshot] = []
  private var pending: [String: NotificationRequestSnapshot]
  private var addAttempt = 0
  private var maximumPendingCount: Int

  init(
    authorization: NotificationAuthorization,
    pendingRequests: [NotificationRequestSnapshot],
    failOnAddAttempt: Int? = nil,
    capacity: Int = 64,
    silentlyDroppedIdentifiers: Set<String> = []
  ) {
    configuredAuthorization = authorization
    self.failOnAddAttempt = failOnAddAttempt
    self.capacity = capacity
    self.silentlyDroppedIdentifiers = silentlyDroppedIdentifiers
    pending = Dictionary(uniqueKeysWithValues: pendingRequests.map { ($0.identifier, $0) })
    maximumPendingCount = pending.count
  }

  func authorization() async -> NotificationAuthorization { configuredAuthorization }

  func pendingRequests() async -> [NotificationRequestSnapshot] {
    pending.values.sorted { $0.identifier < $1.identifier }
  }

  func remove(identifiers: [String]) async {
    removedIdentifiers.append(contentsOf: identifiers)
    for identifier in identifiers { pending.removeValue(forKey: identifier) }
  }

  func add(_ request: NotificationRequestSnapshot) async throws {
    addAttempt += 1
    if addAttempt == failOnAddAttempt { throw FakeNotificationError.addFailed }
    if pending[request.identifier] == nil, pending.count >= capacity {
      throw FakeNotificationError.capacityExceeded
    }
    addedRequests.append(request)
    guard !silentlyDroppedIdentifiers.contains(request.identifier) else { return }
    pending[request.identifier] = request
    maximumPendingCount = max(maximumPendingCount, pending.count)
  }

  func capturedRemoved() -> [String] { removedIdentifiers }
  func capturedAdded() -> [NotificationRequestSnapshot] { addedRequests }
  func capturedPendingRequests() -> [NotificationRequestSnapshot] {
    pending.values.sorted { $0.identifier < $1.identifier }
  }
  func capturedMaximumPendingCount() -> Int { maximumPendingCount }
}

private actor InterleavingNotificationCenterClient: NotificationCenterClient {
  private var pending: [String: NotificationRequestSnapshot] = [:]
  private var addCount = 0
  private var firstAddWaiter: CheckedContinuation<Void, Never>?
  private var resumeFirstAdd: CheckedContinuation<Void, Never>?

  func authorization() async -> NotificationAuthorization { .authorized }
  func pendingRequests() async -> [NotificationRequestSnapshot] {
    pending.values.sorted { $0.identifier < $1.identifier }
  }
  func remove(identifiers: [String]) async {
    for identifier in identifiers { pending.removeValue(forKey: identifier) }
  }
  func add(_ request: NotificationRequestSnapshot) async throws {
    addCount += 1
    if addCount == 1 {
      firstAddWaiter?.resume()
      firstAddWaiter = nil
      await withCheckedContinuation { continuation in resumeFirstAdd = continuation }
    }
    pending[request.identifier] = request
  }
  func waitForFirstAdd() async {
    guard addCount == 0 else { return }
    await withCheckedContinuation { continuation in firstAddWaiter = continuation }
  }
  func allowFirstAdd() {
    resumeFirstAdd?.resume()
    resumeFirstAdd = nil
  }
  func hasSeenSecondAdd() -> Bool { addCount >= 2 }
}

private let notificationPlanStart = Date(timeIntervalSince1970: 1_800_000_000)

private func notificationCandidate(
  identifier: String,
  minuteOffset: Int,
  title: String = "生日提醒",
  body: String = "记得送上祝福。"
) -> ReminderCandidate {
  ReminderCandidate(
    identifier: identifier,
    birthdayId: UUID(),
    kind: .sameDay,
    triggerDate: notificationPlanStart.addingTimeInterval(TimeInterval(minuteOffset * 60)),
    title: title,
    body: body
  )
}

private func notificationRequest(
  identifier: String,
  minuteOffset: Int = 0,
  title: String = "旧标题",
  body: String = "旧内容"
) -> NotificationRequestSnapshot {
  NotificationRequestSnapshot(
    identifier: identifier,
    triggerDate: notificationPlanStart.addingTimeInterval(TimeInterval(minuteOffset * 60)),
    title: title,
    body: body
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

@Test func removesOnlyRollingBirthdayNamespaceAndAddsPlan() async throws {
  let immediate = notificationRequest(identifier: "birthday.immediate.keep")
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingRequests: [
      notificationRequest(identifier: "other.app"),
      notificationRequest(identifier: "birthday.old"),
      immediate,
    ]
  )

  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 2))
  let pending = await center.capturedPendingRequests()

  #expect(await center.capturedRemoved() == ["birthday.old"])
  #expect(await center.capturedAdded().count == 3)
  #expect(pending.contains(immediate))
  #expect(health.state == .scheduled)
  #expect(health.scheduledCount == 3)
  #expect(health.coverageEnd == notificationPlanStart.addingTimeInterval(60))
}

@Test func emptyPlanClearsOnlyRollingBirthdayNamespace() async throws {
  let immediate = notificationRequest(identifier: "birthday.immediate.keep")
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingRequests: [
      notificationRequest(identifier: "birthday.first"),
      notificationRequest(identifier: "other.app"),
      notificationRequest(identifier: "birthday.second"),
      immediate,
    ]
  )
  let plan = ReminderPlan(birthdayNotifications: [], maintenanceNotification: nil, coverageEnd: nil)

  let health = try await UserNotificationScheduler(center: center).apply(plan)

  #expect(await center.capturedRemoved() == ["birthday.first", "birthday.second"])
  #expect(await center.capturedAdded().isEmpty)
  #expect(await center.capturedPendingRequests().contains(immediate))
  #expect(health.state == .scheduled)
  #expect(health.scheduledCount == 0)
}

@Test func disablingNotificationsClearsEntireBirthdayNamespaceAndPreservesForeignRequests() async {
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingRequests: [
      notificationRequest(identifier: "birthday.rolling"),
      notificationRequest(identifier: "birthday.immediate.today"),
      notificationRequest(identifier: "other.app"),
    ]
  )

  let health = await UserNotificationScheduler(center: center).removeAllBirthdayNotifications()

  #expect(health.state == .scheduled)
  #expect(health.scheduledCount == 0)
  #expect(await center.capturedRemoved() == [
    "birthday.immediate.today", "birthday.rolling",
  ])
  #expect(await center.capturedPendingRequests().map(\.identifier) == ["other.app"])
}

@Test(arguments: [NotificationAuthorization.denied, .notDetermined])
func unavailableAuthorizationDoesNotSchedule(_ authorization: NotificationAuthorization) async throws {
  let center = FakeNotificationCenterClient(
    authorization: authorization,
    pendingRequests: [notificationRequest(identifier: "birthday.old")]
  )

  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 2))

  #expect(health.state == (authorization == .denied ? .permissionDenied : .notRequested))
  #expect(await center.capturedAdded().isEmpty)
  #expect(await center.capturedRemoved().isEmpty)
}

@Test func provisionalAuthorizationSchedulesPlan() async throws {
  let center = FakeNotificationCenterClient(authorization: .provisional, pendingRequests: [])
  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 1))
  #expect(health.state == .scheduled)
  #expect(health.scheduledCount == 2)
}

@Test func disjointSixtyOneRequestReplacementNeverExceedsConservativeCapacity() async throws {
  let oldRequests = (0..<61).map {
    notificationRequest(identifier: "birthday.old.\($0)", minuteOffset: $0)
  }
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingRequests: oldRequests,
    capacity: 64
  )

  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 60))

  #expect(health.state == .scheduled)
  #expect(health.scheduledCount == 61)
  #expect(await center.capturedMaximumPendingCount() <= 64)
  #expect(await center.capturedPendingRequests().count == 61)
}

@Test func replacementFailureRestoresCompleteOriginalRequestsEvenForSameIdentifier() async throws {
  let original = [
    notificationRequest(identifier: "birthday.0", title: "原始标题", body: "原始正文"),
    notificationRequest(identifier: "birthday.old", minuteOffset: 2),
  ]
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingRequests: original,
    failOnAddAttempt: 2
  )

  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 2))

  #expect(health.state == .failed)
  #expect(health.errorCategory == "schedule_failed")
  #expect(await center.capturedPendingRequests() == original.sorted { $0.identifier < $1.identifier })
}

@Test func silentSystemUnderRetentionFailsPostconditionAndRestoresSnapshot() async throws {
  let original = [notificationRequest(identifier: "birthday.old")]
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingRequests: original,
    silentlyDroppedIdentifiers: ["birthday.1"]
  )

  let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 2))

  #expect(health.state == .failed)
  #expect(health.errorCategory == "schedule_verification_failed")
  #expect(await center.capturedPendingRequests() == original)
}

@Test func rejectsCandidatesOutsideBirthdayNamespace() async throws {
  let center = FakeNotificationCenterClient(
    authorization: .authorized,
    pendingRequests: [notificationRequest(identifier: "birthday.old")]
  )
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

@Test func immediateReminderUsesSeparateInjectableNamespaceWithoutPermissionPrompt() async {
  let center = FakeNotificationCenterClient(authorization: .authorized, pendingRequests: [])
  let birthdayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

  let result = await OneShotNotificationScheduler(center: center).schedule(
    birthdayID: birthdayID,
    name: "妈妈",
    now: notificationPlanStart
  )
  let request = await center.capturedAdded().first

  #expect(result == .scheduled)
  #expect(request?.identifier.hasPrefix("birthday.immediate.") == true)
  #expect(request?.triggerDate == notificationPlanStart.addingTimeInterval(1))
  #expect(request?.title == "今天是妈妈的生日")
}

@Test func immediateReminderDoesNotScheduleWhenAuthorizationIsUnavailable() async {
  let center = FakeNotificationCenterClient(authorization: .notDetermined, pendingRequests: [])

  let result = await OneShotNotificationScheduler(center: center).schedule(
    birthdayID: UUID(),
    name: "妈妈",
    now: notificationPlanStart
  )

  #expect(result == .notAuthorized)
  #expect(await center.capturedAdded().isEmpty)
}

@Test func systemRequestUsesCurrentWallClockComponentsAndDoesNotRepeat() {
  let requestedTriggerDate = notificationPlanStart.addingTimeInterval(123 * 60 + 37.25)
  let expectedTriggerDate = notificationPlanStart.addingTimeInterval(123 * 60 + 38)
  let snapshot = NotificationRequestSnapshot(
    identifier: "birthday.date-components",
    triggerDate: requestedTriggerDate,
    title: "生日提醒",
    body: "记得送上祝福。"
  )
  let request = SystemNotificationCenterClient.request(for: snapshot)
  let trigger = try! #require(request.trigger as? UNCalendarNotificationTrigger)
  #expect(snapshot.triggerDate == expectedTriggerDate)
  let expected = Calendar.current.dateComponents(
    [.year, .month, .day, .hour, .minute, .second], from: expectedTriggerDate)
  #expect(trigger.dateComponents.year == expected.year)
  #expect(trigger.dateComponents.month == expected.month)
  #expect(trigger.dateComponents.day == expected.day)
  #expect(trigger.dateComponents.hour == expected.hour)
  #expect(trigger.dateComponents.minute == expected.minute)
  #expect(trigger.dateComponents.second == expected.second)
  #expect(trigger.repeats == false)
}

@Test func concurrentPlansLeaveOnlyTheLastSerializedPlan() async throws {
  let center = InterleavingNotificationCenterClient()
  let scheduler = UserNotificationScheduler(center: center)
  let firstPlan = ReminderPlan(
    birthdayNotifications: [notificationCandidate(identifier: "birthday.first", minuteOffset: 0)],
    maintenanceNotification: nil,
    coverageEnd: notificationPlanStart
  )
  let secondPlan = ReminderPlan(
    birthdayNotifications: [notificationCandidate(identifier: "birthday.second", minuteOffset: 1)],
    maintenanceNotification: nil,
    coverageEnd: notificationPlanStart.addingTimeInterval(60)
  )

  let firstApply = Task { try await scheduler.apply(firstPlan) }
  await center.waitForFirstAdd()
  let secondApply = Task { try await scheduler.apply(secondPlan) }
  for _ in 0..<100 where !(await center.hasSeenSecondAdd()) { await Task.yield() }
  await center.allowFirstAdd()

  _ = try await firstApply.value
  let secondHealth = try await secondApply.value

  #expect(secondHealth.state == .scheduled)
  #expect(secondHealth.scheduledCount == 1)
  #expect(secondHealth.coverageEnd == notificationPlanStart.addingTimeInterval(60))
  #expect(await center.pendingRequests().map(\.identifier) == ["birthday.second"])
}
