@preconcurrency import BackgroundTasks
import BirthdayCore
import Foundation
@preconcurrency import Network

@MainActor
final class SyncCoordinator {
  private let coordinator: SyncRequestCoordinator

  init(
    syncEngine: SyncEngine,
    store: BirthdayStore,
    credentials: DeviceCredentialStore,
    notificationScheduler: any NotificationScheduling,
    reminderPlanner: ReminderPlanner,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZone: @escaping @Sendable () -> TimeZone = { .current }
  ) {
    coordinator = SyncRequestCoordinator(
      isBound: {
        guard let saved = try credentials.load() else { return false }
        return saved.refreshExpiresAt > now()
      },
      synchronize: { try await syncEngine.syncNow() },
      loadActiveBirthdays: { try await store.activeBirthdays() },
      planner: reminderPlanner,
      notificationScheduler: notificationScheduler,
      now: now,
      timeZone: timeZone
    )
  }

  func request(_ trigger: SyncTrigger) async throws -> SyncRequestOutcome {
    try await coordinator.request(trigger)
  }
}

@MainActor
final class NetworkRestorationMonitor {
  private let monitor: NWPathMonitor
  private let queue: DispatchQueue
  private let onRestored: @MainActor @Sendable () -> Void
  private var transition = NetworkRestorationTransition()
  private var hasStarted = false

  init(onRestored: @escaping @MainActor @Sendable () -> Void) {
    monitor = NWPathMonitor()
    queue = DispatchQueue(label: "top.qisw.birthday.network-restoration")
    self.onRestored = onRestored
    monitor.pathUpdateHandler = { [weak self] path in
      let isSatisfied = path.status == .satisfied
      Task { @MainActor [weak self] in
        self?.receive(isSatisfied: isSatisfied)
      }
    }
  }

  func start() {
    guard !hasStarted else { return }
    hasStarted = true
    monitor.start(queue: queue)
  }

  func stop() {
    guard hasStarted else { return }
    monitor.cancel()
    hasStarted = false
  }

  private func receive(isSatisfied: Bool) {
    guard transition.receive(isSatisfied: isSatisfied) else { return }
    onRestored()
  }
}

/// Registers a best-effort refresh opportunity. iOS decides when, or whether, it runs.
@MainActor
final class BackgroundRefreshCoordinator {
  static let identifier = "top.qisw.birthday.refresh"

  private let policy: BackgroundRefreshPolicy
  private let runner: BackgroundRefreshRunner
  private let runSync: @MainActor @Sendable () async throws -> SyncRequestOutcome
  private var isRegistered = false

  init(
    policy: BackgroundRefreshPolicy = BackgroundRefreshPolicy(),
    runner: BackgroundRefreshRunner = BackgroundRefreshRunner(),
    runSync: @escaping @MainActor @Sendable () async throws -> SyncRequestOutcome
  ) {
    self.policy = policy
    self.runner = runner
    self.runSync = runSync
  }

  func registerAndSchedule() {
    if !isRegistered {
      isRegistered = BGTaskScheduler.shared.register(
        forTaskWithIdentifier: Self.identifier,
        using: nil
      ) { [weak self] task in
        guard let refreshTask = task as? BGAppRefreshTask else {
          task.setTaskCompleted(success: false)
          return
        }
        Task { @MainActor [weak self] in
          await self?.handle(refreshTask)
        }
      }
    }
    guard isRegistered else { return }
    scheduleNext()
  }

  func scheduleNext() {
    let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
    request.earliestBeginDate = policy.nextEarliestBeginDate(after: Date())
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Background refresh is opportunistic. Foreground and local reminders remain independent.
    }
  }

  func cancelPending() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
  }

  private func handle(_ task: BGAppRefreshTask) async {
    scheduleNext()
    let work = Task { [runner, runSync] in
      await runner.run { try await runSync() }
    }
    task.expirationHandler = { work.cancel() }
    task.setTaskCompleted(success: await work.value)
  }
}

/// Keeps the app-launch BGTask registration independent from delayed SwiftUI view setup.
@MainActor
final class AppSyncRuntime {
  static let shared = AppSyncRuntime()

  private weak var model: AppModel?
  private lazy var backgroundRefreshCoordinator = BackgroundRefreshCoordinator { [weak self] in
    guard let model = self?.model else { return .unbound }
    return try await model.performSync(.backgroundRefresh)
  }

  private init() {}

  func registerBackgroundRefresh() {
    backgroundRefreshCoordinator.registerAndSchedule()
  }

  func install(model: AppModel) {
    self.model = model
  }
}
