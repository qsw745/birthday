import BirthdayCore
import SwiftUI

enum MacCommand: Equatable {
  case newBirthday
  case focusSearch
  case openSettings
  case deleteSelection
}

enum MacEditorRoute: Equatable {
  case new
  case edit(UUID)
}

enum MacNavigationAction: Equatable {
  case selectSection(AppModel.Tab)
  case selectRecord(UUID)
  case windowWidthChanged(Double)
  case command(MacCommand)
  case doubleClickRecord(UUID)
  case dismissEditor
  case cancelDelete
  case clearSelection
}

struct MacNavigationState: Equatable {
  static let detailVisibilityThreshold = 980.0

  var section: AppModel.Tab = .calendar
  var selectedRecordID: UUID?
  var editorRoute: MacEditorRoute?
  var deleteCandidateID: UUID?
  var searchFocusGeneration = 0
  private(set) var windowWidth = 1_080.0

  var usesThreeColumnLayout: Bool {
    windowWidth >= Self.detailVisibilityThreshold
  }

  var showsDetail: Bool {
    usesThreeColumnLayout
      && selectedRecordID != nil
      && (section == .calendar || section == .birthdays)
  }

  mutating func reduce(_ action: MacNavigationAction) {
    switch action {
    case .selectSection(let section):
      self.section = section
      deleteCandidateID = nil
    case .selectRecord(let id):
      selectedRecordID = id
    case .windowWidthChanged(let width):
      windowWidth = width
    case .command(.newBirthday):
      editorRoute = .new
    case .command(.focusSearch):
      section = .birthdays
      searchFocusGeneration += 1
    case .command(.openSettings):
      section = .settings
      deleteCandidateID = nil
    case .command(.deleteSelection):
      guard section == .calendar || section == .birthdays else { return }
      deleteCandidateID = selectedRecordID
    case .doubleClickRecord(let id):
      selectedRecordID = id
      editorRoute = .edit(id)
    case .dismissEditor:
      editorRoute = nil
    case .cancelDelete:
      deleteCandidateID = nil
    case .clearSelection:
      selectedRecordID = nil
      deleteCandidateID = nil
    }
  }
}

struct MacRootView: View {
  @Bindable var model: AppModel
  @State private var isShowingDeleteFailure = false

  var body: some View {
    GeometryReader { proxy in
      Group {
        if model.macNavigation.showsDetail {
          expandedNavigation
        } else {
          compactNavigation
        }
      }
      .onAppear {
        model.reduceMacNavigation(.windowWidthChanged(proxy.size.width))
        selectFirstRecordIfNeeded()
      }
      .onChange(of: proxy.size.width) { _, width in
        model.reduceMacNavigation(.windowWidthChanged(width))
      }
      .onChange(of: model.records) { _, _ in
        selectFirstRecordIfNeeded()
      }
    }
    .frame(minWidth: 820, minHeight: 600)
    .background(ModernAirTheme.desktopCanvas.ignoresSafeArea())
    .tint(ModernAirTheme.tide)
    .focusedSceneValue(
      \.macCommandHandler,
      MacCommandHandler { command in
        model.reduceMacNavigation(.command(command))
      }
    )
    .sheet(isPresented: editorPresentedBinding) {
      desktopEditor
    }
    .confirmationDialog(
      "确认删除",
      isPresented: deleteConfirmationPresented,
      titleVisibility: .visible,
      presenting: deleteCandidate
    ) { record in
      Button("确认删除", role: .destructive) {
        delete(record)
      }
      Button("取消", role: .cancel) {
        model.reduceMacNavigation(.cancelDelete)
      }
    } message: { record in
      Text(LocalOnlyStatusPresentation.deletionConfirmation(name: record.name))
    }
    .alert("删除失败", isPresented: $isShowingDeleteFailure) {
      Button("知道了", role: .cancel) {}
    } message: {
      Text("无法删除本地生日资料，记录仍然保留。请重试。")
    }
  }

  private var expandedNavigation: some View {
    NavigationSplitView {
      sidebar
    } content: {
      primaryContent
    } detail: {
      detailContent
    }
    .navigationSplitViewStyle(.balanced)
  }

