import BirthdayCore
import Foundation
import SwiftData
import SwiftUI
import UIKit

@main
struct BirthdayMobileApp: App {
  init() {
    let bootstrap = UITestBootstrap()
    let configuration = AppConfiguration(
      apiBaseURLValue: Bundle.main.object(forInfoDictionaryKey: "BirthdayAPIBaseURL")
    )
    let runtime = SyncRuntimeCompositionPolicy(
      isUITesting: bootstrap.isEnabled,
      networkDisabled: bootstrap.networkDisabled || configuration.remoteBaseURL == nil
    )
    guard runtime.allowsSystemSyncTriggers else { return }
    AppSyncRuntime.shared.registerBackgroundRefresh()
  }

  var body: some Scene {
    WindowGroup {
      BirthdayAppBootstrapView()
    }
  }
}

@MainActor
private struct BirthdayAppBootstrapView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var container: ModelContainer?
  @State private var model: AppModel?
  @State private var initializationError: String?
  @State private var initializationAttempt = 0
  @State private var networkRestorationMonitor: NetworkRestorationMonitor?
  @State private var networkMonitorLifecycle = NetworkRestorationMonitorLifecycle()
  @State private var sceneSyncRequests = SceneSyncRequestAdapter()
  private let uiTestBootstrap = UITestBootstrap()
  private let appConfiguration = AppConfiguration(
    apiBaseURLValue: Bundle.main.object(forInfoDictionaryKey: "BirthdayAPIBaseURL")
  )

  var body: some View {
    Group {
      if let container, let model {
        ZStack {
          AppFlowView(model: model)
            .accessibilityHidden(scenePhase != .active)
            .allowsHitTesting(scenePhase == .active)

          if scenePhase != .active {
            PrivacyShieldView()
              .transition(.identity)
              .zIndex(1)
          }
        }
        .modelContainer(container)
        .task {
          await SyncRootRuntimeBootstrapper(policy: syncRuntimePolicy).bootstrap(
            runtimeGeneration: { model.currentSyncRuntimeLifecycleGeneration },
            reload: { await model.reload() },
            runtimeStillPermitted: { model.permitsSyncRuntimeLifecycle($0) },
            installRuntime: {
              await AppSyncRuntime.shared.install(model: model, lifecycleGeneration: $0)
            },
            sceneIsActive: { scenePhase == .active },
            activateOrdinaryTriggers: {
              startActiveSceneSync(
                for: model,
                trigger: .appLaunch,
                reloadBeforeRequest: false
              )
            }
          )
        }
        .onChange(of: scenePhase) { _, newPhase in
          switch newPhase {
          case .active:
            model.refreshAuthenticationCapability()
            if syncRuntimeEnabled {
              startActiveSceneSync(for: model, trigger: .foreground)
            } else {
              Task { await model.reload() }
            }
          case .background:
            deactivateSceneSyncRuntime()
            model.lockForBackground()
          case .inactive:
            deactivateSceneSyncRuntime()
          @unknown default:
            break
          }
        }
        .onChange(of: model.isSyncRuntimeEnabled) { _, enabled in
          if enabled, let lifecycleGeneration = model.currentSyncRuntimeLifecycleGeneration {
            Task {
              let installed = await AppSyncRuntime.shared.install(
                model: model,
                lifecycleGeneration: lifecycleGeneration
              )
              guard
                installed,
                model.permitsSyncRuntimeLifecycle(lifecycleGeneration),
                scenePhase == .active
              else { return }
              startActiveSceneSync(for: model, trigger: .foreground)
            }
          } else {
            deactivateSceneSyncRuntime()
            AppSyncRuntime.shared.uninstall(model: model)
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
          Task { await model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
          Task { await model.reload() }
        }
        .onReceive(
          NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
        ) { _ in
          Task { await model.reload() }
        }
      } else if let initializationError {
        LocalDatabaseFailureView(message: initializationError) {
          initializationAttempt += 1
        }
      } else {
        ProgressView("正在打开本地生日资料")
          .tint(ModernAirTheme.tide)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(ModernAirTheme.mist.ignoresSafeArea())
      }
    }
    .task(id: initializationAttempt) {
      initializeLocalDatabase()
    }
  }

  private func initializeLocalDatabase() {
    initializationError = nil

    do {
      let configuration = ModelConfiguration(
        isStoredInMemoryOnly: uiTestBootstrap.isEnabled
      )
      let container = try BirthdayModelContainer.make(configuration: configuration)
      if uiTestBootstrap.isSnapshotImportFixtureEnabled {
        try seedSnapshotImportPreview(in: container)
      }
      self.container = container
      model = makeAppModel(container: container)
    } catch {
      container = nil
      model = nil
      initializationError = "无法打开本地生日资料。请确认设备有可用存储空间后重新尝试；若问题持续，请重新打开应用。"
    }
  }

  private var syncRuntimeEnabled: Bool {
    syncRuntimePolicy.allowsSystemSyncTriggers
  }

  private var syncRuntimePolicy: SyncRuntimeCompositionPolicy {
    SyncRuntimeCompositionPolicy(
      isUITesting: uiTestBootstrap.isEnabled,
      networkDisabled: uiTestBootstrap.networkDisabled || appConfiguration.remoteBaseURL == nil
    )
  }

  private func startActiveSceneSync(
    for model: AppModel,
    trigger: SyncTrigger,
    reloadBeforeRequest: Bool = true
  ) {
    guard model.isSyncRuntimeEnabled else { return }
    stopNetworkRestorationMonitoring()
    sceneSyncRequests.activate(
      reload: {
        if reloadBeforeRequest { await model.reload() }
      },
      configure: { generation in
        configureOrdinarySyncTriggers(for: model, generation: generation)
      },
      request: {
        guard model.isSyncRuntimeEnabled else { return }
        await model.requestSync(trigger)
      }
    )
  }

  private func configureOrdinarySyncTriggers(
    for model: AppModel,
    generation: SceneSyncGeneration
  ) {
    guard
      syncRuntimeEnabled,
      model.isSyncRuntimeEnabled,
      sceneSyncRequests.permits(generation),
      !Task.isCancelled
    else { return }

    switch networkMonitorLifecycle.update(isActive: true) {
    case .none:
      break
    case .startNewMonitor:
      let monitor = NetworkRestorationMonitor {
        sceneSyncRequests.enqueueNetworkRestoration(for: generation) {
          guard model.isSyncRuntimeEnabled else { return }
          await model.requestSync(.networkRestored)
        }
      }
      networkRestorationMonitor = monitor
      monitor.start()
    case .stopMonitor:
      networkRestorationMonitor?.stop()
      networkRestorationMonitor = nil
    }
  }

  private func deactivateSceneSyncRuntime() {
    sceneSyncRequests.invalidate()
    stopNetworkRestorationMonitoring()
  }

  private func stopNetworkRestorationMonitoring() {
    _ = networkMonitorLifecycle.update(isActive: false)
    networkRestorationMonitor?.stop()
    networkRestorationMonitor = nil
  }

  private func makeAppModel(container: ModelContainer) -> AppModel {
    if uiTestBootstrap.isEnabled {
      let suiteName = "top.qisw.birthday.ui-tests"
      let preferences = UserDefaults(suiteName: suiteName)!
      preferences.removePersistentDomain(forName: suiteName)

      // The UI-test composition injects an offline binder, so no view can
      // accidentally turn the offline regression flow into a network test.
      precondition(
        uiTestBootstrap.networkDisabled,
        "UI tests must opt into the no-network composition"
      )

      let snapshotFixtureEnabled = uiTestBootstrap.isSnapshotImportFixtureEnabled
      let serverDeviceBinder: any ServerDeviceBinding =
        snapshotFixtureEnabled
        ? UITestSnapshotServerDeviceBinder(
          firstLoadFails: uiTestBootstrap.snapshotFirstLoadFails
        )
        : OfflineServerDeviceBinder()
      let refreshScenario = UITestSnapshotRefreshScenario(
        firstLoadFails: snapshotFixtureEnabled && uiTestBootstrap.snapshotFirstRefreshFails
      )
      let fixtureNow = Date(timeIntervalSince1970: 1_789_876_800)
      let fixtureTimeZone = TimeZone(identifier: "Asia/Shanghai")!
      let selectedMonth: Date
      let now: @Sendable () -> Date
      let timeZone: @Sendable () -> TimeZone
      if snapshotFixtureEnabled {
        selectedMonth = fixtureNow
        now = { fixtureNow }
        timeZone = { fixtureTimeZone }
      } else {
        selectedMonth = Date()
        now = Date.init
        timeZone = { .current }
      }

      let store = BirthdayStore(modelContainer: container)
      let model = AppModel(
        store: store,
        selectedMonth: selectedMonth,
        preferences: preferences,
        authenticator: UITestAppLockAuthenticator(),
        serverDeviceBinder: serverDeviceBinder,
        notificationScheduler: UITestNotificationScheduler(),
        oneShotNotificationScheduler: UITestOneShotNotificationScheduler(),
        reminderPlanner: ReminderPlanner(),
        requestNotificationAuthorization: { true },
        snapshotRecordLoader: { store in
          try await refreshScenario.loadRecords(from: store)
        },
        now: now,
        timeZone: timeZone
      )
      if uiTestBootstrap.transportCleanupFailure {
        configureTransportCleanupFailureFixture(model: model, store: store)
      }
      return model
    }

    return ProductionAppModelFactory(
      appConfiguration: appConfiguration,
      syncRuntimePolicy: syncRuntimePolicy
    ).make(container: container)
  }

  private func configureTransportCleanupFailureFixture(model: AppModel, store: BirthdayStore) {
    let deviceID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let secure = UITestDeleteFailingSecureTokenStore()
    let credentials = DeviceCredentialStore(secure: secure)
    try! credentials.save(
      DeviceCredentials(
        deviceId: deviceID,
        accessToken: "ui-test-access",
        accessExpiresAt: Date(timeIntervalSinceNow: 3_600),
        refreshToken: "ui-test-refresh",
        refreshExpiresAt: Date(timeIntervalSinceNow: 86_400),
        username: "admin"
      ))
    let api = UITestTransportCleanupMobileAPI(deviceID: deviceID)
    let remoteAccessGate = RemoteSyncAccessGate()
    let scheduler = UITestNotificationScheduler()
    let planner = ReminderPlanner()
    let engine = SyncEngine(
      api: api,
      store: store,
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )
    model.configureSyncCoordinator(
      SyncCoordinator(
        syncEngine: engine,
        remoteAccessGate: remoteAccessGate,
        store: store,
        credentials: credentials,
        notificationScheduler: scheduler,
        reminderPlanner: planner,
        publish: { [weak model] outcome in await model?.publishCompletedSync(outcome) }
      ),
      initiallyBound: true
    )
    model.configureDeviceManagement(
      DeviceManagementService(
        api: api,
        credentials: credentials,
        remoteAccessGate: remoteAccessGate
      ))
  }

  private func seedSnapshotImportPreview(in container: ModelContainer) throws {
    let context = ModelContext(container)
    let date = Date(timeIntervalSince1970: 1_788_000_000)
    let entity = BirthdayEntity(
      id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      draft: BirthdayDraft(
        name: "妈妈",
        lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ),
      nextSolarDate: date,
      now: date
    )
    entity.nextSolarDate = nil
    entity.syncStateRaw = SyncState.synced.rawValue
    context.insert(entity)
    try context.save()
  }
}

private enum UITestCredentialDeleteError: Error {
  case denied
}

private final class UITestDeleteFailingSecureTokenStore: SecureTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  func save(_ data: Data, account: String) throws {
    lock.withLock { values[account] = data }
  }

  func read(account: String) throws -> Data? {
    lock.withLock { values[account] }
  }

  func delete(account: String) throws {
    throw UITestCredentialDeleteError.denied
  }
}

