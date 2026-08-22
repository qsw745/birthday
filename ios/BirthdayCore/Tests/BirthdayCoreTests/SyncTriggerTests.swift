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
  #expect(await probe.waitForFirstPublication())
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

@Test func requestCoordinatorPublishesPlannerFailureBeforeReleasingManualRequestGate() async throws
{
  let probe = SyncTriggerProbe(holdFirstPublication: true)
  let presentation = ManualSyncPresentationProbe()
  let coordinator = makeCoordinator(
    probe: probe,
    reminderPlanner: ReminderPlanner(calculator: SyncTriggerFailingCalculator()),
    publish: { outcome in
      await presentation.publish(outcome)
      await probe.publish(outcome)
    }
  )

  let first = Task {
    let outcome = try await coordinator.request(.manual)
    await presentation.finishManualRequest()
    return outcome
  }
  #expect(await probe.waitForFirstPublication())
  #expect(await presentation.state().manualStatus == .syncing)
  let second = try await coordinator.request(.foreground)
  await probe.allowFirstPublication()
  let outcome = try await first.value
  let state = await presentation.state()

  #expect(second == .coalesced)
  #expect(outcome.summary == syncTriggerSummary)
  #expect(outcome.activeBirthdays?.map(\.name) == ["妈妈"])
  #expect(outcome.notificationHealth?.errorCategory == "plan_failed")
  #expect(state.summary == syncTriggerSummary)
  #expect(state.activeBirthdayNames == ["妈妈"])
  #expect(state.health?.errorCategory == "plan_failed")
  #expect(state.manualStatus == .synchronized)
  #expect(await probe.events() == ["sync", "load", "publish"])
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

@Test func sceneGenerationRejectsForegroundRequestAfterAwaitWhenSceneBecomesInactive() {
  var lifecycle = SceneSyncRequestLifecycle()
  let activeGeneration = lifecycle.activate()

  #expect(lifecycle.permits(activeGeneration))
  lifecycle.invalidate()
  #expect(lifecycle.permits(activeGeneration) == false)
}

@Test func sceneGenerationRejectsQueuedNetworkCallbackAfterSceneBecomesInactive() {
  var lifecycle = SceneSyncRequestLifecycle()
  _ = lifecycle.activate()
  let queuedNetworkGeneration = lifecycle.currentGeneration

  lifecycle.invalidate()

  #expect(queuedNetworkGeneration != nil)
  #expect(lifecycle.permits(queuedNetworkGeneration!) == false)
}

@Test
@MainActor
func sceneRequestAdapterStopsForegroundFlowAfterEveryAwaitBoundary() async throws {
  for suspension in SceneSyncAdapterProbe.Suspension.allCases {
    let probe = SceneSyncAdapterProbe(suspension: suspension)
    let adapter = SceneSyncRequestAdapter()
    let task = adapter.activate(
      reload: { await probe.reload() },
      configure: { _ in await probe.configure() },
      request: { await probe.request("foreground") }
    )

    #expect(await probe.waitUntilSuspended())
    adapter.invalidate()
    await probe.resume()
    await task.value
    #expect(await probe.requestCount() == 0)

    switch suspension {
    case .reload:
      #expect(await probe.events() == ["reload"])
    case .configure:
      #expect(await probe.events() == ["reload", "configure"])
    }
  }
}

@Test
@MainActor
func sceneRequestAdapterRejectsQueuedNetworkWorkAndAcceptsOnlyNewActiveGeneration() async throws {
  let probe = SceneSyncAdapterProbe()
  let adapter = SceneSyncRequestAdapter()
  let first = adapter.activate(
    reload: {},
    configure: { _ in },
    request: { await probe.request("first-foreground") }
  )
  let staleGeneration = try #require(adapter.currentGeneration)
  await first.value

  let staleNetwork = adapter.enqueueNetworkRestoration(for: staleGeneration) {
    await probe.request("stale-network")
  }
  adapter.invalidate()
  await staleNetwork?.value
  #expect(await probe.requestCount(named: "stale-network") == 0)

  let second = adapter.activate(
    reload: {},
    configure: { _ in },
    request: { await probe.request("second-foreground") }
  )
  let activeGeneration = try #require(adapter.currentGeneration)
  await second.value
  let activeNetwork = try #require(
    adapter.enqueueNetworkRestoration(for: activeGeneration) {
      await probe.request("active-network")
    })
  await activeNetwork.value

  #expect(staleGeneration != activeGeneration)
  #expect(
    await probe.events() == ["first-foreground", "second-foreground", "active-network"]
  )
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

