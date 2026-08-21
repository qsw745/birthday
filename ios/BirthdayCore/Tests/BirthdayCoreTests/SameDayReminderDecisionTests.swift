import Foundation
import Testing

@testable import BirthdayCore

private let sameDayTimeZone = TimeZone(identifier: "Asia/Shanghai")!

private func sameDayDraft(
  reminderMinutes: Int = 540,
  notifySameDay: Bool = true
) -> BirthdayDraft {
  var reminder = ReminderConfig.defaults
  reminder.timeMinutes = reminderMinutes
  reminder.notifySameDay = notifySameDay
  return BirthdayDraft(
    name: "妈妈",
    lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
    reminder: reminder
  )
}
@Test func asksForExplicitChoiceWhenTodaysReminderTimeAlreadyPassed() throws {
  let now = ISO8601DateFormatter().date(from: "2026-09-25T02:00:00Z")!

  let decision = try SameDayReminderDecision.evaluate(
    draft: sameDayDraft(),
    now: now,
    timeZone: sameDayTimeZone
  )

  #expect(decision == .chooseImmediateOrNextYear)
}

@Test func doesNotAskBeforeTodaysReminderTimeOrWhenSameDayReminderIsDisabled() throws {
  let beforeReminder = ISO8601DateFormatter().date(from: "2026-09-25T00:00:00Z")!
  let afterReminder = ISO8601DateFormatter().date(from: "2026-09-25T02:00:00Z")!

  #expect(
    try SameDayReminderDecision.evaluate(
      draft: sameDayDraft(),
      now: beforeReminder,
      timeZone: sameDayTimeZone
    ) == .saveNormally
  )
  #expect(
    try SameDayReminderDecision.evaluate(
      draft: sameDayDraft(notifySameDay: false),
      now: afterReminder,
      timeZone: sameDayTimeZone
    ) == .saveNormally
  )
}
