import Foundation

public enum SyncTrigger: String, CaseIterable, Equatable, Sendable {
  case appLaunch
  case foreground
  case networkRestored
  case localMutation
  case manual
  case backgroundRefresh
}

public enum SyncRequestOutcome: Equatable, Sendable {
  case completed(SyncSummary, [BirthdayRecord], NotificationHealth)
  case unbound
  case coalesced

  public var summary: SyncSummary? {
    guard case .completed(let summary, _, _) = self else { return nil }
    return summary
  }

  public var notificationHealth: NotificationHealth? {
    guard case .completed(_, _, let health) = self else { return nil }
    return health
  }

  public var activeBirthdays: [BirthdayRecord]? {
    guard case .completed(_, let records, _) = self else { return nil }
    return records
  }
}

/// Holds the single in-process lease for work that may start a sync request.
public actor SyncTriggerGate {
  private var running = false

  public init() {}

  public func begin() -> Bool {
    guard !running else { return false }
    running = true
    return true
  }

  public func end() {
    running = false
  }

  /// Runs one request exclusively and always releases the gate before returning or throwing.
  public func perform<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async rethrows -> T? {
    guard begin() else { return nil }
    defer { end() }
    return try await operation()
  }
}

/// Coordinates the side-effect order shared by foreground and background triggers.
///
/// The mobile target supplies the concrete `SyncEngine`, `BirthdayStore`, and system
/// notification scheduler. Keeping this workflow in the core package makes the gate,
/// cancellation, and notification ordering independently testable.
public actor SyncRequestCoordinator {
  private let gate: SyncTriggerGate
  private let isBound: @Sendable () async throws -> Bool
  private let synchronize: @Sendable () async throws -> SyncSummary
  private let loadActiveBirthdays: @Sendable () async throws -> [BirthdayRecord]
  private let planner: ReminderPlanner
  private let notificationScheduler: any NotificationScheduling
  private let now: @Sendable () -> Date
  private let timeZone: @Sendable () -> TimeZone
  private let publish: @Sendable (SyncRequestOutcome) async -> Void

  public init(
    gate: SyncTriggerGate = SyncTriggerGate(),
    isBound: @escaping @Sendable () async throws -> Bool,
    synchronize: @escaping @Sendable () async throws -> SyncSummary,
    loadActiveBirthdays: @escaping @Sendable () async throws -> [BirthdayRecord],
    planner: ReminderPlanner,
    notificationScheduler: any NotificationScheduling,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZone: @escaping @Sendable () -> TimeZone = { .current },
    publish: @escaping @Sendable (SyncRequestOutcome) async -> Void = { _ in }
  ) {
    self.gate = gate
    self.isBound = isBound
    self.synchronize = synchronize
    self.loadActiveBirthdays = loadActiveBirthdays
    self.planner = planner
    self.notificationScheduler = notificationScheduler
    self.now = now
    self.timeZone = timeZone
    self.publish = publish
  }

  public func request(_ trigger: SyncTrigger) async throws -> SyncRequestOutcome {
    _ = trigger
    try Task.checkCancellation()
    guard try await isBound() else { return .unbound }

    let synchronize = synchronize
    let loadActiveBirthdays = loadActiveBirthdays
    let planner = planner
    let notificationScheduler = notificationScheduler
    let now = now
    let timeZone = timeZone
    let publish = publish
    guard
      let outcome = try await gate.perform({
        try Task.checkCancellation()
        let summary = try await synchronize()
        try Task.checkCancellation()
        let records = try await loadActiveBirthdays()
        try Task.checkCancellation()

        let plan: ReminderPlan?
        do {
          plan = try planner.makePlan(records: records, now: now(), timeZone: timeZone())
        } catch {
          plan = nil
        }

        let health: NotificationHealth
        if let plan {
          try Task.checkCancellation()
          do {
            health = try await notificationScheduler.apply(plan)
          } catch {
            health = Self.failedNotificationHealth(category: "schedule_failed")
          }
        } else {
          health = Self.failedNotificationHealth(category: "plan_failed")
        }

        try Task.checkCancellation()
        let outcome = SyncRequestOutcome.completed(summary, records, health)
        await publish(outcome)
        try Task.checkCancellation()
        return outcome
      })
    else {
      return .coalesced
    }
    return outcome
  }

  private static func failedNotificationHealth(category: String) -> NotificationHealth {
    NotificationHealth(
      state: .failed,
      scheduledCount: 0,
      coverageEnd: nil,
      errorCategory: category
    )
  }
}

