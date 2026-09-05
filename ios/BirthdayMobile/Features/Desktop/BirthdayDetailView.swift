import BirthdayCore
import SwiftUI

struct BirthdayDetailView: View {
  let record: BirthdayRecord
  let edit: () -> Void
  let requestDelete: () -> Void
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 18) {
          Text(String(record.name.prefix(1)))
            .font(.system(size: 30, weight: .medium, design: .rounded))
            .foregroundStyle(ModernAirTheme.tide)
            .frame(width: 72, height: 72)
            .background(ModernAirTheme.tide.opacity(0.08), in: Circle())
            .overlay {
              Circle()
                .trim(from: 0.04, to: 0.3)
                .stroke(ModernAirTheme.moon, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-85))
                .padding(-3)
            }
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 7) {
            Text("生日详情")
              .font(.caption.weight(.medium))
              .foregroundStyle(ModernAirTheme.secondaryInk)
            Text(record.name)
              .font(.system(.largeTitle, design: .rounded, weight: .bold))
              .foregroundStyle(ModernAirTheme.ink)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        VStack(alignment: .leading, spacing: 12) {
          Label("下次生日", systemImage: "calendar")
            .font(.caption.weight(.semibold))
            .foregroundStyle(ModernAirTheme.tide)

          Text(nextDateText)
            .font(.system(.title2, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(ModernAirTheme.ink)
            .fixedSize(horizontal: false, vertical: true)

          Text("农历 \(lunarText)")
            .font(.subheadline)
            .foregroundStyle(ModernAirTheme.secondaryInk)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernAirTheme.tide.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))

        VStack(alignment: .leading, spacing: 16) {
          Text("提醒安排")
            .font(.caption.weight(.semibold))
            .foregroundStyle(ModernAirTheme.secondaryInk)
          detailRow("提醒时间", value: reminderTimeText, symbol: "clock")
          Divider().overlay(ModernAirTheme.outline.opacity(0.5))
          detailRow("本地通知", value: notificationText, symbol: "bell")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modernAirSurface(radius: 20)

        VStack(spacing: 10) {
          Button(action: edit) {
            Label("编辑", systemImage: "pencil")
              .frame(maxWidth: .infinity, minHeight: 30)
          }
          .buttonStyle(.borderedProminent)
          .tint(ModernAirTheme.tide)
          .keyboardShortcut(.return, modifiers: [])

          Button(role: .destructive, action: requestDelete) {
            Label("删除", systemImage: "trash")
              .frame(maxWidth: .infinity, minHeight: 32)
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
        }
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: 12))
      }
      .frame(maxWidth: 420, alignment: .leading)
      .padding(28)
    }
    .accessibilityIdentifier("birthdayDetail-\(record.id.uuidString)")
  }

  private func detailRow(_ label: String, value: String, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(ModernAirTheme.tide)
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 5) {
        Text(label)
          .font(.caption)
          .foregroundStyle(ModernAirTheme.secondaryInk)
        Text(value)
          .font(.body.weight(.medium))
          .foregroundStyle(ModernAirTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var lunarText: String {
    LunarBirthdayText.string(for: record.lunarBirthday)
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