@Test
@MainActor
func coldBackgroundRootBootstrapMakesBackgroundRuntimeReadyWithoutOrdinaryTriggers() async {
  let readiness = BackgroundRefreshReadiness()
  let runner = BackgroundRefreshRunner()
  let backgroundProbe = BackgroundRefreshProbe()
  let bootstrapProbe = RootSyncBootstrapProbe()
  let backgroundWork = Task {
    await runner.run(readiness: readiness) {
      await backgroundProbe.recordRun()
      return .outcome(.unbound)
    }
  }
  let bootstrapper = SyncRootRuntimeBootstrapper(
    policy: SyncRuntimeCompositionPolicy(isUITesting: false, networkDisabled: false)
  )

  await bootstrapper.bootstrap(
    reload: { bootstrapProbe.reload() },
    installRuntime: {
      bootstrapProbe.installRuntime()
      await readiness.markReady()
    },
    sceneIsActive: { false },
    activateOrdinaryTriggers: { bootstrapProbe.activateOrdinaryTriggers() }
  )

  let backgroundDidRun = await backgroundProbe.waitForRun()
  #expect(backgroundDidRun)
  if !backgroundDidRun { backgroundWork.cancel() }
  #expect(await backgroundWork.value)
  #expect(bootstrapProbe.events == ["reload", "install-runtime"])
  #expect(bootstrapProbe.monitorStartCount == 0)
  #expect(bootstrapProbe.foregroundRequestCount == 0)
  #expect(bootstrapProbe.networkRequestCount == 0)
}

@Test
@MainActor
func rootBootstrapKeepsRemoteRuntimeOutOfOfflineCompositions() async {
  for policy in [
    SyncRuntimeCompositionPolicy(isUITesting: true, networkDisabled: true),
    SyncRuntimeCompositionPolicy(isUITesting: false, networkDisabled: true),
  ] {
    let probe = RootSyncBootstrapProbe()
    let bootstrapper = SyncRootRuntimeBootstrapper(policy: policy)

    await bootstrapper.bootstrap(
      reload: { probe.reload() },
      installRuntime: { probe.installRuntime() },
      sceneIsActive: { true },
      activateOrdinaryTriggers: { probe.activateOrdinaryTriggers() }
    )

    #expect(probe.events == ["reload"])
    #expect(probe.installRuntimeCount == 0)
    #expect(probe.monitorStartCount == 0)
    #expect(probe.foregroundRequestCount == 0)
    #expect(probe.networkRequestCount == 0)
  }
}

@Test
@MainActor
func activeRootBootstrapInstallsRuntimeBeforeActivatingOrdinaryTriggers() async {
  let probe = RootSyncBootstrapProbe()
  let bootstrapper = SyncRootRuntimeBootstrapper(
    policy: SyncRuntimeCompositionPolicy(isUITesting: false, networkDisabled: false)
  )

  await bootstrapper.bootstrap(
    reload: { probe.reload() },
    installRuntime: { probe.installRuntime() },
    sceneIsActive: { true },
    activateOrdinaryTriggers: { probe.activateOrdinaryTriggers() }
  )

  #expect(
    probe.events == [
      "reload", "install-runtime", "start-monitor", "foreground-request",
    ])
  #expect(probe.installRuntimeCount == 1)
  #expect(probe.monitorStartCount == 1)
  #expect(probe.foregroundRequestCount == 1)
  #expect(probe.networkRequestCount == 0)
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
  case plannerFailed
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

