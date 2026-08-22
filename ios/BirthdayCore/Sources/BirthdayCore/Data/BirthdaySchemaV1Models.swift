import Foundation
import SwiftData

extension BirthdaySchemaV1 {
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

  @Model
  public final class SyncOperationEntity {
    @Attribute(.unique) public var operationId: UUID
    public var entityId: UUID
    public var operationType: String
    public var baseVersion: Int64
    public var payloadJSON: Data
    public var createdAt: Date
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var lastErrorCategory: String?

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

  @Model
  public final class SyncMetadataEntity {
    @Attribute(.unique) public var key: String
    public var cursor: Int64

    public init(key: String, cursor: Int64) {
      self.key = key
      self.cursor = cursor
    }
  }
}
