import BirthdayCore
import Foundation
import Observation

struct UITestBootstrap: Equatable, Sendable {
  let isEnabled: Bool
  let networkDisabled: Bool
  let snapshotImportPreviewEnabled: Bool
  let snapshotFirstLoadFails: Bool
  let snapshotFirstRefreshFails: Bool
  let transportCleanupFailure: Bool
  let storeReleaseLocalOnly: Bool
  let cloudKitSyncEnabled: Bool
  let cloudAccountChange: Bool
  let desktopPreview: Bool
  let isCloudKitProductionSmoke: Bool

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    isEnabled = arguments.contains("-ui-testing")
    networkDisabled = arguments.contains("-network-disabled")
    snapshotImportPreviewEnabled = arguments.contains("-snapshot-import-preview")
    snapshotFirstLoadFails = arguments.contains("-snapshot-first-load-fails")
    snapshotFirstRefreshFails = arguments.contains("-snapshot-first-refresh-fails")
    transportCleanupFailure = arguments.contains("-transport-cleanup-failure")
    storeReleaseLocalOnly = arguments.contains("-store-release-local-only")
    cloudKitSyncEnabled = arguments.contains("-cloudkit-sync")
    cloudAccountChange = arguments.contains("-cloud-account-change")
    desktopPreview = arguments.contains("-desktop-preview")
    #if DEBUG
      isCloudKitProductionSmoke = isEnabled
        && arguments.contains("-cloudkit-production-smoke")
    #else
      isCloudKitProductionSmoke = false
    #endif
  }

  var isSnapshotImportFixtureEnabled: Bool {
    isEnabled && networkDisabled && snapshotImportPreviewEnabled
  }

  var isStoredInMemoryOnly: Bool { isEnabled }

  var syncRuntimePolicy: SyncRuntimeCompositionPolicy {
    SyncRuntimeCompositionPolicy(
      isUITesting: isEnabled && !isCloudKitProductionSmoke,
      networkDisabled: networkDisabled
    )
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

  func removeAllBirthdayNotifications(generation: UInt64) async -> NotificationHealth {
    guard generation >= latestRequestedGeneration else {
      if let runningTask { await runningTask.value }
      return latestHealth
    }

    latestRequestedGeneration = generation
    pendingRequest = nil
    if let runningTask { await runningTask.value }

    let result = await scheduler.removeAllBirthdayNotifications()
    if generation == latestRequestedGeneration {
      latestHealth = result
    }
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

  var selectedTab: Tab = .calendar {
    didSet {
      if macNavigation.section != selectedTab {
        macNavigation.reduce(.selectSection(selectedTab))
      }
    }
  }
  private(set) var records: [BirthdayRecord]
  var selectedMonth: Date
  var selectedDay: Int?
  var isPresentingEditor = false
  var macNavigation = MacNavigationState()
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
  private(set) var cloudConflicts: [CloudConflictRecord] = []
  private(set) var conflictErrorMessage: String?
  private(set) var resolvingConflictID: UUID?
  private(set) var isRequestingNotificationAuthorization = false
  private(set) var notificationsEnabled: Bool
  private(set) var notificationHealth = NotificationHealth(
    state: .notRequested,
    scheduledCount: 0,
    coverageEnd: nil,
    errorCategory: nil
  )
  private(set) var syncStatus: SyncStatus = .idle
  private(set) var cloudSyncStatus: CloudSyncStatus = .disabled
  private(set) var isManualSyncing = false
  private(set) var cloudSyncOperationGeneration = 0
  private(set) var cloudSyncCompletionGeneration = 0
  private(set) var cloudSyncPendingChangeCount: Int?
  var cloudSyncDiagnosticSummary: String {
    let pending = cloudSyncPendingChangeCount.map(String.init) ?? "unknown"
    return "started=\(cloudSyncOperationGeneration);completed=\(cloudSyncCompletionGeneration);pending=\(pending);status=\(cloudSyncDiagnosticStatus)"
  }
  var syncPresentation: SyncPresentation { syncPresentationReducer.presentation }
  private(set) var syncPendingCount = 0
  private(set) var managedDevices: [ManagedDevice] = []
  private(set) var isLoadingManagedDevices = false
  private(set) var isManagingDevice = false
  private(set) var deviceManagementMessage: String?
  var isSyncRuntimeEnabled: Bool { syncPresentationReducer.isRemoteSyncEnabled }
  var isCloudSyncEnabled: Bool {
    syncMode == .cloudKit && cloudSyncStatus != .disabled
  }
  var hasSyncConflicts: Bool { !conflicts.isEmpty || !cloudConflicts.isEmpty }
  var syncConflictCount: Int { conflicts.count + cloudConflicts.count }
  let isServerBindingAvailable: Bool
  let syncMode: AppSyncMode
  private(set) var pendingLocalCleanup: PendingLocalCleanup?
  let localOnlyStatusDetail: String
  let platformServices: PlatformServices

  var needsRevokedCredentialCleanup: Bool {
    pendingLocalCleanup == .serverRevoked
  }

  var canResumeSyncAfterLocalCleanupFailure: Bool {
    pendingLocalCleanup == .transportUnknown
  }

  var isServerBindingBlocked: Bool {
    isManagingDevice || pendingUnlinkLifecycleGeneration != nil || pendingLocalCleanup != nil
      || lifecyclePauseAcquisitionCount > 0 || serverBindingState == .binding
  }

  let store: BirthdayStore
  let oneShotNotificationScheduler: any OneShotNotificationScheduling
  let notificationScheduler: any NotificationScheduling

  private var appLockSession: AppLockSessionState
  private var reminderGeneration: UInt64 = 0
  private var reminderOperationsInFlight = 0
  private var pendingInitialSnapshot: SnapshotResponse?
  private let preferences: UserDefaults
  private let syncLastSuccessStore: SyncLastSuccessStore
  private let authenticator: any AppLockAuthenticating
  private let serverDeviceBinder: any ServerDeviceBinding
  private let requestNotificationAuthorization: @MainActor () async throws -> Bool
  private let snapshotRecordLoader: @Sendable (BirthdayStore) async throws -> [BirthdayRecord]
  private let now: @Sendable () -> Date
  private let timeZone: @Sendable () -> TimeZone
  private let conflictResolver: ConflictResolver
  private let reminderRebuildCoordinator: ReminderRebuildCoordinator
  private var syncCoordinator: SyncCoordinator?
  private var cloudSyncRuntime: (any CloudSyncRuntimeControlling)?
  private var deviceManagementService: DeviceManagementService?
  private var syncPresentationReducer: SyncPresentationReducer
  private var activeSyncPresentationRequest: SyncPresentationRequest?
  private var pendingUnlinkLifecycleGeneration: SyncRuntimeLifecycleGeneration?
  private var lifecyclePauseAcquisitionCount = 0

  var currentSyncRuntimeLifecycleGeneration: SyncRuntimeLifecycleGeneration? {
    syncPresentationReducer.currentRuntimeLifecycleGeneration
  }

  func permitsSyncRuntimeLifecycle(_ generation: SyncRuntimeLifecycleGeneration) -> Bool {
    syncPresentationReducer.permitsRuntimeLifecycle(generation)
  }

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
    platformServices: PlatformServices = .live,
    syncMode: AppSyncMode = .none,
    localOnlyStatusDetail: String = "生日与提醒只保存在这台设备上。",
    isServerBindingAvailable: Bool = false,
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
    self.platformServices = platformServices
    self.syncMode = syncMode
    self.localOnlyStatusDetail = localOnlyStatusDetail
    self.isServerBindingAvailable = isServerBindingAvailable
    let syncLastSuccessStore = SyncLastSuccessStore(preferences: preferences)
    self.syncLastSuccessStore = syncLastSuccessStore
    syncPresentationReducer = SyncPresentationReducer(lastSuccess: syncLastSuccessStore.load())
    self.authenticator = authenticator
    self.serverDeviceBinder = serverDeviceBinder
    let notificationPreference = DeviceNotificationPreference(preferences: preferences)
    notificationsEnabled = notificationPreference.isEnabled
    let deviceNotificationScheduler = DeviceNotificationScheduler(
      base: notificationScheduler,
      preference: notificationPreference
    )
    self.notificationScheduler = deviceNotificationScheduler
    self.oneShotNotificationScheduler = DeviceNotificationOneShotScheduler(
      base: oneShotNotificationScheduler,
      preference: notificationPreference
    )
    self.requestNotificationAuthorization = requestNotificationAuthorization
    self.snapshotRecordLoader = snapshotRecordLoader
    self.now = now
    self.timeZone = timeZone
    conflictResolver = ConflictResolver(store: store, now: now, timeZone: timeZone)
    reminderRebuildCoordinator = ReminderRebuildCoordinator(
      planner: reminderPlanner,
      scheduler: deviceNotificationScheduler
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

  func reduceMacNavigation(_ action: MacNavigationAction) {
    macNavigation.reduce(action)
    selectedTab = macNavigation.section
  }

  @discardableResult
  func deleteBirthday(id: UUID) async -> Bool {
    do {
      try await store.softDelete(id: id, now: now())
      await reload()
      Task { await requestSync(.localMutation) }
      return true
    } catch {
      return false
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

  func resolveCloudConflictKeepingLocal(id: UUID) async {
    await resolveCloudConflict(id: id) {
      try await self.store.resolveCloudConflictKeepingLocal(id: id, now: self.now())
    }
  }

  func resolveCloudConflictUsingICloud(id: UUID) async {
    await resolveCloudConflict(id: id) {
      try await self.store.resolveCloudConflictUsingICloud(
        id: id,
        now: self.now(),
        timeZone: self.timeZone()
      )
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

  private func resolveCloudConflict(
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
      await requestCloudSync()
    } catch {
      conflictErrorMessage = "未能解决 iCloud 冲突，本机资料未改变。请重新载入后再试。"
    }
  }

  private func reloadConflicts() async {
    do {
      if syncMode == .cloudKit {
        conflicts = []
        cloudConflicts = try await store.cloudConflicts()
      } else {
        conflicts = try await conflictResolver.conflicts()
        cloudConflicts = []
      }
      conflictErrorMessage = nil
    } catch {
      conflicts = []
      cloudConflicts = []
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
    guard !isServerBindingBlocked else { return false }

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
      if let deviceManagementService {
        try await deviceManagementService.performBinding(
          using: serverDeviceBinder,
          username: normalizedUsername,
          password: password,
          deviceName: normalizedDeviceName
        )
      } else {
        try await serverDeviceBinder.bind(
          username: normalizedUsername,
          password: password,
          deviceName: normalizedDeviceName
        )
      }
      if syncCoordinator != nil {
        syncPresentationReducer.bind()
        pendingLocalCleanup = nil
        pendingUnlinkLifecycleGeneration = nil
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
    guard notificationsEnabled, !isRequestingNotificationAuthorization else { return }
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
    if error as? DeviceManagementError == .operationInProgress {
      return "正在处理设备或停止同步，请完成当前操作后再绑定。"
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

    let lockPresentation = platformServices.lockPresentation(for: lockCapability)

    do {
      let succeeded = try await authenticator.unlock(reason: "解锁生日资料")
      guard appLockSession.completeAuthentication(attempt, succeeded: succeeded) else { return }

      if succeeded {
        unlockState = .idle
      } else {
        unlockState = .failed(
          message: "身份验证未通过。请再次使用生物识别或\(lockPresentation.credentialName)验证。"
        )
      }
    } catch AppLockError.cancelled {
      guard appLockSession.completeAuthentication(attempt, succeeded: false) else { return }
      unlockState = .failed(message: "已取消解锁。需要时可再次验证。")
    } catch AppLockError.unavailable {
      guard appLockSession.completeAuthentication(attempt, succeeded: false) else { return }
      unlockState = .failed(
        message: "此设备当前无法使用生物识别或\(lockPresentation.credentialName)，请检查系统设置后重试。"
      )
    } catch AppLockError.evaluationFailed {
      guard appLockSession.completeAuthentication(attempt, succeeded: false) else { return }
      unlockState = .failed(
        message: "未能验证身份。请再次尝试生物识别或\(lockPresentation.credentialName)。"
      )
    } catch {
      guard appLockSession.completeAuthentication(attempt, succeeded: false) else { return }
      unlockState = .failed(message: "解锁失败。请稍后重试。")
    }
  }

  func handleLockEvent(_ event: AppLockLifecycleEvent) {
    guard platformServices.shouldLock(for: event) else { return }
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
    guard notificationsEnabled else { return }
    let generation = nextReminderGeneration()
    await rebuildFreshSnapshot(generation: generation, reportReadFailure: true)
  }

  func setNotificationsEnabled(_ isEnabled: Bool) async {
    guard notificationsEnabled != isEnabled else { return }
    notificationsEnabled = isEnabled
    DeviceNotificationPreference(preferences: preferences).setEnabled(isEnabled)
    let generation = nextReminderGeneration()

    if isEnabled {
      await rebuildFreshSnapshot(generation: generation, reportReadFailure: true)
      return
    }

    beginReminderOperation()
    let health = await reminderRebuildCoordinator.removeAllBirthdayNotifications(
      generation: generation
    )
    endReminderOperation()
    if generation == reminderGeneration {
      notificationHealth = health.state == .failed
        ? health
        : disabledNotificationHealth()
    }
  }

  func configureCloudSyncRuntime(_ runtime: any CloudSyncRuntimeControlling) {
    cloudSyncRuntime = runtime
    cloudSyncStatus = runtime.initialStatus
  }

  func startCloudSync() async {
    guard syncMode == .cloudKit, let cloudSyncRuntime else { return }
    await applyCloudSyncOperation { await cloudSyncRuntime.start() }
  }

  func requestCloudSync(isManual: Bool = true) async {
    guard syncMode == .cloudKit, let cloudSyncRuntime, cloudSyncStatus != .syncing else { return }
    if isManual { isManualSyncing = true }
    defer {
      if isManual { isManualSyncing = false }
    }
    await applyCloudSyncOperation { await cloudSyncRuntime.requestSync() }
  }

  func setCloudSyncEnabled(_ isEnabled: Bool) async {
    guard syncMode == .cloudKit, let cloudSyncRuntime else { return }
    await applyCloudSyncOperation(
      showProgress: isEnabled,
      reloadAfterOperation: isEnabled
    ) {
      await cloudSyncRuntime.setEnabled(isEnabled)
    }
  }

  func confirmCloudAccountChange() async {
    guard syncMode == .cloudKit, let cloudSyncRuntime else { return }
    await applyCloudSyncOperation {
      await cloudSyncRuntime.confirmAccountChange()
    }
  }

  func cancelCloudAccountChange() async {
    guard syncMode == .cloudKit, let cloudSyncRuntime else { return }
    await applyCloudSyncOperation(showProgress: false, reloadAfterOperation: false) {
      await cloudSyncRuntime.cancelAccountChange()
    }
  }

  private func applyCloudSyncOperation(
    showProgress: Bool = true,
    reloadAfterOperation: Bool = true,
    operation: () async -> CloudSyncStatus
  ) async {
    cloudSyncOperationGeneration += 1
    let operationGeneration = cloudSyncOperationGeneration
    if showProgress { cloudSyncStatus = .syncing }
    let status = await operation()
    cloudSyncStatus = status

    if reloadAfterOperation { await reload() }
    cloudSyncPendingChangeCount = try? await store.pendingCloudChangeCount()
    cloudSyncCompletionGeneration = operationGeneration
  }

  private var cloudSyncDiagnosticStatus: String {
    switch cloudSyncStatus {
    case .disabled: "disabled"
    case .unavailable: "unavailable"
    case .syncing: "syncing"
    case .pending: "pending"
    case .synchronized: "synchronized"
    case .accountChangeRequiresConfirmation: "account-change"
    case .conflicts: "conflicts"
    case .failed(let category): "failed-\(category.rawValue)"
    }
  }

  func configureSyncCoordinator(_ coordinator: SyncCoordinator, initiallyBound: Bool) {
    syncCoordinator = coordinator
    syncPresentationReducer.configureRemoteRuntime(initiallyBound: initiallyBound)
    if !initiallyBound { syncLastSuccessStore.clear() }
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

    pendingLocalCleanup = await deviceManagementService.pendingLocalCleanup
    if let pendingLocalCleanup {
      managedDevices = []
      deviceManagementMessage = cleanupMessage(for: pendingLocalCleanup)
      return
    }

    isLoadingManagedDevices = true
    defer { isLoadingManagedDevices = false }
    do {
      managedDevices = try await deviceManagementService.listDevices()
      deviceManagementMessage = nil
    } catch DeviceManagementError.credentialsUnavailable {
      managedDevices = []
      await enterMissingCredentials()
      deviceManagementMessage = nil
    } catch DeviceManagementError.rebindRequired {
      managedDevices = []
      await enterRebindRequired()
      deviceManagementMessage = "设备列表认证已失效；同步已暂停，请重新绑定。"
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
    guard
      !isManagingDevice,
      serverBindingState != .binding,
      pendingUnlinkLifecycleGeneration == nil,
      let deviceManagementService,
      let unlinkLifecycle = syncPresentationReducer.pauseForUnlink()
    else { return nil }
    isManagingDevice = true
    deviceManagementMessage = nil
    pendingUnlinkLifecycleGeneration = unlinkLifecycle
    defer { isManagingDevice = false }

    do {
      let outcome = try await deviceManagementService.beginUnlinkCurrent()
      if outcome == .unlinked {
        disableSyncRuntimeAfterUnlink()
      } else if !syncPresentationReducer.canRestoreAfterUnlink(unlinkLifecycle) {
        _ = await deviceManagementService.cancelPendingLocalUnlink()
        pendingUnlinkLifecycleGeneration = nil
        return nil
      }
      return outcome
    } catch DeviceManagementError.credentialClearFailedAfterServerRevoke {
      pendingLocalCleanup = .serverRevoked
      failCloseRevokedRuntime(
        message: "服务器已撤销此设备，但本机同步凭据清除失败。请再次清理本机凭据；期间同步保持停用。"
      )
      return nil
    } catch {
      await applyDeviceManagementError(error)
      _ = syncPresentationReducer.restoreAfterUnlink(unlinkLifecycle)
      pendingUnlinkLifecycleGeneration = nil
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
      pendingLocalCleanup = await deviceManagementService.pendingLocalCleanup
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
        await enterMissingCredentials()
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
    notificationHealth = notificationsEnabled ? health : disabledNotificationHealth()
    syncStatus = .synchronized(summary)
    await reloadConflicts()
    await refreshSyncCounts()
    if let request = activeSyncPresentationRequest {
      finishSyncPresentation(request, result: .completed(at: now()))
    }
  }

  func requestSync(_ trigger: SyncTrigger) async {
    if syncMode == .cloudKit {
      await requestCloudSync(isManual: trigger == .manual)
      return
    }
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
      DeviceManagementError.revokedSessionRequiresLocalCleanup:
      await enterRebindRequired()
      deviceManagementMessage = "需要重新绑定后才能管理设备。"
    case DeviceManagementError.credentialsUnavailable:
      await enterMissingCredentials()
      deviceManagementMessage = nil
    case DeviceManagementError.operationInProgress:
      deviceManagementMessage = "另一项设备操作正在进行，请稍候。"
    case MobileAPIError.transport:
      deviceManagementMessage = "暂时无法连接服务器，本机资料未改变。"
    case MobileAPIError.server:
      deviceManagementMessage = "服务器未能完成设备操作，本机资料未改变。"
    default:
      deviceManagementMessage = "设备操作未完成，本机资料未改变。"
    }
  }

  private func disableSyncRuntimeAfterUnlink() {
    syncPresentationReducer.useLocalOnly()
    syncLastSuccessStore.clear()
    syncStatus = .unbound
    managedDevices = []
    pendingLocalCleanup = nil
    pendingUnlinkLifecycleGeneration = nil
    deviceManagementMessage = nil
  }

  private func failCloseRevokedRuntime(message: String) {
    syncStatus = .failed
    managedDevices = []
    pendingLocalCleanup = .serverRevoked
    pendingUnlinkLifecycleGeneration = nil
    syncPresentationReducer.failClosed(message: message)
    deviceManagementMessage = message
  }

  func cancelPendingLocalStopSync() async {
    guard
      let deviceManagementService,
      let unlinkLifecycle = pendingUnlinkLifecycleGeneration,
      await deviceManagementService.cancelPendingLocalUnlink()
    else { return }
    pendingUnlinkLifecycleGeneration = nil
    let restored = syncPresentationReducer.restoreAfterUnlink(unlinkLifecycle)
    pendingLocalCleanup = nil
    if restored { deviceManagementMessage = nil }
  }

  func resumeSyncAfterLocalCleanupFailure() async -> Bool {
    guard
      let deviceManagementService,
      pendingLocalCleanup == .transportUnknown,
      let unlinkLifecycle = pendingUnlinkLifecycleGeneration
    else { return false }
    do {
      try await deviceManagementService.resumeSyncAfterPendingLocalCleanup()
      pendingLocalCleanup = nil
      pendingUnlinkLifecycleGeneration = nil
      let restored = syncPresentationReducer.restoreAfterUnlink(unlinkLifecycle)
      if restored {
        deviceManagementMessage =
          "已保留本机同步凭据并恢复同步；若服务器已撤销此设备，下次同步会要求重新绑定。"
      }
      return restored
    } catch {
      pendingLocalCleanup = await deviceManagementService.pendingLocalCleanup
      deviceManagementMessage = cleanupMessage(for: pendingLocalCleanup)
      return false
    }
  }

  private func enterRebindRequired() async {
    syncPresentationReducer.requireRebind()
    activeSyncPresentationRequest = nil
    lifecyclePauseAcquisitionCount += 1
    defer { lifecyclePauseAcquisitionCount -= 1 }
    await deviceManagementService?.pauseForRebind()
  }

  private func enterMissingCredentials() async {
    syncPresentationReducer.transitionToMissingCredentials()
    syncLastSuccessStore.clear()
    activeSyncPresentationRequest = nil
    lifecyclePauseAcquisitionCount += 1
    defer { lifecyclePauseAcquisitionCount -= 1 }
    await deviceManagementService?.pauseForMissingCredentials()
  }

  private func cleanupMessage(for reason: PendingLocalCleanup?) -> String? {
    switch reason {
    case .transportUnknown:
      "本机同步凭据清除失败。可重试清理，或明确保留凭据并恢复同步。"
    case .serverRevoked:
      "服务器已撤销此设备，但本机同步凭据仍未能清除；只能重试清理或重新绑定。"
    case nil:
      nil
    }
  }

  private func finishSyncPresentation(
    _ request: SyncPresentationRequest,
    result: SyncPresentationCompletion
  ) {
    let accepted = syncPresentationReducer.finishSync(request, result: result)
    if accepted, case .completed(let date) = result {
      syncLastSuccessStore.save(date)
    }
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
    guard notificationsEnabled else {
      if generation == reminderGeneration {
        notificationHealth = disabledNotificationHealth()
      }
      return
    }
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

  private func disabledNotificationHealth() -> NotificationHealth {
    NotificationHealth(
      state: .notRequested,
      scheduledCount: 0,
      coverageEnd: nil,
      errorCategory: "disabled_on_device"
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