public enum NetworkPathState: Equatable, Sendable {
  case unsatisfied
  case requiresConnection
  case satisfied
}

/// Emits a restoration only for an adjacent `.unsatisfied` to `.satisfied` transition.
public struct NetworkRestorationTransition: Equatable, Sendable {
  private var previousState: NetworkPathState?

  public init() {}

  public mutating func receive(_ state: NetworkPathState) -> Bool {
    defer { previousState = state }
    return previousState == .unsatisfied && state == .satisfied
  }
}

public enum NetworkMonitorLifecycleCommand: Equatable, Sendable {
  case none
  case startNewMonitor
  case stopMonitor
}

/// Treats cancelled path monitors as terminal and asks the app composition to create a new one.
public struct NetworkRestorationMonitorLifecycle: Equatable, Sendable {
  private var isMonitoring = false

  public init() {}

  public mutating func update(isActive: Bool) -> NetworkMonitorLifecycleCommand {
    if isActive {
      guard !isMonitoring else { return .none }
      isMonitoring = true
      return .startNewMonitor
    }

    guard isMonitoring else { return .none }
    isMonitoring = false
    return .stopMonitor
  }
}

public struct SceneSyncGeneration: Equatable, Hashable, Sendable {
  fileprivate let value: UInt64
}

/// Makes ordinary foreground and network requests valid only for the active scene generation.
public struct SceneSyncRequestLifecycle: Equatable, Sendable {
  private var generation: UInt64 = 0
  private var isActive = false

  public init() {}

  @discardableResult
  public mutating func activate() -> SceneSyncGeneration {
    generation &+= 1
    isActive = true
    return SceneSyncGeneration(value: generation)
  }

  public mutating func invalidate() {
    generation &+= 1
    isActive = false
  }

  public var currentGeneration: SceneSyncGeneration? {
    guard isActive else { return nil }
    return SceneSyncGeneration(value: generation)
  }

  public func permits(_ candidate: SceneSyncGeneration) -> Bool {
    isActive && candidate.value == generation
  }
}

/// Owns cancellable foreground/network work for one active scene generation.
@MainActor
public final class SceneSyncRequestAdapter {
  private var lifecycle = SceneSyncRequestLifecycle()
  private var foregroundTask: Task<Void, Never>?
  private var networkTask: Task<Void, Never>?

  public init() {}

  public var currentGeneration: SceneSyncGeneration? {
    lifecycle.currentGeneration
  }

  @discardableResult
  public func activate(
    reload: @escaping @MainActor @Sendable () async -> Void,
    configure: @escaping @MainActor @Sendable (SceneSyncGeneration) async -> Void,
    request: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    foregroundTask?.cancel()
    networkTask?.cancel()
    let generation = lifecycle.activate()
    let task = Task { @MainActor [weak self] in
      await reload()
      guard let self, permits(generation), !Task.isCancelled else { return }
      await configure(generation)
      guard permits(generation), !Task.isCancelled else { return }
      await request()
    }
    foregroundTask = task
    return task
  }

