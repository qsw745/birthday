import BirthdayCore
import SwiftUI

struct BirthdayListView: View {
  @Bindable var model: AppModel
  @Environment(\.timeZone) private var timeZone
  @State private var query = ""
  @State private var editingRecord: BirthdayRecord?
  @State private var deleteCandidate: BirthdayRecord?
  @State private var deleteRetryRecord: BirthdayRecord?
  @State private var isShowingDeleteError = false
  @State private var deletingRecordID: UUID?

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
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          model.isPresentingEditor = true
        } label: {
          Image(systemName: "plus")
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("添加生日")
      }
    }
    .sheet(item: $editingRecord) { record in
      BirthdayEditorView(model: model, record: record)
    }
    .confirmationDialog(
      "确认删除这个生日？",
      isPresented: deleteConfirmationPresented,
      titleVisibility: .visible,
      presenting: deleteCandidate
    ) { record in
      Button("删除“\(record.name)”", role: .destructive) {
        delete(record)
      }
      Button("取消", role: .cancel) {}
    } message: { _ in
      Text("记录会立即从本机隐藏，并在联网后同步删除。")
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
      Button {
        editingRecord = record
      } label: {
        BirthdayListRow(record: record, timeZone: timeZone)
      }
      .buttonStyle(.plain)
      .frame(minHeight: 58)
      .disabled(deletingRecordID == record.id)
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        Button(role: .destructive) {
          deleteCandidate = record
        } label: {
          Label("删除", systemImage: "trash")
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
      } catch {
        deleteRetryRecord = record
        isShowingDeleteError = true
      }
      deletingRecordID = nil
    }
  }
}

private struct BirthdayListRow: View {
  let record: BirthdayRecord
  let timeZone: TimeZone

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

      Label(syncText, systemImage: syncSymbol)
        .font(.caption.weight(.medium))
        .foregroundStyle(ModernAirTheme.secondaryInk)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
    .accessibilityHint("轻点编辑生日")
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
    switch record.syncState {
    case .synced: return "已同步"
    case .pending: return "待同步"
    case .conflict: return "需处理"
    case .pendingDelete: return "待删除"
    }
  }

  private var syncSymbol: String {
    switch record.syncState {
    case .synced: return "checkmark.circle"
    case .pending: return "arrow.triangle.2.circlepath"
    case .conflict: return "exclamationmark.triangle"
    case .pendingDelete: return "trash.slash"
    }
  }

  private var accessibilityText: String {
    "\(record.name)，\(nextDateText)，农历\(lunarText)，同步状态\(syncText)"
  }
}
