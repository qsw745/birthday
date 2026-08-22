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
    timeZone: @escaping @Sendable () -> TimeZone = { .current },
    publish: @escaping @MainActor @Sendable (SyncRequestOutcome) async -> Void
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
      timeZone: timeZone,
      publish: { outcome in await publish(outcome) }
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
  private enum State {
    case new
    case started
    case cancelled
  }

  private var state: State = .new

  init(onRestored: @escaping @MainActor @Sendable () -> Void) {
    monitor = NWPathMonitor()
    queue = DispatchQueue(label: "top.qisw.birthday.network-restoration")
    self.onRestored = onRestored
    monitor.pathUpdateHandler = { [weak self] path in
      let state: NetworkPathState
      switch path.status {
      case .unsatisfied:
        state = .unsatisfied
      case .requiresConnection:
        state = .requiresConnection
      case .satisfied:
        state = .satisfied
      @unknown default:
        state = .requiresConnection
      }
      Task { @MainActor [weak self] in
        self?.receive(state)
      }
    }
  }

  func start() {
    guard state == .new else { return }
    state = .started
    monitor.start(queue: queue)
  }

  func stop() {
    guard state == .started else { return }
    monitor.cancel()
    state = .cancelled
  }

  private func receive(_ state: NetworkPathState) {
    guard transition.receive(state) else { return }
    onRestored()
  }
}

/// Registers a best-effort refresh opportunity. iOS decides when, or whether, it runs.
@MainActor
final class BackgroundRefreshCoordinator {
  static let identifier = "top.qisw.birthday.refresh"

  private let policy: BackgroundRefreshPolicy
  private let runner: BackgroundRefreshRunner
  private let readiness: BackgroundRefreshReadiness
  private let runSync: @MainActor @Sendable () async throws -> BackgroundRefreshWorkResult
  private var isRegistered = false

  init(
    policy: BackgroundRefreshPolicy = BackgroundRefreshPolicy(),
    runner: BackgroundRefreshRunner = BackgroundRefreshRunner(),
    readiness: BackgroundRefreshReadiness,
    runSync: @escaping @MainActor @Sendable () async throws -> BackgroundRefreshWorkResult
  ) {
    self.policy = policy
    self.runner = runner
    self.readiness = readiness
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
    let work = Task { [readiness, runner, runSync] in
      await runner.run(readiness: readiness) { try await runSync() }
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
  private let readiness = BackgroundRefreshReadiness()
  private lazy var backgroundRefreshCoordinator = BackgroundRefreshCoordinator(
    readiness: readiness
  ) { [weak self] in
    guard let model = self?.model else { return .notReady }
    return .outcome(try await model.performSync(.backgroundRefresh))
  }

  private init() {}

  func registerBackgroundRefresh() {
    backgroundRefreshCoordinator.registerAndSchedule()
  }

  func install(model: AppModel) async {
    self.model = model
    await readiness.markReady()
    backgroundRefreshCoordinator.scheduleNext()
  }

  func uninstall(model: AppModel) {
    guard self.model === model else { return }
    self.model = nil
    backgroundRefreshCoordinator.cancelPending()
  }
}
