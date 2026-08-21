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

private struct Plan3PushOperationEnvelope: Encodable {
    let operationId: UUID
    let entityId: UUID
    let type: String
    let baseVersion: String
    let payload: BirthdayOutboxPayload
}

private struct Plan3PushEnvelope: Encodable {
    let operations: [Plan3PushOperationEnvelope]
}

@Test func sharedContractTrimsUnicodeWhiteSpaceButPreservesByteOrderMark() throws {
    try BirthdayValidator.validate(validationDraft(emailAddress: "a@b"))
    try BirthdayValidator.validate(validationDraft(
        name: "\u{0085}妈妈\u{0085}",
        emailAddress: "\u{0085}a@b\u{0085}"
    ))
    try BirthdayValidator.validate(validationDraft(name: "\u{FEFF}"))
    try BirthdayValidator.validate(validationDraft(emailAddress: "\u{FEFF}@\u{FEFF}"))
    #expect(throws: BirthdayValidationError.emptyName) {
        try BirthdayValidator.validate(validationDraft(name: "\u{0085}"))
    }
    #expect(throws: BirthdayValidationError.invalidEmail) {
        try BirthdayValidator.validate(validationDraft(emailAddress: "\u{0085}@\u{0085}"))
    }
}

@Test func sharedEmailContractRequiresExactlyOneNonEdgeAtSign() {
    for email in ["@b", "a@", "a@@b"] {
        #expect(throws: BirthdayValidationError.invalidEmail) {
            try BirthdayValidator.validate(validationDraft(emailAddress: email))
        }
    }
}

@Test func sharedNameLimitProtectsBothGraphemeAndUTF8MB4ScalarCapacity() throws {
    let combining = "e\u{301}"
    let family = "👨‍👩‍👧‍👦"
    for name in [
        String(repeating: "人", count: 64),
        String(repeating: combining, count: 32),
        String(repeating: family, count: 9),
    ] {
        #expect(name.count <= 64)
        #expect(name.unicodeScalars.count <= 64)
        try BirthdayValidator.validate(validationDraft(name: name))
    }
    for name in [
        String(repeating: "人", count: 65),
        String(repeating: combining, count: 33),
        String(repeating: family, count: 10),
    ] {
        #expect(name.count > 64 || name.unicodeScalars.count > 64)
        #expect(throws: BirthdayValidationError.nameTooLong) {
            try BirthdayValidator.validate(validationDraft(name: name))
        }
    }
}

@Test func sharedEmailLimitProtectsBothGraphemeAndUTF8MB4ScalarCapacity() throws {
    let combining = "e\u{301}"
    let family = "👨‍👩‍👧‍👦"
    for email in [
        String(repeating: "a", count: 126) + "@b",
        String(repeating: combining, count: 63) + "@b",
        String(repeating: family, count: 18) + "@b",
    ] {
        #expect(email.count <= 128)
        #expect(email.unicodeScalars.count <= 128)
        try BirthdayValidator.validate(validationDraft(emailAddress: email))
    }
    for email in [
        String(repeating: "a", count: 127) + "@b",
        String(repeating: combining, count: 64) + "@b",
        String(repeating: family, count: 19) + "@b",
    ] {
        #expect(email.count > 128 || email.unicodeScalars.count > 128)
        #expect(throws: BirthdayValidationError.invalidEmail) {
            try BirthdayValidator.validate(validationDraft(emailAddress: email))
        }
    }
}

@Test func sharedEmailMessageLimitCapsFinalStorageAt8192UTF8BytesOnlyWhenEnabled() throws {
    try BirthdayValidator.validate(validationDraft(
        name: "M",
        emailMessage: String(repeating: "a", count: 8_191)
    ))
    #expect(throws: BirthdayValidationError.emailMessageTooLong) {
        try BirthdayValidator.validate(validationDraft(
            name: "M",
            emailMessage: String(repeating: "a", count: 8_192)
        ))
    }
    try BirthdayValidator.validate(validationDraft(
        name: "M",
        emailMessage: String(repeating: "🎂", count: 2_047)
    ))
    #expect(throws: BirthdayValidationError.emailMessageTooLong) {
        try BirthdayValidator.validate(validationDraft(
            name: "M",
            emailMessage: String(repeating: "🎂", count: 2_048)
        ))
    }
    try BirthdayValidator.validate(validationDraft(
        name: "M",
        emailEnabled: false,
        emailMessage: String(repeating: "🎂", count: 20_000)
    ))
}

@Test func escapedControlEmailAtStorageLimitFitsCompleteCompactPushEnvelope() throws {
    let emailMessage = "\\\"\u{0000}\u{001F}" + String(repeating: "\u{0000}", count: 8_187)
    let draft = validationDraft(name: "M", emailMessage: emailMessage)
    try BirthdayValidator.validate(draft)
    #expect((draft.name + draft.reminder.emailMessage).utf8.count == 8_192)

    let entityId = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
    let operationId = try #require(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = BirthdayOutboxPayload(record: BirthdayRecord(
        id: entityId,
        name: draft.name,
        lunarBirthday: draft.lunarBirthday,
        reminder: draft.reminder,
        nextSolarDate: now,
        version: 0,
        createdAt: now,
        updatedAt: now,
        deletedAt: nil,
        syncState: .pending
    ))
    let envelope = Plan3PushEnvelope(operations: [Plan3PushOperationEnvelope(
        operationId: operationId,
        entityId: entityId,
        type: "upsert",
        baseVersion: "0",
        payload: payload
    )])

    let compactJSON = try JSONEncoder().encode(envelope)
    #expect(compactJSON.count > 32 * 1_024)
    #expect(compactJSON.count <= 60 * 1_024)
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
