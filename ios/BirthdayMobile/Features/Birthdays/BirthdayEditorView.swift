import BirthdayCore
import SwiftUI

struct BirthdayEditorView: View {
  private enum FocusField: Hashable {
    case name
    case emailAddress
    case emailMessage
  }

  private enum ActiveOperation: Equatable {
    case save
    case delete
  }

  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.timeZone) private var timeZone
  @FocusState private var focusedField: FocusField?
  @State private var editorModel: BirthdayEditorModel
  @State private var isShowingDeleteConfirmation = false
  @State private var isShowingDeleteFailure = false
  @State private var isShowingPassedReminderChoice = false
  @State private var isShowingImmediateReminderResult = false
  @State private var immediateReminderMessage = ""
  @State private var activeOperation: ActiveOperation?

  private let record: BirthdayRecord?

  init(model: AppModel, record: BirthdayRecord? = nil) {
    self.model = model
    self.record = record
    _editorModel = State(
      initialValue: BirthdayEditorModel(
        store: model.store,
        record: record,
        oneShotNotificationScheduler: model.oneShotNotificationScheduler
      )
    )
  }

  private var isInteractionLocked: Bool {
    activeOperation != nil || editorModel.isBusy
  }

  var body: some View {
    @Bindable var editor = editorModel

    NavigationStack {
      ScrollViewReader { proxy in
        Form {
          Section {
            TextField("姓名", text: $editor.draft.name)
              .focused($focusedField, equals: .name)
              .textContentType(.name)
              .submitLabel(.done)
              .accessibilityIdentifier("birthdayNameField")

            LunarDatePicker(value: $editor.draft.lunarBirthday)

            Toggle("闰月", isOn: $editor.draft.lunarBirthday.isLeapMonth)
          } header: {
            Text("基本信息")
          } footer: {
            validationMessage(in: .basicInformation)
          }
          .id(BirthdayEditorModel.SectionLocation.basicInformation)

          Section {
            ReminderTimePicker(minutes: $editor.draft.reminder.timeMinutes)
            Toggle("提前一天", isOn: $editor.draft.reminder.notifyDayBefore)
            Toggle("生日当天", isOn: $editor.draft.reminder.notifySameDay)
            Toggle("邮件备份提醒", isOn: $editor.draft.reminder.emailEnabled)
          } header: {
            Text("提醒")
          } footer: {
            validationMessage(in: .reminder)
          }
          .id(BirthdayEditorModel.SectionLocation.reminder)

          if editor.draft.reminder.emailEnabled {
            Section {
              TextField("收件邮箱", text: $editor.draft.reminder.emailAddress)
                .focused($focusedField, equals: .emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .submitLabel(.next)

              TextField(
                "提醒内容",
                text: $editor.draft.reminder.emailMessage,
                axis: .vertical
              )
              .focused($focusedField, equals: .emailMessage)
              .lineLimit(3...6)
            } header: {
              Text("邮件")
            } footer: {
              VStack(alignment: .leading, spacing: 6) {
                Text("邮件提醒需后续联网绑定服务；本地通知不受影响。")
                validationMessage(in: .email)
              }
            }
            .id(BirthdayEditorModel.SectionLocation.email)
          }

          if editor.errorField?.section == .general,
            let errorMessage = editor.errorMessage
          {
            Section {
              Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityLabel("操作错误：\(errorMessage)")
            }
            .id(BirthdayEditorModel.SectionLocation.general)
          }

          if record != nil {
            Section {
              Button(role: .destructive) {
                isShowingDeleteConfirmation = true
              } label: {
                Label("删除生日", systemImage: "trash")
                  .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              }
              .disabled(isInteractionLocked)
              .accessibilityIdentifier("deleteBirthdayButton")
            } footer: {
              Text("删除后只会从本机立即隐藏。服务器同步尚未启用。")
            }
          }
        }
        .disabled(isInteractionLocked)
        .scrollContentBackground(.hidden)
        .background(ModernAirTheme.mist)
        .onChange(of: editor.errorField) { _, errorField in
          guard let errorField else { return }
          withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(errorField.section, anchor: .center)
          }
          switch errorField {
          case .name:
            focusedField = .name
          case .emailAddress:
            focusedField = .emailAddress
          case .emailMessage:
            focusedField = .emailMessage
          default:
            focusedField = nil
          }
        }
      }
      .navigationTitle(record == nil ? "添加生日" : "编辑生日")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") {
            dismiss()
          }
          .frame(minHeight: 44)
          .disabled(isInteractionLocked)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button {
            save()
          } label: {
            if activeOperation == .save {
              ProgressView()
                .accessibilityLabel("正在保存")
            } else {
              Text("保存")
                .fontWeight(.semibold)
            }
          }
          .frame(minWidth: 44, minHeight: 44)
          .disabled(isInteractionLocked)
          .accessibilityIdentifier("saveBirthdayButton")
        }
      }
      .confirmationDialog(
        "确认删除",
        isPresented: $isShowingDeleteConfirmation,
        titleVisibility: .visible
      ) {
        Button("确认删除", role: .destructive) {
          deleteRecord()
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text(deleteConfirmationMessage)
      }
      .alert("删除失败", isPresented: $isShowingDeleteFailure) {
        Button("重试") {
          deleteRecord()
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text(editor.errorMessage ?? "本地记录仍然保留，请重试")
      }
      .confirmationDialog(
        "今天的提醒时间已过",
        isPresented: $isShowingPassedReminderChoice,
        titleVisibility: .visible
      ) {
        Button("现在提醒一次") {
          save(resolution: .remindNow)
        }
        Button("从明年开始") {
          save(resolution: .nextYear)
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("请选择是否立即提交一次本地通知请求；常规生日提醒将从下一次生日开始。")
      }
      .alert("生日已保存", isPresented: $isShowingImmediateReminderResult) {
        Button("知道了") { dismiss() }
      } message: {
        Text(immediateReminderMessage)
      }
    }
    .tint(ModernAirTheme.tide)
    .interactiveDismissDisabled(isInteractionLocked)
  }

  @ViewBuilder
  private func validationMessage(in section: BirthdayEditorModel.SectionLocation) -> some View {
    if editorModel.errorField?.section == section,
      let errorMessage = editorModel.errorMessage
    {
      Label(errorMessage, systemImage: "exclamationmark.circle")
        .foregroundStyle(.red)
        .accessibilityLabel("输入错误：\(errorMessage)")
    }
  }

  private func save(resolution: PassedSameDayReminderResolution? = nil) {
    guard !isInteractionLocked else { return }
    activeOperation = .save

    Task {
      let outcome = await editorModel.save(resolution: resolution, timeZone: timeZone)
      switch outcome {
      case .requiresPassedReminderChoice:
        activeOperation = nil
        isShowingPassedReminderChoice = true
      case .failed:
        activeOperation = nil
      case .saved(let immediateReminder):
        await model.reload()
        Task { await model.requestSync(.localMutation) }
        guard let immediateReminder else {
          dismiss()
          return
        }
        switch immediateReminder {
        case .scheduled:
          dismiss()
        case .notAuthorized:
          activeOperation = nil
          immediateReminderMessage = "立即提醒未安排：当前没有通知权限。常规提醒仍从明年开始。"
          isShowingImmediateReminderResult = true
        case .failed:
          activeOperation = nil
          immediateReminderMessage = "立即提醒请求未能安排。生日已保存在本机，常规提醒仍从明年开始。"
          isShowingImmediateReminderResult = true
        }
      }
    }
  }

  private func deleteRecord() {
    guard !isInteractionLocked else { return }
    activeOperation = .delete

    Task {
      guard await editorModel.delete() else {
        activeOperation = nil
        isShowingDeleteFailure = true
        return
      }
      await model.reload()
      Task { await model.requestSync(.localMutation) }
      dismiss()
    }
  }

  private var deleteConfirmationMessage: String {
    if let record {
      return LocalOnlyStatusPresentation.deletionConfirmation(name: record.name)
    }
    return "删除后只会从本机隐藏。服务器同步尚未启用。"
  }
}

