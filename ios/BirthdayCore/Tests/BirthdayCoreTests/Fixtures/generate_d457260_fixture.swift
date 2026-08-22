import Foundation
import SwiftData

// Stored declarations copied from exact commit d457260. Keep these top-level: their entity identity
// is the compatibility boundary this fixture is intended to preserve.
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

  init(id: UUID, now: Date) {
    self.id = id
    name = "旧版妈妈"
    lunarMonth = 8
    lunarDay = 15
    isLeapMonth = false
    reminderTimeMinutes = 540
    notifyDayBefore = true
    notifySameDay = true
    emailEnabled = false
    emailAddress = ""
    emailMessage = ""
    nextSolarDate = now.addingTimeInterval(86_400)
    version = 0
    createdAt = now
    updatedAt = now
    deletedAt = nil
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
    payloadJSON = Data(#"{"name":"旧版妈妈"}"#.utf8)
    createdAt = now.addingTimeInterval(60)
    attemptCount = 2
    nextRetryAt = nil
    lastErrorCategory = nil
  }
}

@Model
final class SyncMetadataEntity {
  @Attribute(.unique) var key: String
  var cursor: Int64

  init() {
    key = "primary"
    cursor = 9
  }
}

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("用法：swift generate_d457260_fixture.swift <输出.store>\n".utf8))
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

let birthdayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
let operationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
let now = Date(timeIntervalSince1970: 1_700_000_000)
let container = try ModelContainer(
  for: BirthdayEntity.self,
  SyncOperationEntity.self,
  SyncMetadataEntity.self,
  configurations: ModelConfiguration(url: outputURL)
)
let context = ModelContext(container)
context.insert(BirthdayEntity(id: birthdayID, now: now))
context.insert(SyncOperationEntity(operationId: operationID, entityId: birthdayID, now: now))
context.insert(SyncMetadataEntity())
try context.save()
