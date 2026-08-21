import Foundation

public struct LunarBirthday: Codable, Equatable, Hashable, Sendable {
    public var month: Int
    public var day: Int
    public var isLeapMonth: Bool

    public init(month: Int, day: Int, isLeapMonth: Bool) {
        self.month = month
        self.day = day
        self.isLeapMonth = isLeapMonth
    }
}

public struct ReminderConfig: Codable, Equatable, Sendable {
    public var timeMinutes: Int
    public var notifyDayBefore: Bool
    public var notifySameDay: Bool
    public var emailEnabled: Bool
    public var emailAddress: String
    public var emailMessage: String

    public init(
        timeMinutes: Int,
        notifyDayBefore: Bool,
        notifySameDay: Bool,
        emailEnabled: Bool,
        emailAddress: String,
        emailMessage: String
    ) {
        self.timeMinutes = timeMinutes
        self.notifyDayBefore = notifyDayBefore
        self.notifySameDay = notifySameDay
        self.emailEnabled = emailEnabled
        self.emailAddress = emailAddress
        self.emailMessage = emailMessage
    }

    public static let defaults = ReminderConfig(
        timeMinutes: 540,
        notifyDayBefore: true,
        notifySameDay: true,
        emailEnabled: false,
        emailAddress: "",
        emailMessage: "生日快乐"
    )
}

public struct BirthdayDraft: Equatable, Sendable {
    public var name: String
    public var lunarBirthday: LunarBirthday
    public var reminder: ReminderConfig

    public init(name: String, lunarBirthday: LunarBirthday, reminder: ReminderConfig) {
        self.name = name
        self.lunarBirthday = lunarBirthday
        self.reminder = reminder
    }
}

public enum SyncState: String, Codable, Sendable {
    case synced, pending, conflict, pendingDelete
}

public struct BirthdayRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var lunarBirthday: LunarBirthday
    public var reminder: ReminderConfig
    public var nextSolarDate: Date?
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var syncState: SyncState

    public init(
        id: UUID,
        name: String,
        lunarBirthday: LunarBirthday,
        reminder: ReminderConfig,
        nextSolarDate: Date?,
        version: Int64,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date?,
        syncState: SyncState
    ) {
        self.id = id
        self.name = name
        self.lunarBirthday = lunarBirthday
        self.reminder = reminder
        self.nextSolarDate = nextSolarDate
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncState = syncState
    }
}

public struct SyncOperation: Identifiable, Equatable, Sendable {
    public var id: UUID { operationId }
    public let operationId: UUID
    public let entityId: UUID
    public let operationType: String
    public let baseVersion: Int64
    public let payloadJSON: Data
    public let createdAt: Date
    public let attemptCount: Int
    public let nextRetryAt: Date?
    public let lastErrorCategory: String?

    public init(
        operationId: UUID,
        entityId: UUID,
        operationType: String,
        baseVersion: Int64,
        payloadJSON: Data,
        createdAt: Date,
        attemptCount: Int,
        nextRetryAt: Date?,
        lastErrorCategory: String?
    ) {
        self.operationId = operationId
        self.entityId = entityId
        self.operationType = operationType
        self.baseVersion = baseVersion
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastErrorCategory = lastErrorCategory
    }
}

public struct BirthdayOutboxPayload: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let lunarMonth: Int
    public let lunarDay: Int
    public let isLeapMonth: Bool
    public let reminderTimeMinutes: Int
    public let notifyDayBefore: Bool
    public let notifySameDay: Bool
    public let emailEnabled: Bool
    public let emailAddress: String
    public let emailMessage: String

    public init(record: BirthdayRecord) {
        schemaVersion = Self.currentSchemaVersion
        id = record.id
        name = record.name
        lunarMonth = record.lunarBirthday.month
        lunarDay = record.lunarBirthday.day
        isLeapMonth = record.lunarBirthday.isLeapMonth
        reminderTimeMinutes = record.reminder.timeMinutes
        notifyDayBefore = record.reminder.notifyDayBefore
        notifySameDay = record.reminder.notifySameDay
        emailEnabled = record.reminder.emailEnabled
        emailAddress = record.reminder.emailAddress
        emailMessage = record.reminder.emailMessage
    }
}