  private var compactNavigation: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      primaryContent
    }
    .navigationSplitViewStyle(.balanced)
  }

  private var sidebar: some View {
    List(selection: sectionBinding) {
      Label("日历", systemImage: "calendar")
        .tag(AppModel.Tab.calendar)
      Label("全部生日", systemImage: "list.bullet")
        .tag(AppModel.Tab.birthdays)

      if model.isServerBindingAvailable || model.hasSyncConflicts {
        Label("冲突", systemImage: "arrow.triangle.2.circlepath")
          .badge(model.syncConflictCount)
          .tag(AppModel.Tab.conflicts)
      }

      Section {
        Label("设置", systemImage: "gearshape")
          .tag(AppModel.Tab.settings)
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("岁时")
    .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
    .accessibilityIdentifier("macSidebar")
  }

  @ViewBuilder
  private var primaryContent: some View {
    ZStack {
      accessibilityAnchor("主内容", identifier: "macPrimaryContent")

      NavigationStack {
        switch model.macNavigation.section {
        case .calendar:
          CalendarHomeView(
            model: model,
            showsAddToolbarButton: false,
            desktopSelectionID: model.macNavigation.selectedRecordID,
            selectRecord: select,
            editRecord: edit,
            requestDelete: requestDelete
          )
        case .birthdays:
          BirthdayListView(
            model: model,
            showsAddToolbarButton: false,
            desktopSelectionID: model.macNavigation.selectedRecordID,
            searchFocusGeneration: model.macNavigation.searchFocusGeneration,
            selectRecord: select,
            editRecord: edit,
            requestDelete: requestDelete
          )
        case .conflicts:
          ConflictListView(model: model)
        case .settings:
          SettingsView(model: model)
        }
      }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            model.reduceMacNavigation(.command(.newBirthday))
          } label: {
            Label("添加生日", systemImage: "plus")
          }
          .accessibilityIdentifier("macAddBirthdayToolbarButton")
        }
      }
    }
  }

  private var detailContent: some View {
    ZStack {
      accessibilityAnchor("详情栏", identifier: "macDetailColumn")

      Group {
        if let record = selectedRecord {
          BirthdayDetailView(
            record: record,
            edit: { edit(record) },
            requestDelete: { requestDelete(record) }
          )
        } else {
          ContentUnavailableView {
            Label("选择生日", systemImage: "gift")
          } description: {
            Text("从日历或全部生日中选择一条记录查看详情。")
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ModernAirTheme.detailCanvas.ignoresSafeArea())
    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
  }

  @ViewBuilder
  private var desktopEditor: some View {
    switch model.macNavigation.editorRoute {
    case .new:
      BirthdayEditorView(model: model)
    case .edit(let id):
      if let record = model.records.first(where: { $0.id == id }) {
        BirthdayEditorView(model: model, record: record)
      } else {
        ContentUnavailableView("生日不存在", systemImage: "gift")
      }
    case nil:
      EmptyView()
    }
  }

  private var selectedRecord: BirthdayRecord? {
    guard let id = model.macNavigation.selectedRecordID else { return nil }
    return model.records.first { $0.id == id }
  }

  private var deleteCandidate: BirthdayRecord? {
    guard let id = model.macNavigation.deleteCandidateID else { return nil }
    return model.records.first { $0.id == id }
  }

  private var sectionBinding: Binding<AppModel.Tab?> {
    Binding(
      get: { model.macNavigation.section },
      set: { section in
        guard let section else { return }
        model.reduceMacNavigation(.selectSection(section))
      }
    )
  }

  private var editorPresentedBinding: Binding<Bool> {
    Binding(
      get: { model.macNavigation.editorRoute != nil },
      set: { isPresented in
        if !isPresented {
          model.reduceMacNavigation(.dismissEditor)
        }
      }
    )
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { deleteCandidate != nil },
      set: { isPresented in
        if !isPresented {
          model.reduceMacNavigation(.cancelDelete)
        }
      }
    )
  }

  private func select(_ record: BirthdayRecord) {
    model.reduceMacNavigation(.selectRecord(record.id))
  }

  private func edit(_ record: BirthdayRecord) {
    model.reduceMacNavigation(.doubleClickRecord(record.id))
  }

  private func requestDelete(_ record: BirthdayRecord) {
    model.reduceMacNavigation(.selectRecord(record.id))
    model.reduceMacNavigation(.command(.deleteSelection))
  }

  private func delete(_ record: BirthdayRecord) {
    Task {
      guard await model.deleteBirthday(id: record.id) else {
        isShowingDeleteFailure = true
        return
      }
      model.reduceMacNavigation(.clearSelection)
    }
  }

  private func selectFirstRecordIfNeeded() {
    guard model.macNavigation.selectedRecordID == nil, let first = model.records.first else { return }
    model.reduceMacNavigation(.selectRecord(first.id))
  }

  private func accessibilityAnchor(_ label: String, identifier: String) -> some View {
    Text(label)
      .font(.system(size: 1))
      .foregroundStyle(.clear)
      .frame(width: 1, height: 1)
      .accessibilityLabel(label)
      .accessibilityIdentifier(identifier)
  }
}
