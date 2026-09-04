import BirthdayCore
import SwiftUI
import UIKit

struct BirthdayListView: View {
  @Bindable var model: AppModel
  @Environment(\.timeZone) private var timeZone
  @State private var query = ""
  @State private var editingRecord: BirthdayRecord?
  @State private var deleteCandidate: BirthdayRecord?
  @State private var deleteRetryRecord: BirthdayRecord?
  @State private var isShowingDeleteError = false
  @State private var deletingRecordID: UUID?
  @State private var hoveredRecordID: UUID?
  private let showsAddToolbarButton: Bool
  private let desktopSelectionID: UUID?
  private let searchFocusGeneration: Int
  private let selectRecord: ((BirthdayRecord) -> Void)?
  private let editRecord: ((BirthdayRecord) -> Void)?
  private let requestDelete: ((BirthdayRecord) -> Void)?

  init(
    model: AppModel,
    showsAddToolbarButton: Bool = true,
    desktopSelectionID: UUID? = nil,
    searchFocusGeneration: Int = 0,
    selectRecord: ((BirthdayRecord) -> Void)? = nil,
    editRecord: ((BirthdayRecord) -> Void)? = nil,
    requestDelete: ((BirthdayRecord) -> Void)? = nil
  ) {
    self.model = model
    self.showsAddToolbarButton = showsAddToolbarButton
    self.desktopSelectionID = desktopSelectionID
    self.searchFocusGeneration = searchFocusGeneration
    self.selectRecord = selectRecord
    self.editRecord = editRecord
    self.requestDelete = requestDelete
  }

  private var visibleRecords: [BirthdayRecord] {
    BirthdaySearch.sortedByNextSolarDate(
      BirthdaySearch.filter(
        model.records.filter { $0.deletedAt == nil },
        query: query
      )
    )
  }

  private var hasSearchQuery: Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var isDeletingRecord: Bool {
    deletingRecordID != nil
  }

