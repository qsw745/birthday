import Foundation
import SwiftData

public enum BirthdaySchemaV3: VersionedSchema {
  public static let versionIdentifier = Schema.Version(3, 0, 0)
  public static let models: [any PersistentModel.Type] = [
    BirthdayEntity.self,
    SyncOperationEntity.self,
    SyncMetadataEntity.self,
    SyncConflictEntity.self,
    CloudRecordStateEntity.self,
    CloudSyncEngineStateEntity.self,
    CloudSyncConflictEntity.self,
  ]
}

extension BirthdaySchemaV3 {
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

  @Model
  public final class SyncConflictEntity {
    @Attribute(.unique) public var entityId: UUID
    public var operationId: UUID?
    public var localSnapshotJSON: Data
    public var remoteSnapshotJSON: Data
    public var createdAt: Date
    public var updatedAt: Date
    public var kindRaw: String = "editEdit"

    public init(
      entityId: UUID,
      operationId: UUID?,
      localSnapshotJSON: Data,
      remoteSnapshotJSON: Data,
      createdAt: Date,
      updatedAt: Date,
      kindRaw: String = SyncConflictKind.editEdit.rawValue
    ) {
      self.entityId = entityId
      self.operationId = operationId
      self.localSnapshotJSON = localSnapshotJSON
      self.remoteSnapshotJSON = remoteSnapshotJSON
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.kindRaw = kindRaw
    }
  }

  @Model
  public final class CloudRecordStateEntity {
    @Attribute(.unique) public var entityId: UUID
    public var baseSnapshotJSON: Data?
    public var encodedSystemFields: Data?
    public var needsUpload: Bool
    public var lastMutationID: UUID?
    public var lastErrorCategory: String?

    public init(
      entityId: UUID,
      baseSnapshotJSON: Data? = nil,
      encodedSystemFields: Data? = nil,
      needsUpload: Bool = false,
      lastMutationID: UUID? = nil,
      lastErrorCategory: String? = nil
    ) {
      self.entityId = entityId
      self.baseSnapshotJSON = baseSnapshotJSON
      self.encodedSystemFields = encodedSystemFields
      self.needsUpload = needsUpload
      self.lastMutationID = lastMutationID
      self.lastErrorCategory = lastErrorCategory
    }
  }

  @Model
  public final class CloudSyncEngineStateEntity {
    @Attribute(.unique) public var key: String
    public var serializedState: Data?
    public var initialMergeCompleted: Bool
    public var lastSuccessfulFetchAt: Date?

    public init(
      key: String,
      serializedState: Data? = nil,
      initialMergeCompleted: Bool = false,
      lastSuccessfulFetchAt: Date? = nil
    ) {
      self.key = key
      self.serializedState = serializedState
      self.initialMergeCompleted = initialMergeCompleted
      self.lastSuccessfulFetchAt = lastSuccessfulFetchAt
    }
  }

  @Model
  public final class CloudSyncConflictEntity {
    @Attribute(.unique) public var entityId: UUID
    public var localSnapshotJSON: Data
    public var iCloudSnapshotJSON: Data
    public var kindRaw: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
      entityId: UUID,
      localSnapshotJSON: Data,
      iCloudSnapshotJSON: Data,
      kindRaw: String,
      createdAt: Date,
      updatedAt: Date
    ) {
      self.entityId = entityId
      self.localSnapshotJSON = localSnapshotJSON
      self.iCloudSnapshotJSON = iCloudSnapshotJSON
      self.kindRaw = kindRaw
      self.createdAt = createdAt
      self.updatedAt = updatedAt
    }
  }
}

public typealias CloudRecordStateEntity = BirthdaySchemaV3.CloudRecordStateEntity
public typealias CloudSyncEngineStateEntity = BirthdaySchemaV3.CloudSyncEngineStateEntity
public typealias CloudSyncConflictEntity = BirthdaySchemaV3.CloudSyncConflictEntity
