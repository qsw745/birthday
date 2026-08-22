import Foundation
import Testing

@testable import BirthdayCore

@Test func triggerGateCoalescesConcurrentRequests() async {
  let gate = SyncTriggerGate()

  #expect(await gate.begin() == true)
  #expect(await gate.begin() == false)
  await gate.end()
  #expect(await gate.begin() == true)
}

@Test func requestCoordinatorCoalescesConcurrentTriggersAndKeepsRequiredOrder() async throws {
  let probe = SyncTriggerProbe(holdFirstSync: true)
  let coordinator = makeCoordinator(probe: probe)

  let first = Task { try await coordinator.request(.foreground) }
  await probe.waitForFirstSync()
  let coalesced = try await coordinator.request(.networkRestored)
  await probe.allowFirstSync()
  let completed = try await first.value

  #expect(coalesced == .coalesced)
  #expect(completed.summary == syncTriggerSummary)
  #expect(completed.notificationHealth?.state == .scheduled)
  #expect(completed.activeBirthdays?.map(\.name) == ["妈妈"])
  #expect(await probe.events() == ["sync", "load", "schedule"])
}

@Test func requestCoordinatorKeepsGateLeasedUntilPublicationFinishes() async throws {
  let probe = SyncTriggerProbe(holdFirstPublication: true)
  let coordinator = makeCoordinator(
    probe: probe,
    publish: { outcome in await probe.publish(outcome) }
  )

  let first = Task { try await coordinator.request(.foreground) }
  await probe.waitForFirstPublication()
  let second = try await coordinator.request(.manual)
  await probe.allowFirstPublication()

  #expect(second == .coalesced)
  #expect(try await first.value.summary == syncTriggerSummary)
  #expect(await probe.events() == ["sync", "load", "schedule", "publish"])
}

@Test func requestCoordinatorReturnsUnboundWithoutSyncing() async throws {
  let probe = SyncTriggerProbe()
  let coordinator = makeCoordinator(probe: probe, bound: false)

  #expect(try await coordinator.request(.appLaunch) == .unbound)
  #expect(await probe.events().isEmpty)
}

@Test func requestCoordinatorReleasesGateAfterFailure() async throws {
  let probe = SyncTriggerProbe(failFirstSync: true)
  let coordinator = makeCoordinator(probe: probe)

  do {
    _ = try await coordinator.request(.manual)
    Issue.record("第一次同步应该失败")
  } catch let error as SyncTriggerTestError {
    #expect(error == .syncFailed)
  }

  let retry = try await coordinator.request(.manual)
  #expect(retry.summary == syncTriggerSummary)
  #expect(await probe.events() == ["sync", "sync", "load", "schedule"])
}

@Test func requestCoordinatorPublishesFailedNotificationHealthAfterSuccessfulSync() async throws {
  let probe = SyncTriggerProbe(notificationFails: true)
  let coordinator = makeCoordinator(probe: probe)

  let outcome = try await coordinator.request(.localMutation)

  #expect(outcome.summary == syncTriggerSummary)
  #expect(outcome.notificationHealth?.state == .failed)
  #expect(outcome.notificationHealth?.errorCategory == "schedule_failed")
  #expect(await probe.events() == ["sync", "load", "schedule"])
}

@Test func cancelledBackgroundRequestDoesNotPretendToSucceedAndReleasesGate() async throws {
  let probe = SyncTriggerProbe(holdFirstSync: true)
  let coordinator = makeCoordinator(probe: probe)
  let request = Task { try await coordinator.request(.backgroundRefresh) }
  await probe.waitForFirstSync()
  request.cancel()
  await probe.allowFirstSync()

  do {
    _ = try await request.value
    Issue.record("已取消的后台请求不能报告成功")
  } catch is CancellationError {}

  let retry = try await coordinator.request(.backgroundRefresh)
  #expect(retry.summary == syncTriggerSummary)
  #expect(await probe.events() == ["sync", "sync", "load", "schedule"])
}

@Test func networkRestorationRequiresAnAdjacentUnsatisfiedToSatisfiedTransition() {
  var transition = NetworkRestorationTransition()

  #expect(transition.receive(.satisfied) == false)
  #expect(transition.receive(.unsatisfied) == false)
  #expect(transition.receive(.requiresConnection) == false)
  #expect(transition.receive(.satisfied) == false)
  #expect(transition.receive(.unsatisfied) == false)
  #expect(transition.receive(.satisfied) == true)
}