  var body: some View {
    Group {
      if model.isLoading || model.loadState == .idle {
        loadingState
      } else if let errorMessage = model.errorMessage {
        errorState(message: errorMessage)
      } else if visibleRecords.isEmpty {
        if hasSearchQuery {
          searchEmptyState
        } else {
          recordsEmptyState
        }
      } else {
        birthdayList
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ModernAirTheme.mist.ignoresSafeArea())
    .navigationTitle("全部")
    .searchable(text: $query, prompt: "搜索姓名")
    .background {
      SearchFieldAccessibilityIdentifier(
        identifier: "birthdaySearchField",
        placeholder: "搜索姓名",
        focusGeneration: searchFocusGeneration
      )
      .frame(width: 0, height: 0)
    }
    .toolbar {
      if showsAddToolbarButton {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            model.isPresentingEditor = true
          } label: {
            Image(systemName: "plus")
              .frame(width: 44, height: 44)
          }
          .accessibilityLabel("添加生日")
          .accessibilityIdentifier("addBirthdayButton")
          .disabled(isDeletingRecord)
        }
      }
    }
    .sheet(item: $editingRecord) { record in
      BirthdayEditorView(model: model, record: record)
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
      Button("取消", role: .cancel) {}
    } message: { record in
      Text(LocalOnlyStatusPresentation.deletionConfirmation(name: record.name))
    }
    .alert("删除失败", isPresented: $isShowingDeleteError) {
      Button("重试") {
        if let deleteRetryRecord {
          delete(deleteRetryRecord)
        }
      }
      Button("取消", role: .cancel) {
        deleteRetryRecord = nil
      }
    } message: {
      Text("无法删除本地生日资料，记录仍然保留。请重试。")
    }
  }

  private var birthdayList: some View {
    List(visibleRecords) { record in
      if record.syncState == .conflict {
        VStack(alignment: .leading, spacing: 8) {
          BirthdayListRow(record: record, timeZone: timeZone)

          Button("前往处理同步冲突") {
            model.selectedTab = .conflicts
          }
          .buttonStyle(.bordered)
          .tint(ModernAirTheme.tide)
          .accessibilityIdentifier("openConflictButton-\(record.id.uuidString)")
        }
        .frame(minHeight: 58)
      } else {
        if let selectRecord {
          BirthdayListRow(record: record, timeZone: timeZone, isDesktop: true)
            .padding(.horizontal, 8)
            .frame(minHeight: 58)
            .background(
              desktopRowBackground(for: record.id),
              in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
              editRecord?(record)
            }
            .simultaneousGesture(
              TapGesture().onEnded {
                selectRecord(record)
              }
            )
            .contextMenu {
              Button("编辑生日") {
                editRecord?(record)
              }
              Button("从本机删除", role: .destructive) {
                requestDelete?(record)
              }
            }
            .onHover { isHovering in
              hoveredRecordID = isHovering ? record.id : nil
            }
            .disabled(isDeletingRecord)
            .accessibilityIdentifier("desktopBirthdayRow-\(record.id.uuidString)")
        } else {
          Button {
            editingRecord = record
          } label: {
            BirthdayListRow(record: record, timeZone: timeZone)
          }
          .buttonStyle(.plain)
          .frame(minHeight: 58)
          .disabled(isDeletingRecord)
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
              deleteCandidate = record
            } label: {
              Label("删除", systemImage: "trash")
            }
            .disabled(isDeletingRecord)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
  }

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .tint(ModernAirTheme.tide)
      Text("正在读取本地生日资料")
        .font(.body)
        .foregroundStyle(ModernAirTheme.secondaryInk)
    }
    .accessibilityElement(children: .combine)
  }

  private func desktopRowBackground(for id: UUID) -> Color {
    if desktopSelectionID == id { return ModernAirTheme.glacier }
    if hoveredRecordID == id { return ModernAirTheme.tide.opacity(0.08) }
    return .clear
  }

  private func errorState(message: String) -> some View {
    ContentUnavailableView {
      Label("无法显示生日", systemImage: "externaldrive.badge.exclamationmark")
    } description: {
      Text(message)
    } actions: {
      Button("重新读取") {
        Task { await model.reload() }
      }
      .buttonStyle(.borderedProminent)
      .tint(ModernAirTheme.tide)
      .frame(minHeight: 44)
    }
  }

  private var recordsEmptyState: some View {
    ContentUnavailableView {
      Label("还没有生日记录", systemImage: "gift")
    } description: {
      Text("添加第一个农历生日，开始使用本地提醒。")
    } actions: {
      Button("添加生日") {
        model.isPresentingEditor = true
      }
      .accessibilityIdentifier("birthdayListEmptyAddButton")
      .buttonStyle(.borderedProminent)
      .tint(ModernAirTheme.tide)
      .frame(minHeight: 44)
    }
  }

  private var searchEmptyState: some View {
    ContentUnavailableView {
      Label("没有搜索结果", systemImage: "magnifyingglass")
    } description: {
      Text("没有找到与“\(query.trimmingCharacters(in: .whitespacesAndNewlines))”匹配的姓名。")
    } actions: {
      Button("清除搜索") {
        query = ""
      }
      .buttonStyle(.bordered)
      .tint(ModernAirTheme.tide)
      .frame(minHeight: 44)
    }
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { deleteCandidate != nil },
      set: { isPresented in
        if !isPresented {
          deleteCandidate = nil
        }
      }
    )
  }

  private func delete(_ record: BirthdayRecord) {
    guard deletingRecordID == nil else { return }
    deletingRecordID = record.id
    deleteCandidate = nil

    Task {
      do {
        try await model.store.softDelete(id: record.id, now: .now)
        deleteRetryRecord = nil
        await model.reload()
        Task { await model.requestSync(.localMutation) }
      } catch {
        deleteRetryRecord = record
        isShowingDeleteError = true
      }
      deletingRecordID = nil
    }
  }
}

private struct SearchFieldAccessibilityIdentifier: UIViewRepresentable {
  let identifier: String
  let placeholder: String
  let focusGeneration: Int

  func makeUIView(context: Context) -> InstallerView {
    InstallerView(
      identifier: identifier,
      placeholder: placeholder,
      focusGeneration: focusGeneration
    )
  }

  func updateUIView(_ uiView: InstallerView, context: Context) {
    uiView.update(focusGeneration: focusGeneration)
  }

  final class InstallerView: UIView {
    private let identifier: String
    private let placeholder: String
    private var focusGeneration: Int
    private var appliedFocusGeneration = 0

