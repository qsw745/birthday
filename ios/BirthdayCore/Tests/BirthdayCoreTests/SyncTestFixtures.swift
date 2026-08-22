import Foundation
import SwiftData

@testable import BirthdayCore

func makeSyncContainer() throws -> ModelContainer {
  try ModelContainer(
    for: BirthdayEntity.self,
    SyncOperationEntity.self,
    SyncMetadataEntity.self,
    SyncConflictEntity.self,
    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
  )
}

func makeSyncStore() throws -> BirthdayStore {
  BirthdayStore(modelContainer: try makeSyncContainer())
}

let canonicalRemoteReminder = ReminderConfig(
  timeMinutes: 540,
  notifyDayBefore: true,
  notifySameDay: true,
  emailEnabled: false,
  emailAddress: "",
  emailMessage: ""
)

func makeAPIBirthday(
  id: UUID = UUID(),
  name: String = "妈妈",
  month: Int = 8,
  day: Int = 15,
  isLeapMonth: Bool = false,
  reminder: ReminderConfig = canonicalRemoteReminder,
  nextSolarDate: Date? = nil,
  version: Int64 = 1,
  createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
  updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
  deletedAt: Date? = nil
) -> APIBirthday {
  APIBirthday(
    id: id,
    name: name,
    lunarMonth: month,
    lunarDay: day,
    isLeapMonth: isLeapMonth,
    reminder: reminder,
    nextSolarDate: nextSolarDate,
    version: version,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt
  )
}

func insertSyncedBirthday(
  _ remote: APIBirthday,
  into container: ModelContainer
) throws {
  let context = ModelContext(container)
  let entity = BirthdayEntity(
    id: remote.id,
    draft: BirthdayDraft(
      name: remote.name,
      lunarBirthday: LunarBirthday(
        month: remote.lunarMonth,
        day: remote.lunarDay,
        isLeapMonth: remote.isLeapMonth
      ),
      reminder: remote.reminder
    ),
    nextSolarDate: remote.nextSolarDate ?? remote.updatedAt,
    now: remote.createdAt
  )
  entity.nextSolarDate = remote.nextSolarDate
  entity.version = remote.version
  entity.updatedAt = remote.updatedAt
  entity.deletedAt = remote.deletedAt
  entity.syncStateRaw = SyncState.synced.rawValue
  context.insert(entity)
  try context.save()
}

struct ConflictFixture {
  let container: ModelContainer
  let store: BirthdayStore
  let birthdayId: UUID
  let operationId: UUID
  let local: APIBirthday
  let remote: APIBirthday
}

func makeConflictFixture(
  localVersion: Int64 = 3,
  remoteVersion: Int64 = 5,
  remoteDeleted: Bool = false,
  localDeleted: Bool = false
) throws -> ConflictFixture {
  let container = try makeSyncContainer()
  let context = ModelContext(container)
  let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  let operationId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let localReminder =
    localDeleted
    ? ReminderConfig(
      timeMinutes: 615,
      notifyDayBefore: false,
      notifySameDay: true,
      emailEnabled: false,
      emailAddress: "",
      emailMessage: ""
    )
    : ReminderConfig(
      timeMinutes: 615,
      notifyDayBefore: false,
      notifySameDay: true,
      emailEnabled: true,
      emailAddress: "local@example.com",
      emailMessage: "本机完整正文"
    )
  let remoteReminder =
    remoteDeleted
    ? ReminderConfig(
      timeMinutes: 480,
      notifyDayBefore: false,
      notifySameDay: true,
      emailEnabled: false,
      emailAddress: "",
      emailMessage: ""
    )
    : ReminderConfig(
      timeMinutes: 480,
      notifyDayBefore: true,
      notifySameDay: false,
      emailEnabled: true,
      emailAddress: "remote@example.com",
      emailMessage: "云端完整正文"
    )
  let localDeletedAt = localDeleted ? now.addingTimeInterval(90) : nil
  let remoteDeletedAt = remoteDeleted ? now.addingTimeInterval(120) : nil
  let local = makeAPIBirthday(
    id: id,
    name: "本机妈妈",
    month: 8,
    day: 15,
    isLeapMonth: true,
    reminder: localReminder,
    nextSolarDate: now.addingTimeInterval(86_400),
    version: localVersion,
    createdAt: now.addingTimeInterval(-600),
    updatedAt: now.addingTimeInterval(60),
    deletedAt: localDeletedAt
  )
  let remote = makeAPIBirthday(
    id: id,
    name: remoteDeleted ? "云端已删除" : "云端父亲",
    month: 9,
    day: 3,
    isLeapMonth: false,
    reminder: remoteReminder,
    nextSolarDate: remoteDeleted ? nil : now.addingTimeInterval(172_800),
    version: remoteVersion,
    createdAt: now.addingTimeInterval(-1_200),
    updatedAt: now.addingTimeInterval(120),
    deletedAt: remoteDeletedAt
  )
  let entity = BirthdayEntity(
    id: id,
    draft: BirthdayDraft(
      name: local.name,
      lunarBirthday: LunarBirthday(
        month: local.lunarMonth,
        day: local.lunarDay,
        isLeapMonth: local.isLeapMonth
      ),
      reminder: local.reminder
    ),
    nextSolarDate: local.nextSolarDate!,
    now: local.createdAt
  )
  entity.version = local.version
  entity.updatedAt = local.updatedAt
  entity.deletedAt = local.deletedAt
  entity.syncStateRaw = SyncState.conflict.rawValue
  let operation = SyncOperationEntity(
    operationId: operationId,
    entityId: id,
    operationType: localDeleted ? "delete" : "upsert",
    baseVersion: localVersion,
    payloadJSON: try MobileJSON.encoder.encode(
      BirthdayPayloadDTO(record: local.asRecord(syncState: .conflict))),
    createdAt: now,
    attemptCount: 1,
    nextRetryAt: nil,
    lastErrorCategory: "conflict_blocked"
  )
  let conflict = SyncConflictEntity(
    entityId: id,
    operationId: operationId,
    localSnapshotJSON: try SyncConflictSnapshot.encode(local, side: .local),
    remoteSnapshotJSON: try SyncConflictSnapshot.encode(remote, side: .remote),
    createdAt: now,
    updatedAt: now,
    kindRaw: remoteDeleted
      ? SyncConflictKind.deleteEdit.rawValue : SyncConflictKind.editEdit.rawValue
  )
  context.insert(entity)
  context.insert(operation)
  context.insert(conflict)
  try context.save()
  return ConflictFixture(
    container: container,
    store: BirthdayStore(modelContainer: container),
    birthdayId: id,
    operationId: operationId,
    local: local,
    remote: remote
  )
}
