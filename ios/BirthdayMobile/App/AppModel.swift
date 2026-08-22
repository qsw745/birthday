import BirthdayCore
import Foundation
import Observation

struct UITestBootstrap: Equatable, Sendable {
  let isEnabled: Bool
  let networkDisabled: Bool
  let snapshotImportPreviewEnabled: Bool
  let snapshotFirstLoadFails: Bool
  let snapshotFirstRefreshFails: Bool

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    isEnabled = arguments.contains("-ui-testing")
    networkDisabled = arguments.contains("-network-disabled")
    snapshotImportPreviewEnabled = arguments.contains("-snapshot-import-preview")
    snapshotFirstLoadFails = arguments.contains("-snapshot-first-load-fails")
    snapshotFirstRefreshFails = arguments.contains("-snapshot-first-refresh-fails")
  }

  var isSnapshotImportFixtureEnabled: Bool {
    isEnabled && networkDisabled && snapshotImportPreviewEnabled
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
    case conflicts
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

  enum ServerBindingState: Equatable {
    case idle
    case binding
    case failed(message: String)
    case credentialsSavedAwaitingSnapshotPreview
  }

  enum SnapshotImportState: Equatable {
    case idle
    case loading
    case ready
    case importing
    case failed
    case refreshFailed
    case completed
  }

  enum SyncStatus: Equatable {
    case idle
    case syncing
    case synchronized(SyncSummary)
    case unbound
    case failed
  }

  typealias SyncPresentation = SyncPresentationState

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
  private(set) var serverBindingState: ServerBindingState = .idle
  private(set) var snapshotImportState: SnapshotImportState = .idle
  private(set) var snapshotImportPreview: SnapshotImportPreview?
  private(set) var snapshotImportErrorMessage: String?
  private(set) var snapshotDuplicateDecisions: [DuplicateCandidate.ID: DuplicateDecision] = [:]
  private(set) var conflicts: [ResolvableSyncConflict] = []
  private(set) var conflictErrorMessage: String?
  private(set) var resolvingConflictID: UUID?
  private(set) var isRequestingNotificationAuthorization = false
  private(set) var notificationHealth = NotificationHealth(
    state: .notRequested,
    scheduledCount: 0,
    coverageEnd: nil,
    errorCategory: nil
  )
  private(set) var syncStatus: SyncStatus = .idle
  private(set) var isManualSyncing = false
  var syncPresentation: SyncPresentation { syncPresentationReducer.presentation }
  private(set) var syncPendingCount = 0
  private(set) var managedDevices: [ManagedDevice] = []
  private(set) var isLoadingManagedDevices = false
  private(set) var isManagingDevice = false
  private(set) var deviceManagementMessage: String?
  private(set) var isSyncRuntimeEnabled = false
  private(set) var needsRevokedCredentialCleanup = false

  let store: BirthdayStore
  let oneShotNotificationScheduler: any OneShotNotificationScheduling

  private var appLockSession: AppLockSessionState
  private var reminderGeneration: UInt64 = 0
  private var reminderOperationsInFlight = 0
  private var pendingInitialSnapshot: SnapshotResponse?
  private let preferences: UserDefaults
  private let authenticator: any AppLockAuthenticating
  private let serverDeviceBinder: any ServerDeviceBinding
  private let requestNotificationAuthorization: @MainActor () async throws -> Bool
  private let snapshotRecordLoader: @Sendable (BirthdayStore) async throws -> [BirthdayRecord]
  private let now: @Sendable () -> Date
  private let timeZone: @Sendable () -> TimeZone
  private let conflictResolver: ConflictResolver
  private let reminderRebuildCoordinator: ReminderRebuildCoordinator
  private var syncCoordinator: SyncCoordinator?
  private var deviceManagementService: DeviceManagementService?
  private var syncPresentationReducer = SyncPresentationReducer()
  private var activeSyncPresentationRequest: SyncPresentationRequest?

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
    serverDeviceBinder: any ServerDeviceBinding,
    notificationScheduler: any NotificationScheduling = UserNotificationScheduler(
      center: SystemNotificationCenterClient()
    ),
    oneShotNotificationScheduler: any OneShotNotificationScheduling = OneShotNotificationScheduler(
      center: SystemNotificationCenterClient()
    ),
    reminderPlanner: ReminderPlanner = ReminderPlanner(),
    requestNotificationAuthorization: @escaping @MainActor () async throws -> Bool = { false },
    snapshotRecordLoader: @escaping @Sendable (BirthdayStore) async throws -> [BirthdayRecord] = {
      try $0.activeBirthdays()
    },
    now: @escaping @Sendable () -> Date = Date.init,
    timeZone: @escaping @Sendable () -> TimeZone = { .current }
  ) {
    self.store = store
    records = initialRecords
    self.selectedMonth = selectedMonth
    loadState = initiallyLoaded ? .loaded : .idle
    self.preferences = preferences
    self.authenticator = authenticator
    self.serverDeviceBinder = serverDeviceBinder
    self.oneShotNotificationScheduler = oneShotNotificationScheduler
    self.requestNotificationAuthorization = requestNotificationAuthorization
    self.snapshotRecordLoader = snapshotRecordLoader
    self.now = now
    self.timeZone = timeZone
    conflictResolver = ConflictResolver(store: store, now: now, timeZone: timeZone)
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
      await reloadConflicts()
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

  func isResolvingConflict(_ id: UUID) -> Bool {
    resolvingConflictID == id
  }

  func resolveConflictKeepingLocal(id: UUID) async {
    await resolveConflict(id: id) {
      try await self.conflictResolver.keepLocal(id: id)
    }
  }

  func resolveConflictUsingRemote(id: UUID) async {
    await resolveConflict(id: id) {
      try await self.conflictResolver.useRemote(id: id)
    }
  }

  private func resolveConflict(
    id: UUID,
    action: () async throws -> Void
  ) async {
    guard resolvingConflictID == nil else { return }
    resolvingConflictID = id
    conflictErrorMessage = nil
    defer { resolvingConflictID = nil }

    do {
      try await action()
      await reload()
    } catch {
      conflictErrorMessage = "未能解决同步冲突，本机资料未改变。请重新载入后再试。"
    }
  }

  private func reloadConflicts() async {
    do {
      conflicts = try await conflictResolver.conflicts()
      conflictErrorMessage = nil
    } catch {
      conflicts = []
      conflictErrorMessage = "同步冲突资料无法安全读取，未执行任何更改。请重新载入后再试。"
    }
    updateSyncPresentationLocalFacts()
  }

  func completeOnboarding(requestNotifications: Bool) async {
    guard await prepareOnboardingNotifications(requestNotifications: requestNotifications) else {
      return
    }
    finishOnboarding()
  }

  func prepareOnboardingNotifications(requestNotifications: Bool) async -> Bool {
    guard
      !hasCompletedOnboarding,
      !isCompletingOnboarding,
      !isRequestingNotificationAuthorization
    else { return false }

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
        return false
      }

      if isAuthorized {
        await rebuildKnownSnapshot(records, generation: generation)
      } else if generation == reminderGeneration {
        notificationHealth = permissionDeniedNotificationHealth()
      }
      isRequestingNotificationAuthorization = false
      isCompletingOnboarding = false
      return true
    }

    isCompletingOnboarding = false
    return true
  }

  func finishOnboarding() {
    guard !hasCompletedOnboarding, !isCompletingOnboarding else { return }
    completeOnboardingState()
  }

  @discardableResult
  func bindServer(username: String, password: String, deviceName: String) async -> Bool {
    guard serverBindingState != .binding else { return false }

    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedUsername.isEmpty else {
      serverBindingState = .failed(message: "请输入管理员用户名。")
      return false
    }
    guard !password.isEmpty else {
      serverBindingState = .failed(message: "请输入管理员密码。")
      return false
    }
    guard !normalizedDeviceName.isEmpty, normalizedDeviceName.utf16.count <= 100 else {
      serverBindingState = .failed(message: "设备名称需为 1 到 100 个字符。")
      return false
    }

    serverBindingState = .binding
    do {
      try await serverDeviceBinder.bind(
        username: normalizedUsername,
        password: password,
        deviceName: normalizedDeviceName
      )
      if syncCoordinator != nil {
        await deviceManagementService?.resumeAfterBinding()
        syncPresentationReducer.bind()
        isSyncRuntimeEnabled = true
      }
      serverBindingState = .credentialsSavedAwaitingSnapshotPreview
      return true
    } catch {
      serverBindingState = .failed(message: serverBindingMessage(for: error))
      return false
    }
  }

  func loadInitialSnapshotPreview() async {
    guard
      serverBindingState == .credentialsSavedAwaitingSnapshotPreview,
      snapshotImportState != .loading,
      snapshotImportState != .importing,
      snapshotImportState != .refreshFailed,
      snapshotImportState != .completed
    else { return }

    snapshotImportState = .loading
    snapshotImportErrorMessage = nil

    do {
      let snapshot = try await serverDeviceBinder.loadSnapshot()
      let localRecords = try await store.activeBirthdays()
      pendingInitialSnapshot = snapshot
      snapshotImportPreview = SnapshotImporter.preview(
        local: localRecords,
        remote: snapshot.birthdays
      )
      snapshotDuplicateDecisions = [:]
      snapshotImportState = .ready
    } catch {
      pendingInitialSnapshot = nil
      snapshotImportPreview = nil
      snapshotDuplicateDecisions = [:]
      snapshotImportErrorMessage = snapshotImportMessage(for: error)
      snapshotImportState = .failed
    }
  }

  func chooseSnapshotDuplicate(
    _ decision: DuplicateDecision,
    candidateID: DuplicateCandidate.ID
  ) {
    guard
      snapshotImportState == .ready,
      let preview = snapshotImportPreview,
      let selectedCandidate = preview.duplicates.first(where: { $0.id == candidateID })
    else { return }
    for candidate in preview.duplicates where candidate.local.id == selectedCandidate.local.id {
      snapshotDuplicateDecisions[candidate.id] = decision
    }
    snapshotImportErrorMessage = nil
  }

  func snapshotDecision(for candidateID: DuplicateCandidate.ID) -> DuplicateDecision? {
    snapshotDuplicateDecisions[candidateID]
  }

  var canImportInitialSnapshot: Bool {
    guard snapshotImportState == .ready, let preview = snapshotImportPreview else { return false }
    return preview.duplicates.allSatisfy { snapshotDuplicateDecisions[$0.id] != nil }
  }

  @discardableResult
  func importInitialSnapshot() async -> Bool {
    guard
      canImportInitialSnapshot,
      let snapshot = pendingInitialSnapshot,
      let preview = snapshotImportPreview,
      preview.duplicates.allSatisfy({ snapshotDuplicateDecisions[$0.id] != nil })
    else { return false }

    snapshotImportState = .importing
    snapshotImportErrorMessage = nil
    do {
      try await store.applySnapshot(
        snapshot,
        decisions: snapshotDuplicateDecisions,
        now: now(),
        timeZone: timeZone()
      )
    } catch {
      snapshotImportState = .ready
      snapshotImportErrorMessage = "未能导入服务器快照，本机资料未改变，请重试。"
      return false
    }

    pendingInitialSnapshot = nil
    return await reloadImportedSnapshot()
  }

  @discardableResult
  func reloadImportedSnapshot() async -> Bool {
    guard snapshotImportState == .importing || snapshotImportState == .refreshFailed else {
      return false
    }

    snapshotImportState = .importing
    snapshotImportErrorMessage = nil
    let importedRecords: [BirthdayRecord]
    do {
      importedRecords = try await snapshotRecordLoader(store)
    } catch {
      snapshotImportState = .refreshFailed
      snapshotImportErrorMessage = "导入已完成，但界面刷新失败。请重新载入已导入资料。"
      return false
    }

    records = importedRecords
    loadState = .loaded
    selectedTab = .calendar
    if let nearestOccurrence = importedRecords.compactMap(\.nextSolarDate).min() {
      selectedMonth = nearestOccurrence
      selectedDay = nil
    }
    snapshotImportState = .completed
    completeOnboardingState()

    let generation = nextReminderGeneration()
    await rebuildKnownSnapshot(importedRecords, generation: generation)
    return true
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

  private func serverBindingMessage(for error: any Error) -> String {
    if let mobileError = error as? MobileAPIError {
      switch mobileError {
      case .server(code: "mobile_login_invalid", status: 401):
        return "用户名或密码错误。"
      case .server(code: "mobile_device_ownership_conflict", status: 409):
        return "此设备标识已绑定到其他账号，请联系管理员处理；本地功能仍可使用。"
      case .server(code: "api_rate_limited", status: 429),
        .server(code: "mobile_login_rate_limited", status: 429):
        return "尝试次数较多，请稍后再试；本地功能仍可使用。"
      case .server(code: "mobile_auth_unconfigured", status: 503):
        return "服务器暂未配置手机绑定，请稍后再试；本地功能仍可使用。"
      case .transport:
        return "暂时无法连接服务器，本地功能仍可使用。"
      case .invalidResponse:
        return "服务器返回的数据无法验证，本地功能仍可使用。"
      default:
        return "服务器暂时无法完成绑定，本地功能仍可使用。"
      }
    }
    if error is ServerDeviceBindingError {
      return "服务器返回的数据无法验证，本地功能仍可使用。"
    }
    if error is DeviceCredentialStoreError || error is KeychainError {
      return "无法安全读取或保存同步凭据，本地功能仍可使用。"
    }
    return "服务器暂时无法完成绑定，本地功能仍可使用。"
  }

  private func snapshotImportMessage(for error: any Error) -> String {
    if let mobileError = error as? MobileAPIError {
      switch mobileError {
      case .transport:
        return "暂时无法读取服务器快照，本机资料未改变。"
      case .accessExpired, .refreshInvalid:
        return "同步凭据已失效，本机资料未改变。请返回后重新绑定。"
      case .invalidResponse:
        return "服务器快照无法验证，本机资料未改变。"
      default:
        return "服务器暂时无法提供快照，本机资料未改变。"
      }
    }
    if error is DeviceCredentialStoreError || error is KeychainError
      || error is ServerDeviceBindingError
    {
      return "无法安全读取已保存的同步凭据，本机资料未改变。"
    }
    return "暂时无法准备导入预览，本机资料未改变。"
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

  func configureSyncCoordinator(_ coordinator: SyncCoordinator, initiallyBound: Bool) {
    syncCoordinator = coordinator
    isSyncRuntimeEnabled = true
    if initiallyBound { syncPresentationReducer.bind() }
  }

  func configureDeviceManagement(_ service: DeviceManagementService) {
    deviceManagementService = service
  }

  func refreshSyncSettings() async {
    await refreshSyncCounts()
    guard let deviceManagementService else {
      managedDevices = []
      return
    }

    isLoadingManagedDevices = true
    defer { isLoadingManagedDevices = false }
    do {
      managedDevices = try await deviceManagementService.listDevices()
      deviceManagementMessage = nil
    } catch DeviceManagementError.credentialsUnavailable {
      managedDevices = []
      deviceManagementMessage = nil
    } catch DeviceManagementError.rebindRequired {
      managedDevices = []
      deviceManagementMessage = "设备列表认证已失效；同步状态将在下次请求时要求重新绑定。"
    } catch MobileAPIError.transport {
      managedDevices = []
      deviceManagementMessage = "暂时无法读取设备列表；同步状态未改变。"
    } catch {
      managedDevices = []
      deviceManagementMessage = "无法读取设备列表，请稍后重试；同步状态未改变。"
    }
  }

  @discardableResult
  func revokeManagedDevice(_ device: MobileDevice, typedUsername: String) async -> Bool {
    guard !isManagingDevice, let deviceManagementService else { return false }
    isManagingDevice = true
    deviceManagementMessage = nil
    defer { isManagingDevice = false }

    do {
      try await deviceManagementService.revokeOther(device, typedUsername: typedUsername)
      await refreshSyncSettings()
      return true
    } catch {
      await applyDeviceManagementError(error)
      return false
    }
  }

  func beginStopSync() async -> UnlinkOutcome? {
    guard !isManagingDevice, let deviceManagementService else { return nil }
    isManagingDevice = true
    deviceManagementMessage = nil
    defer { isManagingDevice = false }
    isSyncRuntimeEnabled = false
    syncPresentationReducer.pauseOffline()

    do {
      let outcome = try await deviceManagementService.beginUnlinkCurrent()
      if outcome == .unlinked {
        disableSyncRuntimeAfterUnlink()
      }
      return outcome
    } catch DeviceManagementError.credentialClearFailedAfterServerRevoke {
      failCloseRevokedRuntime(
        message: "服务器已撤销此设备，但本机同步凭据清除失败。请再次清理本机凭据；期间同步保持停用。"
      )
      return nil
    } catch {
      await applyDeviceManagementError(error)
      return nil
    }
  }

  @discardableResult
  func confirmLocalStopSync() async -> Bool {
    guard !isManagingDevice, let deviceManagementService else { return false }
    isManagingDevice = true
    deviceManagementMessage = nil
    defer { isManagingDevice = false }

    do {
      try await deviceManagementService.confirmLocalUnlink()
      disableSyncRuntimeAfterUnlink()
      return true
    } catch {
      deviceManagementMessage =
        needsRevokedCredentialCleanup
        ? "服务器已撤销此设备，但本机同步凭据仍未能清除；同步继续保持停用。"
        : "无法清除本机同步凭据；本地生日资料未改变。"
      return false
    }
  }

  @discardableResult
  func performSync(_ trigger: SyncTrigger) async throws -> SyncRequestOutcome {
    guard isSyncRuntimeEnabled, let syncCoordinator else {
      syncStatus = .unbound
      return .unbound
    }

    let request = syncPresentationReducer.beginSync()
    if let request { activeSyncPresentationRequest = request }
    syncStatus = .syncing
    do {
      let outcome = try await syncCoordinator.request(trigger)
      switch outcome {
      case .completed:
        // Publication completes this generation while both sync gates remain leased.
        break
      case .unbound:
        syncStatus = .unbound
        if let request { finishSyncPresentation(request, result: .coalesced) }
      case .coalesced:
        if let request { finishSyncPresentation(request, result: .coalesced) }
      }
      return outcome
    } catch is CancellationError {
      syncStatus = .idle
      if let request { finishSyncPresentation(request, result: .cancelled) }
      throw CancellationError()
    } catch SyncError.rebindRequired {
      syncStatus = .failed
      await enterRebindRequired()
      throw SyncError.rebindRequired
    } catch let error as MobileAPIError {
      switch error {
      case .transport:
        syncStatus = .failed
        await refreshSyncCounts()
        if let request { finishSyncPresentation(request, result: .offline) }
      default:
        syncStatus = .failed
        await refreshSyncCounts()
        if let request {
          finishSyncPresentation(
            request,
            result: .failed(message: "服务器同步未完成；本地资料未回退。")
          )
        }
      }
      throw error
    } catch SyncError.retryPersistenceFailed(let category) where category == .transport {
      syncStatus = .failed
      await refreshSyncCounts()
      if let request { finishSyncPresentation(request, result: .offline) }
      throw SyncError.retryPersistenceFailed(originalCategory: category)
    } catch {
      syncStatus = .failed
      await refreshSyncCounts()
      if let request {
        finishSyncPresentation(
          request,
          result: .failed(message: "服务器同步未完成；本地资料未回退。")
        )
      }
      throw error
    }
  }

  func publishCompletedSync(_ outcome: SyncRequestOutcome) async {
    guard case .completed(let summary, let activeBirthdays, let health) = outcome else { return }
    records = activeBirthdays
    notificationHealth = health
    syncStatus = .synchronized(summary)
    await reloadConflicts()
    await refreshSyncCounts()
    if let request = activeSyncPresentationRequest {
      finishSyncPresentation(request, result: .completed(at: now()))
    }
  }

  func requestSync(_ trigger: SyncTrigger) async {
    guard trigger != .manual || !isManualSyncing else { return }
    if trigger == .manual {
      isManualSyncing = true
    }
    defer {
      if trigger == .manual {
        isManualSyncing = false
      }
    }

    do {
      _ = try await performSync(trigger)
    } catch {}
  }

  private func refreshSyncCounts() async {
    do {
      syncPendingCount = try await store.pendingOperations().count
    } catch {
      syncPendingCount = 0
    }
    updateSyncPresentationLocalFacts()
  }

  private func applyDeviceManagementError(_ error: any Error) async {
    switch error {
    case DeviceManagementError.confirmationMismatch:
      deviceManagementMessage = "管理员用户名不匹配，未发送撤销请求。"
    case DeviceManagementError.rebindRequired,
      DeviceManagementError.credentialsUnavailable:
      await enterRebindRequired()
      deviceManagementMessage = "需要重新绑定后才能管理设备。"
    case DeviceManagementError.operationInProgress:
      deviceManagementMessage = "另一项设备操作正在进行，请稍候。"
    case MobileAPIError.transport:
      if !isSyncRuntimeEnabled { syncPresentationReducer.pauseOffline() }
      deviceManagementMessage = "暂时无法连接服务器，本机资料未改变。"
    case MobileAPIError.server:
      if !isSyncRuntimeEnabled {
        syncPresentationReducer.bind()
        isSyncRuntimeEnabled = true
      }
      deviceManagementMessage = "服务器未能完成设备操作，本机资料未改变。"
    default:
      if !isSyncRuntimeEnabled {
        syncPresentationReducer.bind()
        isSyncRuntimeEnabled = true
      }
      deviceManagementMessage = "设备操作未完成，本机资料未改变。"
    }
  }

  private func disableSyncRuntimeAfterUnlink() {
    isSyncRuntimeEnabled = false
    syncPresentationReducer.useLocalOnly()
    syncStatus = .unbound
    managedDevices = []
    needsRevokedCredentialCleanup = false
    deviceManagementMessage = nil
  }

  private func failCloseRevokedRuntime(message: String) {
    isSyncRuntimeEnabled = false
    syncStatus = .failed
    managedDevices = []
    needsRevokedCredentialCleanup = true
    syncPresentationReducer.failClosed(message: message)
    deviceManagementMessage = message
  }

  func cancelPendingLocalStopSync() async {
    await deviceManagementService?.cancelPendingLocalUnlink()
    syncPresentationReducer.bind()
    isSyncRuntimeEnabled = true
    deviceManagementMessage = nil
  }

  private func enterRebindRequired() async {
    isSyncRuntimeEnabled = false
    syncPresentationReducer.requireRebind()
    activeSyncPresentationRequest = nil
    await deviceManagementService?.pauseForRebind()
  }

  private func finishSyncPresentation(
    _ request: SyncPresentationRequest,
    result: SyncPresentationCompletion
  ) {
    syncPresentationReducer.finishSync(request, result: result)
    if activeSyncPresentationRequest == request {
      activeSyncPresentationRequest = nil
    }
  }

  private func updateSyncPresentationLocalFacts() {
    syncPresentationReducer.updateLocalFacts(
      pendingCount: syncPendingCount,
      conflictCount: conflicts.count
    )
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
