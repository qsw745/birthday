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
