import Foundation

public enum BirthdayValidationError: Error, Equatable {
    case emptyName, nameTooLong, invalidLunarMonth, invalidLunarDay, invalidReminderTime, noNotificationSelected, invalidEmail, emailMessageTooLong
}

public enum BirthdayValidator {
    public static func validate(_ draft: BirthdayDraft) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BirthdayValidationError.emptyName }
        guard name.count <= 64, name.unicodeScalars.count <= 64 else {
            throw BirthdayValidationError.nameTooLong
        }
        guard (1...12).contains(draft.lunarBirthday.month) else { throw BirthdayValidationError.invalidLunarMonth }
        guard (1...30).contains(draft.lunarBirthday.day) else { throw BirthdayValidationError.invalidLunarDay }
        guard (0..<1_440).contains(draft.reminder.timeMinutes) else { throw BirthdayValidationError.invalidReminderTime }
        guard draft.reminder.notifyDayBefore || draft.reminder.notifySameDay else { throw BirthdayValidationError.noNotificationSelected }

        if draft.reminder.emailEnabled {
            let email = draft.reminder.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let emailParts = email.split(separator: "@", omittingEmptySubsequences: false)
            guard email.count <= 128,
                  email.unicodeScalars.count <= 128,
                  emailParts.count == 2,
                  !emailParts[0].isEmpty,
                  !emailParts[1].isEmpty
            else { throw BirthdayValidationError.invalidEmail }
            guard (name + draft.reminder.emailMessage).utf8.count <= 32_768 else {
                throw BirthdayValidationError.emailMessageTooLong
            }
        }
    }
}