  @discardableResult
  public func enqueueNetworkRestoration(
    for generation: SceneSyncGeneration,
    request: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never>? {
    guard lifecycle.permits(generation) else { return nil }
    networkTask?.cancel()
    let task = Task { @MainActor [weak self] in
      guard let self, permits(generation), !Task.isCancelled else { return }
      await request()
    }
    networkTask = task
    return task
  }

  public func invalidate() {
    lifecycle.invalidate()
    foregroundTask?.cancel()
    foregroundTask = nil
    networkTask?.cancel()
    networkTask = nil
  }

  public func permits(_ generation: SceneSyncGeneration) -> Bool {
    lifecycle.permits(generation)
  }
}

public enum SyncRuntimeMode: Equatable, Sendable {
  case offline
  case networked
}

/// Defines whether app composition may construct remote sync dependencies or system sync triggers.
public struct SyncRuntimeCompositionPolicy: Equatable, Sendable {
  public let mode: SyncRuntimeMode

  public init(isUITesting: Bool, networkDisabled: Bool) {
    mode = isUITesting || networkDisabled ? .offline : .networked
  }

  public var allowsRemoteSyncComposition: Bool { mode == .networked }
  public var allowsSystemSyncTriggers: Bool { mode == .networked }
}

/// Installs the persistent background runtime after local bootstrap, independently of scene state.
@MainActor
public struct SyncRootRuntimeBootstrapper {
  private let policy: SyncRuntimeCompositionPolicy

  public init(policy: SyncRuntimeCompositionPolicy) {
    self.policy = policy
  }

  public func bootstrap(
    reload: @escaping @MainActor @Sendable () async -> Void,
    installRuntime: @escaping @MainActor @Sendable () async -> Void,
    sceneIsActive: @escaping @MainActor @Sendable () -> Bool,
    activateOrdinaryTriggers: @escaping @MainActor @Sendable () -> Void
  ) async {
    await reload()
    guard policy.allowsRemoteSyncComposition else { return }
    await installRuntime()
    guard sceneIsActive() else { return }
    activateOrdinaryTriggers()
  }
}

/// Background refresh is an opportunity requested after six hours, never a deadline.
public struct BackgroundRefreshPolicy: Equatable, Sendable {
  public static let delay: TimeInterval = 6 * 60 * 60

  public init() {}

  public var isOpportunistic: Bool { true }

  public func nextEarliestBeginDate(after now: Date) -> Date {
    now.addingTimeInterval(Self.delay)
  }
}

/// Converts a best-effort background sync into the success flag expected by a scheduler.
/// Cancellation and failures remain failures; an unbound device is a valid no-work completion.
public enum BackgroundRefreshWorkResult: Equatable, Sendable {
  case notReady
  case outcome(SyncRequestOutcome)
}

/// Lets a cold-launched background task wait for app runtime installation without treating it as unbound.
public actor BackgroundRefreshReadiness {
  private var isReady = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var cancelledWaiters: Set<UUID> = []

  public init() {}

  public func markReady() {
    isReady = true
    let pending = waiters.values
    waiters.removeAll()
    cancelledWaiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }

  public func waitUntilReady() async throws {
    guard !isReady else { return }
    let id = UUID()

    await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { continuation in
          if isReady || cancelledWaiters.remove(id) != nil {
            continuation.resume()
          } else {
            waiters[id] = continuation
          }
        }
      },
      onCancel: {
        Task { await self.cancelWaiter(id) }
      })

    cancelledWaiters.remove(id)
    try Task.checkCancellation()
  }

  private func cancelWaiter(_ id: UUID) {
    guard !isReady else { return }
    if let waiter = waiters.removeValue(forKey: id) {
      waiter.resume()
    } else {
      cancelledWaiters.insert(id)
    }
  }
}

public actor BackgroundRefreshRunner {
  public init() {}

  public func run(
    readiness: BackgroundRefreshReadiness,
    _ sync: @Sendable () async throws -> BackgroundRefreshWorkResult
  ) async -> Bool {
    do {
      try await readiness.waitUntilReady()
      try Task.checkCancellation()
      let result = try await sync()
      try Task.checkCancellation()
      switch result {
      case .notReady:
        return false
      case .outcome(let outcome):
        switch outcome {
        case .completed, .unbound:
          return true
        case .coalesced:
          return false
        }
      }
    } catch {
      return false
    }
  }
}
