import Foundation
import Testing
import BirthdayCore

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

private func validationDraft(
    name: String = "妈妈",
    emailEnabled: Bool = true,
    emailAddress: String = "a@b",
    emailMessage: String = "生日快乐"
) -> BirthdayDraft {
    BirthdayDraft(
        name: name,
        lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false),
        reminder: ReminderConfig(
            timeMinutes: 540,
            notifyDayBefore: true,
            notifySameDay: true,
            emailEnabled: emailEnabled,
            emailAddress: emailAddress,
            emailMessage: emailMessage
        )
    )
}

@Test func sharedEmailContractAcceptsMinimalDomainAndTrimsCommonWhitespaceForValidation() throws {
    try BirthdayValidator.validate(validationDraft(emailAddress: "a@b"))
    try BirthdayValidator.validate(validationDraft(
        name: "\t\n妈妈\r ",
        emailAddress: " \t a@b \n"
    ))
}

@Test func sharedEmailContractRequiresExactlyOneNonEdgeAtSign() {
    for email in ["@b", "a@", "a@@b"] {
        #expect(throws: BirthdayValidationError.invalidEmail) {
            try BirthdayValidator.validate(validationDraft(emailAddress: email))
        }
    }
}

@Test func sharedNameLimitCountsExtendedGraphemeClusters() throws {
    let combining = "e\u{301}"
    let family = "👨‍👩‍👧‍👦"
    for name in [String(repeating: combining, count: 64), String(repeating: family, count: 64)] {
        #expect(name.count == 64)
        try BirthdayValidator.validate(validationDraft(name: name))
    }
    for name in [String(repeating: combining, count: 65), String(repeating: family, count: 65)] {
        #expect(name.count == 65)
        #expect(throws: BirthdayValidationError.nameTooLong) {
            try BirthdayValidator.validate(validationDraft(name: name))
        }
    }
}

@Test func sharedEmailLimitCountsExtendedGraphemeClusters() throws {
    let combining = "e\u{301}"
    let email128 = String(repeating: combining, count: 126) + "@b"
    let email129 = String(repeating: combining, count: 127) + "@b"
    #expect(email128.count == 128)
    #expect(email129.count == 129)
    try BirthdayValidator.validate(validationDraft(emailAddress: email128))
    #expect(throws: BirthdayValidationError.invalidEmail) {
        try BirthdayValidator.validate(validationDraft(emailAddress: email129))
    }
}

@Test func sharedEmailMessageLimitUsesFinalUTF8StorageBytesOnlyWhenEnabled() throws {
    try BirthdayValidator.validate(validationDraft(
        name: "M",
        emailMessage: String(repeating: "a", count: 65_534)
    ))
    #expect(throws: BirthdayValidationError.emailMessageTooLong) {
        try BirthdayValidator.validate(validationDraft(
            name: "M",
            emailMessage: String(repeating: "a", count: 65_535)
        ))
    }
    try BirthdayValidator.validate(validationDraft(
        name: "M",
        emailEnabled: false,
        emailMessage: String(repeating: "🎂", count: 20_000)
    ))
}

@Test func exposesPublicInitializersForPersistenceAndSyncModels() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reminder = ReminderConfig.defaults
    let record = BirthdayRecord(
        id: UUID(),
        name: "妈妈",
        lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false),
        reminder: reminder,
        nextSolarDate: now,
        version: 1,
        createdAt: now,
        updatedAt: now,
        deletedAt: nil,
        syncState: .pending
    )
    let operation = SyncOperation(
        operationId: UUID(),
        entityId: record.id,
        operationType: "upsert",
        baseVersion: record.version,
        payloadJSON: Data(),
        createdAt: now,
        attemptCount: 0,
        nextRetryAt: nil,
        lastErrorCategory: nil
    )

    #expect(operation.id == operation.operationId)
    #expect(operation.entityId == record.id)
}
