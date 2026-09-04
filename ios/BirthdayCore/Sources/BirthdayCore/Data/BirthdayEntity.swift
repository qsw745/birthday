import Foundation
import SwiftData

extension BirthdaySchemaV2 {
  @Model
  public final class BirthdayEntity {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var lunarMonth: Int
    public var lunarDay: Int
    public var isLeapMonth: Bool
    public var reminderTimeMinutes: Int
    public var notifyDayBefore: Bool
    public var notifySameDay: Bool
    public var emailEnabled: Bool
    public var emailAddress: String
    public var emailMessage: String
    public var nextSolarDate: Date?
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var syncStateRaw: String

    public init(id: UUID, draft: BirthdayDraft, nextSolarDate: Date, now: Date) {
      self.id = id
      self.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
      self.lunarMonth = draft.lunarBirthday.month
      self.lunarDay = draft.lunarBirthday.day
      self.isLeapMonth = draft.lunarBirthday.isLeapMonth
      self.reminderTimeMinutes = draft.reminder.timeMinutes
      self.notifyDayBefore = draft.reminder.notifyDayBefore
      self.notifySameDay = draft.reminder.notifySameDay
      self.emailEnabled = draft.reminder.emailEnabled
      self.emailAddress = draft.reminder.emailAddress
      self.emailMessage = draft.reminder.emailMessage
      self.nextSolarDate = nextSolarDate
      self.version = 0
      self.createdAt = now
      self.updatedAt = now
      self.deletedAt = nil
      self.syncStateRaw = SyncState.pending.rawValue
    }
  }
}

public typealias BirthdayEntity = BirthdaySchemaV3.BirthdayEntity