private actor UITestTransportCleanupMobileAPI: MobileAPI {
  private let deviceID: UUID

  init(deviceID: UUID) {
    self.deviceID = deviceID
  }

  func login(_ request: LoginRequest) async throws -> TokenResponse {
    throw MobileAPIError.invalidResponse
  }

  func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
    throw MobileAPIError.invalidResponse
  }

  func snapshot(accessToken: String) async throws -> SnapshotResponse {
    throw MobileAPIError.invalidResponse
  }

  func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse {
    throw MobileAPIError.invalidResponse
  }

  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    throw MobileAPIError.invalidResponse
  }

  func revoke(deviceId: UUID, accessToken: String) async throws {
    throw MobileAPIError.transport("ui_test_transport_cleanup")
  }

  func devices(accessToken: String) async throws -> [MobileDevice] {
    [
      MobileDevice(
        deviceId: deviceID,
        deviceName: "UI Test iPhone",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastUsedAt: nil,
        revokedAt: nil
      )
    ]
  }
}

struct OfflineServerDeviceBinder: ServerDeviceBinding {
  func bind(username: String, password: String, deviceName: String) async throws {
    throw MobileAPIError.transport("network_disabled")
  }

  func loadSnapshot() async throws -> SnapshotResponse {
    throw MobileAPIError.transport("network_disabled")
  }
}

