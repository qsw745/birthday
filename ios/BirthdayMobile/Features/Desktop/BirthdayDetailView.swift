import BirthdayCore
import SwiftUI

struct BirthdayDetailView: View {
  let record: BirthdayRecord
  let edit: () -> Void
  let requestDelete: () -> Void
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 14) {
          Image(systemName: "gift.fill")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(ModernAirTheme.tide)
            .frame(width: 64, height: 64)
            .background(ModernAirTheme.glacier, in: Circle())

          Text("生日详情")
            .font(.caption.weight(.semibold))
            .foregroundStyle(ModernAirTheme.secondaryInk)
            .textCase(.uppercase)

          Text(record.name)
            .font(.system(.largeTitle, design: .rounded, weight: .bold))
            .foregroundStyle(ModernAirTheme.ink)
        }

        VStack(spacing: 0) {
          detailRow("农历生日", value: lunarText)
          Divider()
          detailRow("下次公历", value: nextDateText)
          Divider()
          detailRow("提醒时间", value: reminderTimeText)
          Divider()
          detailRow("本地通知", value: notificationText)
        }
        .padding(.horizontal, 18)
        .modernAirSurface(radius: 20)

        HStack(spacing: 12) {
          Button("编辑", action: edit)
            .buttonStyle(.borderedProminent)
            .tint(ModernAirTheme.tide)
            .keyboardShortcut(.return, modifiers: [])

          Button("删除", role: .destructive, action: requestDelete)
            .buttonStyle(.bordered)
        }
      }
      .frame(maxWidth: 420, alignment: .leading)
      .padding(28)
    }
    .accessibilityIdentifier("birthdayDetail-\(record.id.uuidString)")
  }

  private func detailRow(_ label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label)
        .foregroundStyle(ModernAirTheme.secondaryInk)
      Spacer(minLength: 12)
      Text(value)
        .multilineTextAlignment(.trailing)
        .foregroundStyle(ModernAirTheme.ink)
    }
    .font(.body)
    .padding(.vertical, 15)
  }

  private var lunarText: String {
    let birthday = record.lunarBirthday
    return "\(birthday.isLeapMonth ? "闰" : "")\(birthday.month) 月 \(birthday.day) 日"
  }

  private var nextDateText: String {
    guard let date = record.nextSolarDate else { return "待计算" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy年M月d日"
    return formatter.string(from: date)
  }

  private var reminderTimeText: String {
    String(
      format: "%02d:%02d",
      record.reminder.timeMinutes / 60,
      record.reminder.timeMinutes % 60
    )
  }

  private var notificationText: String {
    switch (record.reminder.notifyDayBefore, record.reminder.notifySameDay) {
    case (true, true): "提前一天、生日当天"
    case (true, false): "提前一天"
    case (false, true): "生日当天"
    case (false, false): "未开启"
    }
  }
}
