import BirthdayCore
import SwiftData
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

@main
struct BirthdayMobileApp: App {
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
  private let uiTestBootstrap = UITestBootstrap()

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
        .task { await model.reload() }
        .onChange(of: scenePhase) { _, newPhase in
          switch newPhase {
          case .active:
            model.refreshAuthenticationCapability()
            Task { await model.reload() }
          case .background:
            model.lockForBackground()
          case .inactive:
            break
          @unknown default:
            break
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
      let container = try ModelContainer(
        for: BirthdayEntity.self,
        SyncOperationEntity.self,
        configurations: configuration
      )
      self.container = container
      model = makeAppModel(container: container)
    } catch {
      container = nil
      model = nil
      initializationError = "无法打开本地生日资料。请确认设备有可用存储空间后重新尝试；若问题持续，请重新打开应用。"
    }
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

      return AppModel(
        store: BirthdayStore(modelContainer: container),
        preferences: preferences,
        authenticator: UITestAppLockAuthenticator(),
        serverDeviceBinder: OfflineServerDeviceBinder(),
        notificationScheduler: UITestNotificationScheduler(),
        oneShotNotificationScheduler: UITestOneShotNotificationScheduler(),
        reminderPlanner: ReminderPlanner(),
        requestNotificationAuthorization: { true }
      )
    }

    let notificationCenter = UNUserNotificationCenter.current()
    let notificationClient = SystemNotificationCenterClient(center: notificationCenter)
    let credentials = DeviceCredentialStore(secure: KeychainStore())
    let mobileAPI = MobileAPIClient(
      baseURL: URL(string: "https://qisw.top/api/mobile")!
    )
    return AppModel(
      store: BirthdayStore(modelContainer: container),
      preferences: .standard,
      authenticator: LocalAuthenticationService(),
      serverDeviceBinder: ServerDeviceBinder(api: mobileAPI, credentials: credentials),
      notificationScheduler: UserNotificationScheduler(
        center: notificationClient
      ),
      oneShotNotificationScheduler: OneShotNotificationScheduler(center: notificationClient),
      reminderPlanner: ReminderPlanner(),
      requestNotificationAuthorization: {
        try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
      }
    )
  }
}

struct OfflineServerDeviceBinder: ServerDeviceBinding {
  func bind(username: String, password: String, deviceName: String) async throws {
    throw MobileAPIError.transport("network_disabled")
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
