import Foundation

public enum SameDayReminderDecision: Equatable, Sendable {
  case saveNormally
  case chooseImmediateOrNextYear

  public static func evaluate(
    draft: BirthdayDraft,
    now: Date,
    timeZone: TimeZone,
    calculator: any LunarBirthdayCalculating = ChineseCalendarBirthdayCalculator()
  ) throws -> Self {
    try BirthdayValidator.validate(draft)
    guard draft.reminder.notifySameDay else { return .saveNormally }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let startOfToday = calendar.startOfDay(for: now)
    let occurrence = try calculator.nextOccurrence(
      of: draft.lunarBirthday,
      reminderMinutes: draft.reminder.timeMinutes,
      after: startOfToday.addingTimeInterval(-1),
      in: timeZone
    )

    guard calendar.isDate(occurrence, inSameDayAs: now), occurrence <= now else {
      return .saveNormally
    }
    return .chooseImmediateOrNextYear
  }
}

public enum PassedSameDayReminderResolution: Equatable, Sendable {
  case remindNow
  case nextYear
}
