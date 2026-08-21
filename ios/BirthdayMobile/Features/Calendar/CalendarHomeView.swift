import SwiftData
import SwiftUI

import BirthdayCore

struct CalendarHomeView: View {
  @Bindable var model: AppModel
  @Environment(\.timeZone) private var timeZone

  private let weekSymbols = ["一", "二", "三", "四", "五", "六", "日"]
  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 44), spacing: 4),
    count: 7
  )

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "zh_CN")
    return calendar
  }

  private var projection: CalendarProjection {
    CalendarProjection.make(
      records: model.records,
      monthContaining: model.selectedMonth,
      timeZone: timeZone
    )
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        monthHeader

        if model.isLoading || model.loadState == .idle {
          loadingState
        } else if let errorMessage = model.errorMessage {
          errorState(message: errorMessage)
        } else {
          calendarSurface
          selectedDaySection
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 28)
    }
    .background(ModernAirTheme.mist.ignoresSafeArea())
    .navigationTitle("岁时")
    .navigationBarTitleDisplayMode(.inline)
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
    .onAppear(perform: selectDefaultDayIfNeeded)
    .onChange(of: model.selectedMonth) { _, _ in
      model.selectedDay = nil
      selectDefaultDayIfNeeded()
    }
    .onChange(of: model.records) { _, _ in
      selectDefaultDayIfNeeded()
    }
  }

  private var monthHeader: some View {
    HStack(spacing: 12) {
      monthNavigationButton(
        title: "上个月",
        systemImage: "chevron.left",
        monthOffset: -1
      )

      Spacer(minLength: 4)

      VStack(spacing: 2) {
        Text(monthTitle)
          .font(.system(.title2, design: .rounded, weight: .semibold))
          .foregroundStyle(ModernAirTheme.ink)
          .monospacedDigit()
        Text(monthSubtitle)
          .font(.caption)
          .foregroundStyle(ModernAirTheme.secondaryInk)
      }
      .accessibilityElement(children: .combine)

      Spacer(minLength: 4)

      monthNavigationButton(
        title: "下个月",
        systemImage: "chevron.right",
        monthOffset: 1
      )
    }
  }

  private func monthNavigationButton(
    title: String,
    systemImage: String,
    monthOffset: Int
  ) -> some View {
    Button {
      guard let nextMonth = calendar.date(
        byAdding: .month,
        value: monthOffset,
        to: projection.monthStart
      ) else { return }
      model.selectedMonth = nextMonth
    } label: {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .frame(width: 44, height: 44)
        .background(ModernAirTheme.glacier, in: Circle())
    }
    .foregroundStyle(ModernAirTheme.tide)
    .accessibilityLabel(title)
  }

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .tint(ModernAirTheme.tide)
      Text("正在读取本地生日资料")
        .font(.body)
        .foregroundStyle(ModernAirTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, minHeight: 280)
    .accessibilityElement(children: .combine)
  }

  private func errorState(message: String) -> some View {
    ContentUnavailableView {
      Label("无法显示生日", systemImage: "exclamationmark.triangle")
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
    .frame(maxWidth: .infinity, minHeight: 280)
  }

  private var calendarSurface: some View {
    VStack(spacing: 10) {
      LazyVGrid(columns: columns, spacing: 4) {
        ForEach(weekSymbols, id: \.self) { symbol in
          Text(symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(ModernAirTheme.secondaryInk)
            .frame(maxWidth: .infinity, minHeight: 28)
            .accessibilityLabel("星期\(symbol)")
        }
      }

      Divider()

      LazyVGrid(columns: columns, spacing: 4) {
        ForEach(Array(monthCells.enumerated()), id: \.offset) { _, day in
          if let day {
            dayButton(day)
          } else {
            Color.clear
              .frame(minHeight: 52)
              .accessibilityHidden(true)
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 14)
    .modernAirSurface()
  }

  private func dayButton(_ day: Int) -> some View {
    let records = projection.records(onDay: day)
    let hasBirthday = !records.isEmpty
    let isSelected = model.selectedDay == day

    return Button {
      model.selectedDay = day
    } label: {
      VStack(spacing: 1) {
        ZStack {
          if hasBirthday || isSelected {
            Circle()
              .trim(from: 0.08, to: hasBirthday ? 0.88 : 0.72)
              .stroke(
                ModernAirTheme.moon,
                style: StrokeStyle(
                  lineWidth: isSelected ? 3 : 2,
                  lineCap: .round
                )
              )
              .rotationEffect(.degrees(-72))
              .frame(width: 36, height: 36)
              .accessibilityHidden(true)
          }

          Text(day, format: .number)
            .font(
              .system(
                .body,
                design: .rounded,
                weight: isSelected ? .bold : .medium
              )
            )
            .monospacedDigit()
            .foregroundStyle(ModernAirTheme.ink)
        }

        if hasBirthday {
          Image(systemName: "gift.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(ModernAirTheme.tide)
            .accessibilityHidden(true)
        } else {
          Color.clear.frame(height: 8)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 52)
      .contentShape(Rectangle())
      .overlay {
        if isSelected {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(ModernAirTheme.ink.opacity(0.28), lineWidth: 1)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(dayAccessibilityLabel(day: day, records: records))
    .accessibilityValue(isSelected ? "已选中" : "未选中")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder
  private var selectedDaySection: some View {
    if let selectedDay = model.selectedDay {
      let records = projection.records(onDay: selectedDay)

      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          Text(selectedDayTitle(selectedDay))
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(ModernAirTheme.ink)
          Spacer()
          Text(records.isEmpty ? "无生日" : "\(records.count) 位")
            .font(.caption.weight(.medium))
            .foregroundStyle(ModernAirTheme.secondaryInk)
        }

        if records.isEmpty {
          VStack(spacing: 10) {
            Image(systemName: model.isEmpty ? "gift" : "calendar.badge.checkmark")
              .font(.title2)
              .foregroundStyle(ModernAirTheme.dusk)
            Text(model.isEmpty ? "还没有生日记录" : "这一天没有生日")
              .font(.headline)
              .foregroundStyle(ModernAirTheme.ink)
            Text(model.isEmpty ? "点右上角的加号，添加第一个农历生日。" : "选择带礼物标记的日期查看生日。")
              .font(.subheadline)
              .multilineTextAlignment(.center)
              .foregroundStyle(ModernAirTheme.secondaryInk)

            if model.isEmpty {
              Button("添加生日") {
                model.isPresentingEditor = true
              }
              .buttonStyle(.bordered)
              .tint(ModernAirTheme.tide)
              .frame(minHeight: 44)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 24)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
              birthdayRow(record)
              if index < records.count - 1 {
                Divider().padding(.leading, 48)
              }
            }
          }
        }
      }
      .padding(.horizontal, 4)
    }
  }

  private func birthdayRow(_ record: BirthdayRecord) -> some View {
    HStack(spacing: 14) {
      Image(systemName: "gift.fill")
        .font(.body.weight(.semibold))
        .foregroundStyle(ModernAirTheme.tide)
        .frame(width: 34, height: 34)
        .background(ModernAirTheme.glacier, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(record.name)
          .font(.headline)
          .foregroundStyle(ModernAirTheme.ink)
        Text("农历\(lunarText(record.lunarBirthday))")
          .font(.subheadline)
          .foregroundStyle(ModernAirTheme.secondaryInk)
      }

      Spacer(minLength: 8)
    }
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(record.name)，农历\(lunarText(record.lunarBirthday))生日")
  }

  private var monthCells: [Int?] {
    guard let dayRange = calendar.range(of: .day, in: .month, for: projection.monthStart)
    else { return [] }

    let weekday = calendar.component(.weekday, from: projection.monthStart)
    let leadingEmptyCount = (weekday + 5) % 7
    var cells = Array<Int?>(repeating: nil, count: leadingEmptyCount)
    cells.append(contentsOf: dayRange.map(Optional.some))

    let trailingEmptyCount = (7 - (cells.count % 7)) % 7
    cells.append(contentsOf: Array<Int?>(repeating: nil, count: trailingEmptyCount))
    return cells
  }

  private var monthTitle: String {
    let components = calendar.dateComponents([.year, .month], from: projection.monthStart)
    return "\(components.year ?? 0) 年 \(components.month ?? 0) 月"
  }

  private var monthSubtitle: String {
    let count = projection.recordsByDay.values.reduce(0) { $0 + $1.count }
    return count == 0 ? "本月暂无生日" : "本月 \(count) 位生日"
  }

  private func selectedDayTitle(_ day: Int) -> String {
    let month = calendar.component(.month, from: projection.monthStart)
    return "\(month) 月 \(day) 日"
  }

  private func dayAccessibilityLabel(day: Int, records: [BirthdayRecord]) -> String {
    guard let date = calendar.date(byAdding: .day, value: day - 1, to: projection.monthStart)
    else { return "公历 \(monthTitle) \(day) 日" }

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月d日"

    guard !records.isEmpty else {
      return "公历\(formatter.string(from: date))，无生日"
    }

    let birthdayDetails = records.map { record in
      "\(record.name)，农历\(lunarText(record.lunarBirthday))生日"
    }.joined(separator: "；")
    return "公历\(formatter.string(from: date))；\(birthdayDetails)"
  }

  private func lunarText(_ birthday: LunarBirthday) -> String {
    let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    let days = [
      "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
      "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
      "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
    let month = months.indices.contains(birthday.month - 1) ? months[birthday.month - 1] : "第\(birthday.month)"
    let day = days.indices.contains(birthday.day - 1) ? days[birthday.day - 1] : "第\(birthday.day)日"
    return "\(birthday.isLeapMonth ? "闰" : "")\(month)月\(day)"
  }

  private func selectDefaultDayIfNeeded() {
    guard model.selectedDay == nil else { return }

    if calendar.isDate(Date(), equalTo: projection.monthStart, toGranularity: .month) {
      model.selectedDay = calendar.component(.day, from: Date())
    } else {
      model.selectedDay = projection.daysWithBirthdays.first ?? 1
    }
  }
}

@MainActor
private struct CalendarHomePreviewHost: View {
  private let container: ModelContainer?
  @State private var model: AppModel?

  init() {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try? ModelContainer(
      for: BirthdayEntity.self,
      SyncOperationEntity.self,
      configurations: configuration
    )
    self.container = container

    let selectedMonth = ISO8601DateFormatter().date(from: "2026-08-12T04:00:00Z")!
    let records = [
      Self.previewRecord(
        name: "妈妈", lunarMonth: 7, lunarDay: 3,
        nextSolarDate: "2026-08-15T01:00:00Z"),
      Self.previewRecord(
        name: "外公", lunarMonth: 7, lunarDay: 3,
        nextSolarDate: "2026-08-15T02:00:00Z"),
      Self.previewRecord(
        name: "小满", lunarMonth: 7, lunarDay: 18,
        nextSolarDate: "2026-08-30T01:00:00Z"),
    ]

    if let container {
      _model = State(
        initialValue: AppModel(
          store: BirthdayStore(modelContainer: container),
          initialRecords: records,
          selectedMonth: selectedMonth,
          initiallyLoaded: true
        )
      )
    } else {
      _model = State(initialValue: nil)
    }
  }

  var body: some View {
    Group {
      if let container, let model {
        NavigationStack {
          CalendarHomeView(model: model)
        }
        .modelContainer(container)
      } else {
        Text("预览资料库初始化失败")
      }
    }
  }

  private static func previewRecord(
    name: String,
    lunarMonth: Int,
    lunarDay: Int,
    nextSolarDate: String
  ) -> BirthdayRecord {
    let now = Date(timeIntervalSince1970: 1_770_000_000)
    return BirthdayRecord(
      id: UUID(),
      name: name,
      lunarBirthday: LunarBirthday(month: lunarMonth, day: lunarDay, isLeapMonth: false),
      reminder: .defaults,
      nextSolarDate: ISO8601DateFormatter().date(from: nextSolarDate),
      version: 0,
      createdAt: now,
      updatedAt: now,
      deletedAt: nil,
      syncState: .pending
    )
  }
}

#Preview("八月生日月历") {
  CalendarHomePreviewHost()
}
