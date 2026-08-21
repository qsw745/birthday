import Foundation

public enum BirthdayValidationError: Error, Equatable {
    case emptyName, nameTooLong, invalidLunarMonth, invalidLunarDay, invalidReminderTime, noNotificationSelected, invalidEmail
}

public enum BirthdayValidator {
    public static func validate(_ draft: BirthdayDraft) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BirthdayValidationError.emptyName }
        guard name.count <= 64 else { throw BirthdayValidationError.nameTooLong }
        guard (1...12).contains(draft.lunarBirthday.month) else { throw BirthdayValidationError.invalidLunarMonth }
        guard (1...30).contains(draft.lunarBirthday.day) else { throw BirthdayValidationError.invalidLunarDay }
        guard (0..<1_440).contains(draft.reminder.timeMinutes) else { throw BirthdayValidationError.invalidReminderTime }
        guard draft.reminder.notifyDayBefore || draft.reminder.notifySameDay else { throw BirthdayValidationError.noNotificationSelected }

        if draft.reminder.emailEnabled {
            let email = draft.reminder.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard email.contains("@"), email.count <= 128 else { throw BirthdayValidationError.invalidEmail }
        }
    }
}