    init(identifier: String, placeholder: String, focusGeneration: Int) {
      self.identifier = identifier
      self.placeholder = placeholder
      self.focusGeneration = focusGeneration
      super.init(frame: .zero)
      isAccessibilityElement = false
      isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      installIdentifier()
      DispatchQueue.main.async { [weak self] in
        self?.installIdentifier()
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      installIdentifier()
    }

    func installIdentifier() {
      guard
        let searchField = window?.firstDescendant(
          of: UISearchTextField.self,
          where: {
            $0.placeholder == self.placeholder
          })
      else { return }
      searchField.accessibilityIdentifier = identifier
      if focusGeneration > appliedFocusGeneration {
        appliedFocusGeneration = focusGeneration
        searchField.becomeFirstResponder()
      }
    }

    func update(focusGeneration: Int) {
      self.focusGeneration = focusGeneration
      installIdentifier()
    }
  }
}

extension UIView {
  fileprivate func firstDescendant<View: UIView>(
    of type: View.Type,
    where predicate: (View) -> Bool
  ) -> View? {
    for subview in subviews {
      if let match = subview as? View, predicate(match) {
        return match
      }
      if let nested = subview.firstDescendant(of: type, where: predicate) {
        return nested
      }
    }
    return nil
  }
}

private struct BirthdayListRow: View {
  let record: BirthdayRecord
  let timeZone: TimeZone
  var isDesktop = false

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: "gift.fill")
        .font(.body.weight(.semibold))
        .foregroundStyle(ModernAirTheme.tide)
        .frame(width: 36, height: 36)
        .background(ModernAirTheme.glacier, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(record.name)
          .font(.headline)
          .foregroundStyle(ModernAirTheme.ink)

        Text(nextDateText)
          .font(.subheadline)
          .foregroundStyle(ModernAirTheme.dusk)
          .monospacedDigit()

        Text("农历\(lunarText)")
          .font(.caption)
          .foregroundStyle(ModernAirTheme.secondaryInk)
      }

      Spacer(minLength: 8)

      if isDesktop {
        Image(systemName: syncSymbol)
          .font(.caption.weight(.semibold))
          .foregroundStyle(ModernAirTheme.secondaryInk)
          .help(syncText)
      } else {
        Label(syncText, systemImage: syncSymbol)
          .font(.caption.weight(.medium))
          .foregroundStyle(ModernAirTheme.secondaryInk)
          .labelStyle(.titleAndIcon)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
    .accessibilityHint(
      record.syncState == .conflict
        ? "请使用下方按钮处理同步冲突"
        : isDesktop ? "单击选择，双击编辑" : "轻点编辑生日"
    )
  }

  private var nextDateText: String {
    guard let nextSolarDate = record.nextSolarDate else {
      return "下次公历日期待计算"
    }

    let formatter = DateFormatter()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月d日"
    return "下次公历 \(formatter.string(from: nextSolarDate))"
  }

  private var lunarText: String {
    let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    let days = [
      "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
      "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
      "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
    let month =
      months.indices.contains(record.lunarBirthday.month - 1)
      ? months[record.lunarBirthday.month - 1] : "第\(record.lunarBirthday.month)"
    let day =
      days.indices.contains(record.lunarBirthday.day - 1)
      ? days[record.lunarBirthday.day - 1] : "第\(record.lunarBirthday.day)日"
    return "\(record.lunarBirthday.isLeapMonth ? "闰" : "")\(month)月\(day)"
  }

  private var syncText: String {
    if record.syncState == .conflict { return "待处理冲突" }
    return LocalOnlyStatusPresentation.make(for: record.syncState).title
  }

  private var syncSymbol: String {
    if record.syncState == .conflict { return "exclamationmark.triangle" }
    return isDesktop ? "internaldrive" : "iphone"
  }

  private var accessibilityText: String {
    if record.syncState == .conflict {
      return "\(record.name)，\(nextDateText)，农历\(lunarText)，待处理同步冲突"
    }
    let status = LocalOnlyStatusPresentation.make(for: record.syncState)
    return "\(record.name)，\(nextDateText)，农历\(lunarText)，\(status.title)，\(status.detail)"
  }
}
