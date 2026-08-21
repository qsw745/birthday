import BirthdayCore
import Foundation
import Observation

struct UITestBootstrap: Equatable, Sendable {
  let isEnabled: Bool
  let networkDisabled: Bool

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    isEnabled = arguments.contains("-ui-testing")
    networkDisabled = arguments.contains("-network-disabled")
  }
}

private actor ReminderRebuildCoordinator {
  private struct Request: Sendable {
    let records: [BirthdayRecord]
    let now: Date
    let timeZone: TimeZone
    let generation: UInt64
  }

  private let planner: ReminderPlanner
  private let scheduler: any NotificationScheduling
  private var pendingRequest: Request?
  private var runningTask: Task<Void, Never>?
  private var latestRequestedGeneration: UInt64 = 0
  private var latestHealth = NotificationHealth(
    state: .notRequested,
    scheduledCount: 0,
    coverageEnd: nil,
    errorCategory: nil
  )

  init(planner: ReminderPlanner, scheduler: any NotificationScheduling) {
    self.planner = planner
    self.scheduler = scheduler
  }

  func rebuild(
    records: [BirthdayRecord],
    now: Date,
    timeZone: TimeZone,
    generation: UInt64
  ) async
    -> NotificationHealth
  {
    guard generation >= latestRequestedGeneration else {
      if let runningTask {
        await runningTask.value
      }
      return latestHealth
    }

    latestRequestedGeneration = generation
    pendingRequest = Request(
      records: records,
      now: now,
      timeZone: timeZone,
      generation: generation
    )

    if runningTask == nil {
      runningTask = Task { await drainPendingRequests() }
    }

    guard let runningTask else { return latestHealth }
    await runningTask.value
    return latestHealth
  }

  private func drainPendingRequests() async {
    while let request = pendingRequest {
      pendingRequest = nil

      let plan: ReminderPlan
      do {
        plan = try planner.makePlan(
          records: request.records,
          now: request.now,
          timeZone: request.timeZone
        )
      } catch {
        if request.generation == latestRequestedGeneration {
          latestHealth = failedHealth(category: "plan_failed")
        }
        continue
      }

      let result: NotificationHealth
      do {
        result = try await scheduler.apply(plan)
      } catch {
        result = failedHealth(category: "schedule_failed")
      }

      if request.generation == latestRequestedGeneration {
        latestHealth = result
      }
    }

    runningTask = nil
  }

  private func failedHealth(category: String) -> NotificationHealth {
    NotificationHealth(
      state: .failed,
      scheduledCount: 0,
      coverageEnd: nil,
      errorCategory: category
    )
  }
}

@MainActor
@Observable
final class AppModel {
  enum Tab: Hashable {
    case calendar
    case birthdays
    case settings
  }

  enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(message: String)
  }

  enum UnlockState: Equatable {
    case idle
    case authenticating
    case failed(message: String)
  }

  private enum PreferenceKey {
    static let hasCompletedOnboarding = "top.qisw.birthday.hasCompletedOnboarding"
    static let lockEnabled = "top.qisw.birthday.lockEnabled"
  }

  var selectedTab: Tab = .calendar
  private(set) var records: [BirthdayRecord]
  var selectedMonth: Date
  var selectedDay: Int?
  var isPresentingEditor = false
  private(set) var loadState: LoadState
  private(set) var hasCompletedOnboarding: Bool
  private(set) var lockEnabled: Bool
  private(set) var lockCapability: AppLockCapability
  private(set) var unlockState: UnlockState = .idle
  private(set) var isCompletingOnboarding = false
  private(set) var onboardingErrorMessage: String?
  private(set) var isRequestingNotificationAuthorization = false
  private(set) var notificationHealth = NotificationHealth(
    state: .notRequested,
    scheduledCount: 0,
    coverageEnd: nil,
    errorCategory: nil
  )

  let store: BirthdayStore
  let oneShotNotificationScheduler: any OneShotNotificationScheduling

  private var appLockSession: AppLockSessionState
  private var reminderGeneration: UInt64 = 0
  private var reminderOperationsInFlight = 0
  private let preferences: UserDefaults
  private let authenticator: any AppLockAuthenticating
  private let requestNotificationAuthorization: @MainActor () async throws -> Bool
  private let now: @Sendable () -> Date
  private let timeZone: @Sendable () -> TimeZone
  private let reminderRebuildCoordinator: ReminderRebuildCoordinator

  var isLoading: Bool {
    loadState == .loading
  }

  var errorMessage: String? {
    guard case .failed(let message) = loadState else { return nil }
    return message
  }

  var isEmpty: Bool {
    loadState == .loaded && records.isEmpty
  }

  var isUnlocked: Bool {
    appLockSession.isUnlocked
  }

  var launchState: AppLaunchState {
    if !hasCompletedOnboarding {
      return .onboarding
    }
    return AppLaunchState.resolve(
      hasCompletedOnboarding: true,
      lockEnabled: lockEnabled && !isUnlocked
    )
  }

  var isUnlocking: Bool {
    unlockState == .authenticating
  }

  var isRebuildingReminders: Bool {
    reminderOperationsInFlight > 0
  }

  init(
    store: BirthdayStore,
    initialRecords: [BirthdayRecord] = [],
    selectedMonth: Date = Date(),
    initiallyLoaded: Bool = false,
    preferences: UserDefaults = .standard,
    authenticator: any AppLockAuthenticating = LocalAuthenticationService(),
    notificationScheduler: any NotificationScheduling = UserNotificationScheduler(
      center: SystemNotificationCenterClient()
    ),
    oneShotNotificationScheduler: any OneShotNotificationScheduling = OneShotNotificationScheduler(
      center: SystemNotificationCenterClient()
    ),
    reminderPlanner: ReminderPlanner = ReminderPlanner(),
    requestNotificationAuthorization: @escaping @MainActor () async throws -> Bool = { false },
    now: @escaping @Sendable () -> Date = Date.init,
    timeZone: @escaping @Sendable () -> TimeZone = { .current }
  ) {
    self.store = store
    records = initialRecords
    self.selectedMonth = selectedMonth
    loadState = initiallyLoaded ? .loaded : .idle
    self.preferences = preferences
    self.authenticator = authenticator
    self.oneShotNotificationScheduler = oneShotNotificationScheduler
    self.requestNotificationAuthorization = requestNotificationAuthorization
    self.now = now
    self.timeZone = timeZone
    reminderRebuildCoordinator = ReminderRebuildCoordinator(
      planner: reminderPlanner,
      scheduler: notificationScheduler
    )

    let capability = authenticator.capability()
    let storedPreference = preferences.object(forKey: PreferenceKey.lockEnabled) as? Bool
    let lockDecision = AppLockPreferenceDecision.resolve(
      storedPreference: storedPreference,
      capability: capability
    )
    preferences.set(lockDecision.preferenceToPersist, forKey: PreferenceKey.lockEnabled)
    hasCompletedOnboarding = preferences.bool(forKey: PreferenceKey.hasCompletedOnboarding)
    lockCapability = capability
    lockEnabled = lockDecision.isEnabled
    appLockSession = AppLockSessionState(lockEnabled: lockDecision.isEnabled)
  }

  func reload() async {
    let generation = nextReminderGeneration()
    beginReminderOperation()
    defer { endReminderOperation() }
    loadState = .loading

    do {
      _ = try await store.refreshNextSolarDates(now: now(), timeZone: timeZone())
      let snapshot = try await store.activeBirthdays()
      records = snapshot
      loadState = .loaded
      await rebuildReminderSnapshot(snapshot, generation: generation)
    } catch {
      loadState = .failed(
        message: "无法读取本地生日资料。请重试；若仍然失败，请重新打开应用。"
      )
      if generation == reminderGeneration {
        notificationHealth = failedNotificationHealth(category: "local_read_failed")
      }
    }
  }

  func completeOnboarding(requestNotifications: Bool) async {
    guard
      !hasCompletedOnboarding,
      !isCompletingOnboarding,
      !isRequestingNotificationAuthorization
    else { return }

    isCompletingOnboarding = true
    onboardingErrorMessage = nil

    if requestNotifications {
      isRequestingNotificationAuthorization = true
      let generation = nextReminderGeneration()

      let isAuthorized: Bool
      do {
        isAuthorized = try await requestNotificationAuthorization()
      } catch {
        if generation == reminderGeneration {
          notificationHealth = failedNotificationHealth(category: "authorization_request_failed")
        }
        onboardingErrorMessage = "通知权限请求未完成。请重试，或选择暂不开启。"
        isRequestingNotificationAuthorization = false
        isCompletingOnboarding = false
        return
      }

      completeOnboardingState()
      if isAuthorized {
        await rebuildKnownSnapshot(records, generation: generation)
      } else if generation == reminderGeneration {
        notificationHealth = permissionDeniedNotificationHealth()
      }
      isRequestingNotificationAuthorization = false
      isCompletingOnboarding = false
      return
    }

    completeOnboardingState()
    isCompletingOnboarding = false
  }

  func requestNotificationAuthorizationFromSettings() async {
    guard !isRequestingNotificationAuthorization else { return }
    isRequestingNotificationAuthorization = true
    let generation = nextReminderGeneration()
    defer { isRequestingNotificationAuthorization = false }

    do {
      if try await requestNotificationAuthorization() {
        await rebuildFreshSnapshot(generation: generation, reportReadFailure: true)
      } else if generation == reminderGeneration {
        notificationHealth = permissionDeniedNotificationHealth()
      }
    } catch {
      if generation == reminderGeneration {
        notificationHealth = failedNotificationHealth(category: "authorization_request_failed")
      }
    }
  }

  private func completeOnboardingState() {
    preferences.set(true, forKey: PreferenceKey.hasCompletedOnboarding)
    hasCompletedOnboarding = true
    onboardingErrorMessage = nil
  }

  func unlock() async {
    guard
      launchState == .locked,
      !isUnlocking,
      let attempt = appLockSession.beginAuthentication()
    else { return }

    unlockState = .authenticating

    do {
      let succeeded = try await authenticator.unlock(reason: "解锁生日资料")
      guard appLockSession.completeAuthentication(attempt, succeeded: succeeded) else { return }

      if succeeded {
        unlockState = .idle
      } else {
        unlockState = .failed(message: "身份验证未通过。请再次验证 Face ID 或设备密码。")
      }
    } catch AppLockError.cancelled {
      guard appLockSession.completeAuthentication(attempt, succeeded: false) else { return }
      unlockState = .failed(message: "已取消解锁。需要时可再次验证。")
    } catch AppLockError.unavailable {
      guard appLockSession.completeAuthentication(attempt, succeeded: false) else { return }
      unlockState = .failed(message: "此设备当前无法使用 Face ID 或设备密码，请检查系统设置后重试。")
    } catch AppLockError.evaluationFailed {
      guard appLockSession.completeAuthentication(attempt, succeeded: false) else { return }
      unlockState = .failed(message: "未能验证身份。请再次尝试 Face ID 或设备密码。")
    } catch {
      guard appLockSession.completeAuthentication(attempt, succeeded: false) else { return }
      unlockState = .failed(message: "解锁失败。请稍后重试。")
    }
  }

  func lockForBackground() {
    appLockSession.enterBackground(lockEnabled: lockEnabled)
    unlockState = .idle
  }

  func refreshAuthenticationCapability() {
    let capability = authenticator.capability()
    lockCapability = capability
    guard capability == .unavailable, lockEnabled else { return }
    lockEnabled = false
    preferences.set(false, forKey: PreferenceKey.lockEnabled)
    appLockSession.setLockEnabled(false)
    unlockState = .idle
  }

  func setLockEnabled(_ isEnabled: Bool) {
    guard !isEnabled || lockCapability != .unavailable else { return }
    guard lockEnabled != isEnabled else { return }
    lockEnabled = isEnabled
    preferences.set(isEnabled, forKey: PreferenceKey.lockEnabled)
    appLockSession.setLockEnabled(isEnabled)

    if !isEnabled {
      unlockState = .idle
    }
  }

  func rebuildReminders() async {
    let generation = nextReminderGeneration()
    await rebuildFreshSnapshot(generation: generation, reportReadFailure: true)
  }

  private func rebuildFreshSnapshot(generation: UInt64, reportReadFailure: Bool) async {
    beginReminderOperation()
    defer { endReminderOperation() }

    do {
      _ = try await store.refreshNextSolarDates(now: now(), timeZone: timeZone())
      let snapshot = try await store.activeBirthdays()
      await rebuildReminderSnapshot(snapshot, generation: generation)
    } catch {
      if reportReadFailure, generation == reminderGeneration {
        notificationHealth = failedNotificationHealth(category: "local_read_failed")
      }
    }
  }

  private func rebuildKnownSnapshot(_ snapshot: [BirthdayRecord], generation: UInt64) async {
    beginReminderOperation()
    defer { endReminderOperation() }
    await rebuildReminderSnapshot(snapshot, generation: generation)
  }

  private func rebuildReminderSnapshot(_ snapshot: [BirthdayRecord], generation: UInt64) async {
    let health = await reminderRebuildCoordinator.rebuild(
      records: snapshot,
      now: now(),
      timeZone: timeZone(),
      generation: generation
    )
    if generation == reminderGeneration {
      notificationHealth = health
    }
  }

  private func nextReminderGeneration() -> UInt64 {
    reminderGeneration &+= 1
    return reminderGeneration
  }

  private func beginReminderOperation() {
    reminderOperationsInFlight += 1
  }

  private func endReminderOperation() {
    reminderOperationsInFlight = max(0, reminderOperationsInFlight - 1)
  }

  private func failedNotificationHealth(category: String) -> NotificationHealth {
    NotificationHealth(
      state: .failed,
      scheduledCount: 0,
      coverageEnd: nil,
      errorCategory: category
    )
  }

  private func permissionDeniedNotificationHealth() -> NotificationHealth {
    NotificationHealth(
      state: .permissionDenied,
      scheduledCount: 0,
      coverageEnd: nil,
      errorCategory: nil
    )
  }
}
