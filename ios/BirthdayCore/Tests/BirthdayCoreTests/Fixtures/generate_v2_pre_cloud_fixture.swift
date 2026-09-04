import Foundation
import SwiftData

// Frozen declarations copied from the V2 production schema before CloudKit support.
// Keep this generator independent from BirthdayCore so future model aliases cannot alter the fixture.
enum BirthdaySchemaV2: VersionedSchema {
  static let versionIdentifier = Schema.Version(2, 0, 0)
  static let models: [any PersistentModel.Type] = [
    BirthdayEntity.self,
    SyncOperationEntity.self,
    SyncMetadataEntity.self,
    SyncConflictEntity.self,
  ]

  @Model
  final class BirthdayEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var lunarMonth: Int
    var lunarDay: Int
    var isLeapMonth: Bool
    var reminderTimeMinutes: Int
    var notifyDayBefore: Bool
    var notifySameDay: Bool
    var emailEnabled: Bool
    var emailAddress: String
    var emailMessage: String
    var nextSolarDate: Date?
    var version: Int64
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var syncStateRaw: String

    init(id: UUID, name: String, now: Date, deletedAt: Date? = nil) {
      self.id = id
      self.name = name
      lunarMonth = 8
      lunarDay = 15
      isLeapMonth = false
      reminderTimeMinutes = 540
      notifyDayBefore = true
      notifySameDay = true
      emailEnabled = false
      emailAddress = ""
      emailMessage = ""
      nextSolarDate = deletedAt == nil ? now.addingTimeInterval(86_400) : nil
      version = deletedAt == nil ? 7 : 4
      createdAt = now
      updatedAt = deletedAt ?? now
      self.deletedAt = deletedAt
      syncStateRaw = "pending"
    }
  }

  @Model
  final class SyncOperationEntity {
    @Attribute(.unique) var operationId: UUID
    var entityId: UUID
    var operationType: String
    var baseVersion: Int64
    var payloadJSON: Data
    var createdAt: Date
    var attemptCount: Int
    var nextRetryAt: Date?
    var lastErrorCategory: String?

    init(operationId: UUID, entityId: UUID, now: Date) {
      self.operationId = operationId
      self.entityId = entityId
      operationType = "update"
      baseVersion = 7
      payloadJSON = Data(#"{"name":"V2 妈妈"}"#.utf8)
      createdAt = now.addingTimeInterval(60)
      attemptCount = 2
      nextRetryAt = nil
      lastErrorCategory = "network"
    }
  }

  @Model
  final class SyncMetadataEntity {
    @Attribute(.unique) var key: String
    var cursor: Int64

    init() {
      key = "primary"
      cursor = 19
    }
  }

  @Model
  final class SyncConflictEntity {
    @Attribute(.unique) var entityId: UUID
    var operationId: UUID?
    var localSnapshotJSON: Data
    var remoteSnapshotJSON: Data
    var createdAt: Date
    var updatedAt: Date
    var kindRaw: String = "editEdit"

    init(entityId: UUID, operationId: UUID, now: Date) {
      self.entityId = entityId
      self.operationId = operationId
      localSnapshotJSON = Data(#"{"side":"local","name":"本机妈妈"}"#.utf8)
      remoteSnapshotJSON = Data(#"{"side":"remote","name":"云端妈妈"}"#.utf8)
      createdAt = now.addingTimeInterval(120)
      updatedAt = now.addingTimeInterval(180)
      kindRaw = "editEdit"
    }
  }
}

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("用法：swift generate_v2_pre_cloud_fixture.swift <输出.store>\n".utf8))
  exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: outputURL.path) else {
  FileHandle.standardError.write(Data("拒绝覆盖已有夹具：\(outputURL.path)\n".utf8))
  exit(73)
}

try FileManager.default.createDirectory(
  at: outputURL.deletingLastPathComponent(),
  withIntermediateDirectories: true
)

let activeBirthdayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
let operationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
let tombstoneID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
let now = Date(timeIntervalSince1970: 1_700_000_000)
let deletedAt = now.addingTimeInterval(300)
let container = try ModelContainer(
  for: Schema(versionedSchema: BirthdaySchemaV2.self),
  configurations: ModelConfiguration(url: outputURL)
)
let context = ModelContext(container)
context.insert(BirthdaySchemaV2.BirthdayEntity(id: activeBirthdayID, name: "V2 妈妈", now: now))
context.insert(
  BirthdaySchemaV2.BirthdayEntity(
    id: tombstoneID,
    name: "V2 已删除好友",
    now: now,
    deletedAt: deletedAt
  )
)
context.insert(
  BirthdaySchemaV2.SyncOperationEntity(
    operationId: operationID,
    entityId: activeBirthdayID,
    now: now
  )
)
context.insert(BirthdaySchemaV2.SyncMetadataEntity())
context.insert(
  BirthdaySchemaV2.SyncConflictEntity(
    entityId: activeBirthdayID,
    operationId: operationID,
    now: now
  )
)
try context.save()
