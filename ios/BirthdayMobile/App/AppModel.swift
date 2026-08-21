import BirthdayCore
import Foundation
import Observation

private actor ReminderRebuildCoordinator {
  private struct Request: Sendable {
    let records: [BirthdayRecord]
    let now: Date
    let timeZone: TimeZone
  }

  private let planner: ReminderPlanner
  private let scheduler: any NotificationScheduling
  private var pendingRequest: Request?
  private var runningTask: Task<Void, Never>?
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

  func rebuild(records: [BirthdayRecord], now: Date, timeZone: TimeZone) async
    -> NotificationHealth
  {
    pendingRequest = Request(records: records, now: now, timeZone: timeZone)

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
        latestHealth = failedHealth(category: "plan_failed")
        continue
      }

      do {
        latestHealth = try await scheduler.apply(plan)
      } catch {
        latestHealth = failedHealth(category: "schedule_failed")
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
  private(set) var isUnlocked: Bool
  private(set) var unlockState: UnlockState = .idle
  private(set) var isCompletingOnboarding = false
  private(set) var notificationHealth = NotificationHealth(
    state: .notRequested,
    scheduledCount: 0,
    coverageEnd: nil,
    errorCategory: nil
  )
  private(set) var isRebuildingReminders = false

  let store: BirthdayStore

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
    reminderPlanner: ReminderPlanner = ReminderPlanner(),
    requestNotificationAuthorization: @escaping @MainActor () async throws -> Bool = { false },
    now: @escaping @Sendable () -> Date = Date.init,
    timeZone: @escaping @Sendable () -> TimeZone = { .current }
  ) {
    preferences.register(defaults: [PreferenceKey.lockEnabled: true])

    self.store = store
    records = initialRecords
    self.selectedMonth = selectedMonth
    loadState = initiallyLoaded ? .loaded : .idle
    self.preferences = preferences
    self.authenticator = authenticator
    self.requestNotificationAuthorization = requestNotificationAuthorization
    self.now = now
    self.timeZone = timeZone
    reminderRebuildCoordinator = ReminderRebuildCoordinator(
      planner: reminderPlanner,
      scheduler: notificationScheduler
    )

    let storedLockEnabled = preferences.bool(forKey: PreferenceKey.lockEnabled)
    hasCompletedOnboarding = preferences.bool(forKey: PreferenceKey.hasCompletedOnboarding)
    lockEnabled = storedLockEnabled
    isUnlocked = !storedLockEnabled
  }

  func reload() async {
    loadState = .loading

    do {
      records = try await store.activeBirthdays()
      loadState = .loaded
      await rebuildReminders()
    } catch {
      loadState = .failed(
        message: "无法读取本地生日资料。请重试；若仍然失败，请重新打开应用。"
      )
    }
  }

  func completeOnboarding(requestNotifications: Bool) async {
    guard !hasCompletedOnboarding, !isCompletingOnboarding else { return }
    isCompletingOnboarding = true

    var shouldRebuildAfterAuthorization = requestNotifications
    if requestNotifications {
      do {
        _ = try await requestNotificationAuthorization()
      } catch {
        shouldRebuildAfterAuthorization = false
        notificationHealth = NotificationHealth(
          state: .failed,
          scheduledCount: 0,
          coverageEnd: nil,
          errorCategory: "authorization_request_failed"
        )
      }
    }

    preferences.set(true, forKey: PreferenceKey.hasCompletedOnboarding)
    hasCompletedOnboarding = true
    isUnlocked = !lockEnabled
    isCompletingOnboarding = false

    if shouldRebuildAfterAuthorization {
      await rebuildReminders()
    }
  }

  func unlock() async {
    guard launchState == .locked, !isUnlocking else { return }
    unlockState = .authenticating

    do {
      if try await authenticator.unlock(reason: "解锁生日资料") {
        isUnlocked = true
        unlockState = .idle
      } else {
        unlockState = .failed(message: "身份验证未通过。请再次验证 Face ID 或设备密码。")
      }
    } catch AppLockError.cancelled {
      unlockState = .failed(message: "已取消解锁。需要时可再次验证。")
    } catch AppLockError.unavailable {
      unlockState = .failed(message: "此设备当前无法使用 Face ID 或设备密码，请检查系统设置后重试。")
    } catch AppLockError.evaluationFailed {
      unlockState = .failed(message: "未能验证身份。请再次尝试 Face ID 或设备密码。")
    } catch {
      unlockState = .failed(message: "解锁失败。请稍后重试。")
    }
  }

  func lockForBackground() {
    isUnlocked = false
    unlockState = .idle
  }

  func setLockEnabled(_ isEnabled: Bool) {
    guard lockEnabled != isEnabled else { return }
    lockEnabled = isEnabled
    preferences.set(isEnabled, forKey: PreferenceKey.lockEnabled)

    if !isEnabled {
      isUnlocked = true
      unlockState = .idle
    }
  }

  func rebuildReminders() async {
    isRebuildingReminders = true
    notificationHealth = await reminderRebuildCoordinator.rebuild(
      records: records,
      now: now(),
      timeZone: timeZone()
    )
    isRebuildingReminders = false
  }
}
