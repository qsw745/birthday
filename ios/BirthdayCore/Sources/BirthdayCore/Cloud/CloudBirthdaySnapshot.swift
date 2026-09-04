import Foundation

public struct CloudBirthdaySnapshot: Codable, Equatable, Sendable {
  public static let currentSchemaVersion: Int64 = 1

  public let schemaVersion: Int64
  public let id: UUID
  public let name: String
  public let lunarMonth: Int
  public let lunarDay: Int
  public let isLeapMonth: Bool
  public let reminderTimeMinutes: Int
  public let notifyDayBefore: Bool
  public let notifySameDay: Bool
  public let createdAt: Date
  public let updatedAt: Date
  public let deletedAt: Date?

  public init(
    schemaVersion: Int64 = Self.currentSchemaVersion,
    id: UUID,
    name: String,
    lunarMonth: Int,
    lunarDay: Int,
    isLeapMonth: Bool,
    reminderTimeMinutes: Int,
    notifyDayBefore: Bool,
    notifySameDay: Bool,
    createdAt: Date,
    updatedAt: Date,
    deletedAt: Date?
  ) throws {
    try Self.validate(
      schemaVersion: schemaVersion,
      name: name,
      lunarMonth: lunarMonth,
      lunarDay: lunarDay,
      isLeapMonth: isLeapMonth,
      reminderTimeMinutes: reminderTimeMinutes,
      notifyDayBefore: notifyDayBefore,
      notifySameDay: notifySameDay
    )
    self.schemaVersion = schemaVersion
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.lunarMonth = lunarMonth
    self.lunarDay = lunarDay
    self.isLeapMonth = isLeapMonth
    self.reminderTimeMinutes = reminderTimeMinutes
    self.notifyDayBefore = notifyDayBefore
    self.notifySameDay = notifySameDay
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  public init(record: BirthdayRecord) throws {
    try self.init(
      id: record.id,
      name: record.name,
      lunarMonth: record.lunarBirthday.month,
      lunarDay: record.lunarBirthday.day,
      isLeapMonth: record.lunarBirthday.isLeapMonth,
      reminderTimeMinutes: record.reminder.timeMinutes,
      notifyDayBefore: record.reminder.notifyDayBefore,
      notifySameDay: record.reminder.notifySameDay,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      deletedAt: record.deletedAt
    )
  }

  private static func validate(
    schemaVersion: Int64,
    name: String,
    lunarMonth: Int,
    lunarDay: Int,
    isLeapMonth: Bool,
    reminderTimeMinutes: Int,
    notifyDayBefore: Bool,
    notifySameDay: Bool
  ) throws {
    guard schemaVersion == currentSchemaVersion else {
      throw CloudRecordCodecError.unsupportedSchemaVersion(schemaVersion)
    }
    do {
      try BirthdayValidator.validate(
        BirthdayDraft(
          name: name,
          lunarBirthday: LunarBirthday(
            month: lunarMonth,
            day: lunarDay,
            isLeapMonth: isLeapMonth
          ),
          reminder: ReminderConfig(
            timeMinutes: reminderTimeMinutes,
            notifyDayBefore: notifyDayBefore,
            notifySameDay: notifySameDay,
            emailEnabled: false,
            emailAddress: "",
            emailMessage: ""
          )
        )
      )
    } catch {
      throw CloudRecordCodecError.invalidBirthday
    }
  }
}
