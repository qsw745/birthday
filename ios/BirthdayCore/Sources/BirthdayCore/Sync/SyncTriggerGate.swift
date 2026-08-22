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

  public init(
    gate: SyncTriggerGate = SyncTriggerGate(),
    isBound: @escaping @Sendable () async throws -> Bool,
    synchronize: @escaping @Sendable () async throws -> SyncSummary,
    loadActiveBirthdays: @escaping @Sendable () async throws -> [BirthdayRecord],
    planner: ReminderPlanner,
    notificationScheduler: any NotificationScheduling,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZone: @escaping @Sendable () -> TimeZone = { .current }
  ) {
    self.gate = gate
    self.isBound = isBound
    self.synchronize = synchronize
    self.loadActiveBirthdays = loadActiveBirthdays
    self.planner = planner
    self.notificationScheduler = notificationScheduler
    self.now = now
    self.timeZone = timeZone
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
    guard
      let outcome = try await gate.perform({
        try Task.checkCancellation()
        let summary = try await synchronize()
        try Task.checkCancellation()
        let records = try await loadActiveBirthdays()
        try Task.checkCancellation()

        let plan: ReminderPlan
        do {
          plan = try planner.makePlan(records: records, now: now(), timeZone: timeZone())
        } catch {
          return SyncRequestOutcome.completed(
            summary,
            records,
            Self.failedNotificationHealth(category: "plan_failed")
          )
        }

        try Task.checkCancellation()
        let health: NotificationHealth
        do {
          health = try await notificationScheduler.apply(plan)
        } catch {
          health = Self.failedNotificationHealth(category: "schedule_failed")
        }
        try Task.checkCancellation()
        return SyncRequestOutcome.completed(summary, records, health)
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

/// Emits a restoration only for a known `.unsatisfied` to `.satisfied` transition.
public struct NetworkRestorationTransition: Equatable, Sendable {
  private var wasSatisfied: Bool?

  public init() {}

  public mutating func receive(isSatisfied: Bool) -> Bool {
    defer { wasSatisfied = isSatisfied }
    return wasSatisfied == false && isSatisfied
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
public actor BackgroundRefreshRunner {
  public init() {}

  public func run(
    _ sync: @Sendable () async throws -> SyncRequestOutcome
  ) async -> Bool {
    do {
      try Task.checkCancellation()
      let outcome = try await sync()
      try Task.checkCancellation()
      switch outcome {
      case .completed, .unbound:
        return true
      case .coalesced:
        return false
      }
    } catch {
      return false
    }
  }
}
