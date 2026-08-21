import SwiftData
import SwiftUI

import BirthdayCore

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
  @State private var container: ModelContainer?
  @State private var model: AppModel?
  @State private var initializationError: String?
  @State private var initializationAttempt = 0

  var body: some View {
    Group {
      if let container, let model {
        RootTabView(model: model)
          .modelContainer(container)
          .task { await model.reload() }
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
      let container = try ModelContainer(
        for: BirthdayEntity.self,
        SyncOperationEntity.self
      )
      self.container = container
      model = AppModel(store: BirthdayStore(modelContainer: container))
    } catch {
      container = nil
      model = nil
      initializationError = "无法打开本地生日资料。请确认设备有可用存储空间后重新尝试；若问题持续，请重新打开应用。"
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