@Test func networkMonitorLifecycleCreatesNewMonitorOnlyWhileActive() {
  var lifecycle = NetworkRestorationMonitorLifecycle()

  #expect(lifecycle.update(isActive: false) == .none)
  #expect(lifecycle.update(isActive: true) == .startNewMonitor)
  #expect(lifecycle.update(isActive: true) == .none)
  #expect(lifecycle.update(isActive: false) == .stopMonitor)
  #expect(lifecycle.update(isActive: false) == .none)
  #expect(lifecycle.update(isActive: true) == .startNewMonitor)
}

@Test func networkDisabledRuntimeUsesOfflineCompositionWithoutRemoteOrSystemTriggers() {
  let disabled = SyncRuntimeCompositionPolicy(isUITesting: false, networkDisabled: true)
  let enabled = SyncRuntimeCompositionPolicy(isUITesting: false, networkDisabled: false)

  #expect(disabled.mode == .offline)
  #expect(disabled.allowsRemoteSyncComposition == false)
  #expect(disabled.allowsSystemSyncTriggers == false)
  #expect(enabled.mode == .networked)
  #expect(enabled.allowsRemoteSyncComposition)
  #expect(enabled.allowsSystemSyncTriggers)
}

@Test func backgroundRefreshPolicyIsOpportunisticAndSixHoursOut() {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let policy = BackgroundRefreshPolicy()

  #expect(policy.nextEarliestBeginDate(after: now) == now.addingTimeInterval(6 * 60 * 60))
  #expect(policy.isOpportunistic)
}

@Test func backgroundRefreshRunnerWaitsForReadyRuntimeBeforeRunningWork() async {
  let runner = BackgroundRefreshRunner()
  let readiness = BackgroundRefreshReadiness()
  let probe = BackgroundRefreshProbe()
  let work = Task {
    await runner.run(readiness: readiness) {
      await probe.recordRun()
      return .outcome(.unbound)
    }
  }

  await Task.yield()
  await Task.yield()
  #expect(await probe.runCount() == 0)

  await readiness.markReady()
  #expect(await work.value)
  #expect(await probe.runCount() == 1)
}

@Test func backgroundRefreshRunnerCancellationWhileWaitingForReadinessFailsCompletion() async {
  let runner = BackgroundRefreshRunner()
  let readiness = BackgroundRefreshReadiness()
  let probe = BackgroundRefreshProbe()
  let work = Task {
    await runner.run(readiness: readiness) {
      await probe.recordRun()
      return .outcome(.unbound)
    }
  }

  await Task.yield()
  work.cancel()

  #expect(await work.value == false)
  await readiness.markReady()
  await Task.yield()
  #expect(await probe.runCount() == 0)
}

@Test func backgroundRefreshRunnerCompletesOnlyReadyUnboundOrReadyBoundWork() async {
  let runner = BackgroundRefreshRunner()
  let readiness = BackgroundRefreshReadiness()
  await readiness.markReady()

  #expect(await runner.run(readiness: readiness) { .outcome(.unbound) })
  #expect(
    await runner.run(readiness: readiness) {
      .outcome(
        .completed(
          syncTriggerSummary,
          [],
          NotificationHealth(
            state: .scheduled,
            scheduledCount: 0,
            coverageEnd: nil,
            errorCategory: nil
          )
        )
      )
    }
  )
  #expect(await runner.run(readiness: readiness) { .notReady } == false)
  #expect(await runner.run(readiness: readiness) { .outcome(.coalesced) } == false)
  #expect(
    await runner.run(readiness: readiness) {
      throw SyncTriggerTestError.syncFailed
    } == false
  )
}

private let syncTriggerNow = Date(timeIntervalSince1970: 1_800_000_000)
private let syncTriggerTimeZone = TimeZone(identifier: "Asia/Shanghai")!
private let syncTriggerSummary = SyncSummary(uploaded: 2, downloaded: 3, conflicts: 1, cursor: 7)

private enum SyncTriggerTestError: Error, Equatable {
  case syncFailed
  case notificationFailed
}

