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
}