private struct UITestSnapshotServerDeviceBinder: ServerDeviceBinding {
  private let scenario: UITestSnapshotLoadScenario

  init(firstLoadFails: Bool) {
    scenario = UITestSnapshotLoadScenario(firstLoadFails: firstLoadFails)
  }

  func bind(username: String, password: String, deviceName: String) async throws {}

  func loadSnapshot() async throws -> SnapshotResponse {
    try await scenario.loadSnapshot()
  }
}

private actor UITestSnapshotLoadScenario {
  private var firstLoadFails: Bool

  init(firstLoadFails: Bool) {
    self.firstLoadFails = firstLoadFails
  }

  func loadSnapshot() throws -> SnapshotResponse {
    if firstLoadFails {
      firstLoadFails = false
      throw MobileAPIError.transport("ui_test_snapshot_failure")
    }

    let date = Date(timeIntervalSince1970: 1_788_000_000)
    return SnapshotResponse(
      cursor: 41,
      birthdays: [
        APIBirthday(
          id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
          name: "妈妈",
          lunarMonth: 8,
          lunarDay: 15,
          isLeapMonth: false,
          reminder: .defaults,
          nextSolarDate: nil,
          version: 3,
          createdAt: date,
          updatedAt: date,
          deletedAt: nil
        ),
        APIBirthday(
          id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
          name: "爸爸",
          lunarMonth: 8,
          lunarDay: 16,
          isLeapMonth: false,
          reminder: .defaults,
          nextSolarDate: nil,
          version: 2,
          createdAt: date,
          updatedAt: date,
          deletedAt: nil
        ),
        APIBirthday(
          id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
          name: " 妈妈 ",
          lunarMonth: 8,
          lunarDay: 15,
          isLeapMonth: false,
          reminder: .defaults,
          nextSolarDate: nil,
          version: 1,
          createdAt: date,
          updatedAt: date,
          deletedAt: nil
        ),
      ]
    )
  }
}