private struct SyncTriggerCalculator: LunarBirthdayCalculating {
  func nextOccurrence(
    of birthday: LunarBirthday,
    reminderMinutes: Int,
    after now: Date,
    in timeZone: TimeZone
  ) throws -> Date {
    now.addingTimeInterval(86_400)
  }
}

private actor SyncTriggerProbe {
  private var recordedEvents: [String] = []
  private var failFirstSync: Bool
  private let notificationFails: Bool
  private var holdFirstSync = false
  private var firstSyncStarted: CheckedContinuation<Void, Never>?
  private var firstSyncResumption: CheckedContinuation<Void, Never>?
  private var holdFirstPublication = false
  private var firstPublicationStarted: CheckedContinuation<Void, Never>?
  private var firstPublicationResumption: CheckedContinuation<Void, Never>?

  init(
    failFirstSync: Bool = false,
    notificationFails: Bool = false,
    holdFirstSync: Bool = false,
    holdFirstPublication: Bool = false
  ) {
    self.failFirstSync = failFirstSync
    self.notificationFails = notificationFails
    self.holdFirstSync = holdFirstSync
    self.holdFirstPublication = holdFirstPublication
  }

  func synchronize() async throws -> SyncSummary {
    recordedEvents.append("sync")
    if holdFirstSync {
      holdFirstSync = false
      firstSyncStarted?.resume()
      firstSyncStarted = nil
      await withCheckedContinuation { firstSyncResumption = $0 }
    }
    if failFirstSync {
      failFirstSync = false
      throw SyncTriggerTestError.syncFailed
    }
    return syncTriggerSummary
  }

  func loadActiveBirthdays() -> [BirthdayRecord] {
    recordedEvents.append("load")
    return [
      .fixture(
        id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        name: "妈妈",
        month: 8,
        day: 15
      )
    ]
  }

  func applyNotifications(_ plan: ReminderPlan) throws -> NotificationHealth {
    recordedEvents.append("schedule")
    if notificationFails { throw SyncTriggerTestError.notificationFailed }
    return NotificationHealth(
      state: .scheduled,
      scheduledCount: plan.birthdayNotifications.count,
      coverageEnd: plan.coverageEnd,
      errorCategory: nil
    )
  }

  func publish(_ outcome: SyncRequestOutcome) async {
    guard outcome.summary == syncTriggerSummary else { return }
    recordedEvents.append("publish")
    if holdFirstPublication {
      holdFirstPublication = false
      firstPublicationStarted?.resume()
      firstPublicationStarted = nil
      await withCheckedContinuation { firstPublicationResumption = $0 }
    }
  }

  func waitForFirstSync() async {
    guard recordedEvents.isEmpty else { return }
    await withCheckedContinuation { firstSyncStarted = $0 }
  }

  func allowFirstSync() {
    firstSyncResumption?.resume()
    firstSyncResumption = nil
  }

  func waitForFirstPublication() async {
    guard !recordedEvents.contains("publish") else { return }
    await withCheckedContinuation { firstPublicationStarted = $0 }
  }

  func allowFirstPublication() {
    firstPublicationResumption?.resume()
    firstPublicationResumption = nil
  }

  func events() -> [String] { recordedEvents }
}

private func makeCoordinator(
  probe: SyncTriggerProbe,
  bound: Bool = true,
  publish: @escaping @Sendable (SyncRequestOutcome) async -> Void = { _ in }
) -> SyncRequestCoordinator {
  return SyncRequestCoordinator(
    isBound: { bound },
    synchronize: { try await probe.synchronize() },
    loadActiveBirthdays: { await probe.loadActiveBirthdays() },
    planner: ReminderPlanner(calculator: SyncTriggerCalculator()),
    notificationScheduler: SyncTriggerNotificationScheduler(probe: probe),
    now: { syncTriggerNow },
    timeZone: { syncTriggerTimeZone },
    publish: publish
  )
}

private struct SyncTriggerNotificationScheduler: NotificationScheduling {
  let probe: SyncTriggerProbe

  func apply(_ plan: ReminderPlan) async throws -> NotificationHealth {
    try await probe.applyNotifications(plan)
  }
}

private actor BackgroundRefreshProbe {
  private var count = 0

  func recordRun() {
    count += 1
  }

  func runCount() -> Int { count }
}