private struct SyncTriggerFailingCalculator: LunarBirthdayCalculating {
  func nextOccurrence(
    of birthday: LunarBirthday,
    reminderMinutes: Int,
    after now: Date,
    in timeZone: TimeZone
  ) throws -> Date {
    throw SyncTriggerTestError.plannerFailed
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

  func waitForFirstPublication() async -> Bool {
    for _ in 0..<1_000 {
      if recordedEvents.contains("publish") { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
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
  reminderPlanner: ReminderPlanner = ReminderPlanner(calculator: SyncTriggerCalculator()),
  publish: @escaping @Sendable (SyncRequestOutcome) async -> Void = { _ in }
) -> SyncRequestCoordinator {
  return SyncRequestCoordinator(
    isBound: { bound },
    synchronize: { try await probe.synchronize() },
    loadActiveBirthdays: { await probe.loadActiveBirthdays() },
    planner: reminderPlanner,
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

  func waitForRun() async -> Bool {
    for _ in 0..<1_000 {
      if count > 0 { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }
}

@MainActor
private final class RootSyncBootstrapProbe {
  private(set) var events: [String] = []
  private(set) var installRuntimeCount = 0
  private(set) var monitorStartCount = 0
  private(set) var foregroundRequestCount = 0
  private(set) var networkRequestCount = 0

  func reload() {
    events.append("reload")
  }

  func installRuntime() {
    installRuntimeCount += 1
    events.append("install-runtime")
  }

  func activateOrdinaryTriggers() {
    monitorStartCount += 1
    events.append("start-monitor")
    foregroundRequestCount += 1
    events.append("foreground-request")
  }
}

private actor ManualSyncPresentationProbe {
  struct State: Equatable {
    var summary: SyncSummary?
    var activeBirthdayNames: [String]
    var health: NotificationHealth?
    var manualStatus: ManualStatus
  }

  enum ManualStatus: Equatable {
    case syncing
    case synchronized
  }

  private var snapshot = State(
    summary: nil,
    activeBirthdayNames: [],
    health: nil,
    manualStatus: .syncing
  )

  func publish(_ outcome: SyncRequestOutcome) {
    guard case .completed(let summary, let records, let health) = outcome else { return }
    snapshot.summary = summary
    snapshot.activeBirthdayNames = records.map(\.name)
    snapshot.health = health
  }

  func finishManualRequest() {
    snapshot.manualStatus = .synchronized
  }

  func state() -> State { snapshot }
}

private actor SceneSyncAdapterProbe {
  enum Suspension: CaseIterable {
    case reload
    case configure
  }

  private let suspension: Suspension?
  private var recordedEvents: [String] = []
  private var suspended = false
  private var resumption: CheckedContinuation<Void, Never>?

  init(suspension: Suspension? = nil) {
    self.suspension = suspension
  }

  func reload() async {
    recordedEvents.append("reload")
    guard suspension == .reload else { return }
    await suspend()
  }

  func configure() async {
    recordedEvents.append("configure")
    guard suspension == .configure else { return }
    await suspend()
  }

  func request(_ event: String) {
    recordedEvents.append(event)
  }

  func waitUntilSuspended() async -> Bool {
    for _ in 0..<1_000 {
      if suspended { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func resume() {
    resumption?.resume()
    resumption = nil
  }

  func events() -> [String] { recordedEvents }

  func requestCount(named name: String? = nil) -> Int {
    recordedEvents.filter { event in
      if let name { return event == name }
      return event != "reload" && event != "configure"
    }.count
  }

  private func suspend() async {
    suspended = true
    await withCheckedContinuation { resumption = $0 }
  }
}