private actor UITestSnapshotRefreshScenario {
  private var firstLoadFails: Bool

  init(firstLoadFails: Bool) {
    self.firstLoadFails = firstLoadFails
  }

  func loadRecords(from store: BirthdayStore) async throws -> [BirthdayRecord] {
    if firstLoadFails {
      firstLoadFails = false
      throw MobileAPIError.transport("ui_test_snapshot_refresh_failure")
    }
    return try await store.activeBirthdays()
  }
}

private struct UITestAppLockAuthenticator: AppLockAuthenticating {
  func capability() -> AppLockCapability {
    .faceID
  }

  func unlock(reason: String) async throws -> Bool {
    true
  }
}

private struct UITestOneShotNotificationScheduler: OneShotNotificationScheduling {
  func schedule(birthdayID: UUID, name: String, now: Date) async -> OneShotNotificationResult {
    .scheduled
  }
}

private struct UITestNotificationScheduler: NotificationScheduling {
  func apply(_ plan: ReminderPlan) async throws -> NotificationHealth {
    let scheduledCount =
      plan.birthdayNotifications.count
      + (plan.maintenanceNotification == nil ? 0 : 1)
    return NotificationHealth(
      state: .scheduled,
      scheduledCount: scheduledCount,
      coverageEnd: plan.coverageEnd,
      errorCategory: nil
    )
  }
}

private struct PrivacyShieldView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "lock.shield.fill")
        .font(.system(size: 36, weight: .medium))
        .foregroundStyle(ModernAirTheme.tide)
        .accessibilityHidden(true)
      Text("岁时")
        .font(.system(.title2, design: .rounded, weight: .semibold))
        .foregroundStyle(ModernAirTheme.ink)
      Text("生日资料已隐藏")
        .font(.subheadline)
        .foregroundStyle(ModernAirTheme.secondaryInk)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("岁时，生日资料已隐藏")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ModernAirTheme.mist.ignoresSafeArea())
  }
}

private struct AppFlowView: View {
  @Bindable var model: AppModel

  var body: some View {
    switch model.launchState {
    case .onboarding:
      OnboardingView(model: model)
    case .locked:
      AppLockView(model: model)
    case .ready:
      RootTabView(model: model)
    }
  }
}

struct RootTabView: View {
  @Bindable var model: AppModel

  var body: some View {
    TabView(selection: $model.selectedTab) {
      NavigationStack {
        CalendarHomeView(model: model)
      }
      .tabItem {
        Label("日历", systemImage: "calendar")
      }
      .tag(AppModel.Tab.calendar)

      NavigationStack {
        BirthdayListView(model: model)
      }
      .tabItem {
        Label("全部", systemImage: "list.bullet")
      }
      .tag(AppModel.Tab.birthdays)

      NavigationStack {
        ConflictListView(model: model)
      }
      .tabItem {
        Label("冲突", systemImage: "arrow.triangle.2.circlepath")
      }
      .badge(model.conflicts.count)
      .tag(AppModel.Tab.conflicts)

      NavigationStack {
        SettingsView(model: model)
      }
      .tabItem {
        Label("设置", systemImage: "gearshape")
      }
      .tag(AppModel.Tab.settings)
    }
    .tint(ModernAirTheme.tide)
    .sheet(isPresented: $model.isPresentingEditor) {
      BirthdayEditorView(model: model)
    }
  }
}

private struct LocalDatabaseFailureView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("本地资料无法打开", systemImage: "externaldrive.badge.exclamationmark")
    } description: {
      Text(message)
    } actions: {
      Button("重新尝试", action: retry)
        .buttonStyle(.borderedProminent)
        .tint(ModernAirTheme.tide)
        .frame(minHeight: 44)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ModernAirTheme.mist.ignoresSafeArea())
  }
}