struct LunarDatePicker: View {
  @Binding var value: LunarBirthday

  private let monthNames = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
  private let dayNames = [
    "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
  ]

  var body: some View {
    HStack(spacing: 12) {
      Picker("农历月份", selection: $value.month) {
        ForEach(1...12, id: \.self) { month in
          Text(monthNames[month - 1]).tag(month)
        }
      }

      Picker("农历日期", selection: $value.day) {
        ForEach(1...30, id: \.self) { day in
          Text(dayNames[day - 1]).tag(day)
        }
      }
    }
    .pickerStyle(.wheel)
    .frame(height: 140)
    .accessibilityElement(children: .contain)
  }
}

struct ReminderTimePicker: View {
  @Binding var minutes: Int
  @Environment(\.timeZone) private var timeZone

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "zh_CN")
    calendar.timeZone = timeZone
    return calendar
  }

  private var date: Binding<Date> {
    Binding(
      get: {
        calendar.date(
          from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: 2001,
            month: 1,
            day: 1,
            hour: minutes / 60,
            minute: minutes % 60
          )
        ) ?? Date(timeIntervalSinceReferenceDate: 0)
      },
      set: { newValue in
        let components = calendar.dateComponents([.hour, .minute], from: newValue)
        minutes = (components.hour ?? 9) * 60 + (components.minute ?? 0)
      }
    )
  }

  var body: some View {
    DatePicker("提醒时间", selection: date, displayedComponents: .hourAndMinute)
      .environment(\.calendar, calendar)
      .environment(\.locale, Locale(identifier: "zh_CN"))
      .environment(\.timeZone, timeZone)
  }
}
