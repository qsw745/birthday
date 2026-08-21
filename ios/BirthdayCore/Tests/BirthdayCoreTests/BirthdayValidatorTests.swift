import Foundation
import Testing
@testable import BirthdayCore

@Test func rejectsEmptyName() {
    let draft = BirthdayDraft(
        name: "  ",
        lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
    )
    #expect(throws: BirthdayValidationError.emptyName) {
        try BirthdayValidator.validate(draft)
    }
}

@Test func rejectsInvalidLunarDay() {
    let draft = BirthdayDraft(
        name: "妈妈",
        lunarBirthday: .init(month: 8, day: 31, isLeapMonth: false),
        reminder: .defaults
    )
    #expect(throws: BirthdayValidationError.invalidLunarDay) {
        try BirthdayValidator.validate(draft)
    }
}

@Test func requiresEmailWhenEmailReminderIsEnabled() {
    let reminder = ReminderConfig(
        timeMinutes: 540,
        notifyDayBefore: true,
        notifySameDay: true,
        emailEnabled: true,
        emailAddress: "",
        emailMessage: "生日快乐"
    )
    let draft = BirthdayDraft(name: "妈妈", lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false), reminder: reminder)
    #expect(throws: BirthdayValidationError.invalidEmail) {
        try BirthdayValidator.validate(draft)
    }
}
