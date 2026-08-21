import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

private enum InjectedCommitFailure: Error, Equatable {
  case saveFailed
}

private func makeContainer() throws -> ModelContainer {
  try ModelContainer(
    for: BirthdayEntity.self,
    SyncOperationEntity.self,
    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
  )
}

private func makeStore(_ container: ModelContainer) -> BirthdayStore {
  BirthdayStore(modelContainer: container)
}

private func makeFailingStore(_ container: ModelContainer) -> BirthdayStore {
  BirthdayStore(
    modelContainer: container,
    transactionCommitter: { _ in
      throw InjectedCommitFailure.saveFailed
    })
}

private let storeTimeZone = TimeZone(identifier: "Asia/Shanghai")!
private let storeNow = Date(timeIntervalSince1970: 1_788_000_000)

private func draft(name: String, reminder: ReminderConfig = .defaults) -> BirthdayDraft {
  BirthdayDraft(
    name: name,
    lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false),
    reminder: reminder
  )
}

@Test func savePersistsBirthdayAndOutboxAtomically() async throws {
  let store = makeStore(try makeContainer())

  let saved = try await store.save(
    draft(name: "妈妈"), id: nil, now: storeNow, timeZone: storeTimeZone)

  #expect(try await store.activeBirthdays().map(\.id) == [saved.id])
  #expect(try await store.pendingOperations().count == 1)
}

@Test func saveRoundTripsAllReminderFieldsAndInitialVersion() async throws {
  let store = makeStore(try makeContainer())
  let reminder = ReminderConfig(
    timeMinutes: 615,
    notifyDayBefore: false,
    notifySameDay: true,
    emailEnabled: true,
    emailAddress: "a@example.com",
    emailMessage: "记得打电话"
  )

  let saved = try await store.save(
    .init(
      name: "  妈妈  ", lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false),
      reminder: reminder),
    id: nil,
    now: storeNow,
    timeZone: storeTimeZone
  )

  #expect(saved.name == "妈妈")
  #expect(saved.reminder == reminder)
  #expect(saved.version == 0)
  #expect(try await store.activeBirthdays() == [saved])
}

@Test func updatingExistingBirthdayPreservesCreatedAtAndVersionAndQueuesFullPayload() async throws {
  let store = makeStore(try makeContainer())
  let original = try await store.save(
    draft(name: "妈妈"), id: nil, now: storeNow, timeZone: storeTimeZone)
  let updatedReminder = ReminderConfig(
    timeMinutes: 615,
    notifyDayBefore: false,
    notifySameDay: true,
    emailEnabled: true,
    emailAddress: "updated@example.com",
    emailMessage: "新的提醒内容"
  )
  let updatedAt = storeNow.addingTimeInterval(60)

  let updated = try await store.save(
    .init(
      name: "  妈妈的新名字  ",
      lunarBirthday: .init(month: 9, day: 3, isLeapMonth: true),
      reminder: updatedReminder
    ),
    id: original.id,
    now: updatedAt,
    timeZone: storeTimeZone
  )
  let operations = try await store.pendingOperations()
  let secondOperation = try #require(operations.last)

  #expect(updated.id == original.id)
  #expect(updated.name == "妈妈的新名字")
  #expect(updated.lunarBirthday == .init(month: 9, day: 3, isLeapMonth: true))
  #expect(updated.reminder == updatedReminder)
  #expect(updated.createdAt == original.createdAt)
  #expect(updated.updatedAt == updatedAt)
  #expect(updated.version == original.version)
  #expect(operations.count == 2)
  #expect(secondOperation.operationType == "upsert")
  #expect(secondOperation.entityId == original.id)
  #expect(secondOperation.baseVersion == original.version)
  #expect(secondOperation.createdAt == updatedAt)
  #expect(
    try JSONDecoder().decode(BirthdayRecord.self, from: secondOperation.payloadJSON) == updated)
}

@Test func activeBirthdaysSortEqualDatesByCreationOrder() async throws {
  let store = makeStore(try makeContainer())
  let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

  _ = try await store.save(draft(name: "同日生日"), id: firstID, now: storeNow, timeZone: storeTimeZone)
  _ = try await store.save(
    draft(name: "同日生日"), id: secondID, now: storeNow, timeZone: storeTimeZone)

  #expect(try await store.activeBirthdays().map(\.id) == [firstID, secondID])
}

@Test func softDeleteHidesRecordAndCreatesDeleteOperation() async throws {
  let store = makeStore(try makeContainer())
  let saved = try await store.save(
    draft(name: "爸爸"), id: nil, now: storeNow, timeZone: storeTimeZone)

  try await store.softDelete(id: saved.id, now: storeNow.addingTimeInterval(1))

  #expect(try await store.activeBirthdays().isEmpty)
  #expect(try await store.pendingOperations().last?.operationType == "delete")
}

@Test func restoreQueuesCompleteUpsertPayloadAndDefaultMetadata() async throws {
  let store = makeStore(try makeContainer())
  let saved = try await store.save(
    draft(name: "爸爸"), id: nil, now: storeNow, timeZone: storeTimeZone)
  try await store.softDelete(id: saved.id, now: storeNow.addingTimeInterval(1))
  let restoredAt = storeNow.addingTimeInterval(2)

  try await store.restore(id: saved.id, now: restoredAt)

  let restored = try #require(try await store.activeBirthdays().first)
  let operation = try #require(try await store.pendingOperations().last)
  #expect(restored.id == saved.id)
  #expect(restored.deletedAt == nil)
  #expect(restored.syncState == .pending)
  #expect(restored.updatedAt == restoredAt)
  #expect(operation.operationType == "upsert")
  #expect(operation.entityId == saved.id)
  #expect(operation.baseVersion == saved.version)
  #expect(operation.createdAt == restoredAt)
  #expect(operation.attemptCount == 0)
  #expect(operation.nextRetryAt == nil)
  #expect(operation.lastErrorCategory == nil)
  #expect(try JSONDecoder().decode(BirthdayRecord.self, from: operation.payloadJSON) == restored)
}

@Test func activeBirthdaysRejectsUnknownSyncStateInsteadOfMaskingIt() async throws {
  let container = try makeContainer()
  let context = ModelContext(container)
  let entity = BirthdayEntity(
    id: UUID(), draft: draft(name: "数据损坏"), nextSolarDate: storeNow, now: storeNow)
  entity.syncStateRaw = "unexpected-state"
  context.insert(entity)
  try context.save()
  let store = makeStore(container)

  await #expect(throws: BirthdayStoreError.unknownSyncState("unexpected-state")) {
    try await store.activeBirthdays()
  }
}

@Test func mutationsRejectUnknownSyncStateBeforeChangingPersistedRecord() async throws {
  let container = try makeContainer()
  let context = ModelContext(container)
  let originalUpdatedAt = storeNow.addingTimeInterval(-1)
  let originalDeletedAt = storeNow
  let entity = BirthdayEntity(
    id: UUID(),
    draft: draft(name: "数据损坏"),
    nextSolarDate: storeNow,
    now: originalUpdatedAt
  )
  entity.deletedAt = originalDeletedAt
  entity.syncStateRaw = "unexpected-state"
  context.insert(entity)
  try context.save()
  let store = makeStore(container)

  await #expect(throws: BirthdayStoreError.unknownSyncState("unexpected-state")) {
    try await store.save(
      draft(name: "不应覆盖"), id: entity.id, now: storeNow.addingTimeInterval(1),
      timeZone: storeTimeZone)
  }
  await #expect(throws: BirthdayStoreError.unknownSyncState("unexpected-state")) {
    try await store.softDelete(id: entity.id, now: storeNow.addingTimeInterval(2))
  }
  await #expect(throws: BirthdayStoreError.unknownSyncState("unexpected-state")) {
    try await store.restore(id: entity.id, now: storeNow.addingTimeInterval(3))
  }

  let observer = ModelContext(container)
  let persisted = try #require(try observer.fetch(FetchDescriptor<BirthdayEntity>()).first)
  #expect(persisted.name == "数据损坏")
  #expect(persisted.updatedAt == originalUpdatedAt)
  #expect(persisted.deletedAt == originalDeletedAt)
  #expect(persisted.syncStateRaw == "unexpected-state")
}

@Test func failedNewSaveRollsBackBirthdayAndOutboxTogether() async throws {
  let container = try makeContainer()
  let store = makeFailingStore(container)

  await #expect(throws: InjectedCommitFailure.saveFailed) {
    try await store.save(draft(name: "妈妈"), id: nil, now: storeNow, timeZone: storeTimeZone)
  }

  let observer = makeStore(container)
  #expect(try await observer.activeBirthdays().isEmpty)
  #expect(try await observer.pendingOperations().isEmpty)
}

@Test func failedUpdateRollsBackBirthdayAndSecondOutbox() async throws {
  let container = try makeContainer()
  let seedStore = makeStore(container)
  let original = try await seedStore.save(
    draft(name: "原始姓名"), id: nil, now: storeNow, timeZone: storeTimeZone)
  let failingStore = makeFailingStore(container)

  await #expect(throws: InjectedCommitFailure.saveFailed) {
    try await failingStore.save(
      draft(name: "不应提交的新姓名"),
      id: original.id,
      now: storeNow.addingTimeInterval(1),
      timeZone: storeTimeZone
    )
  }

  let observer = makeStore(container)
  #expect(try await observer.activeBirthdays() == [original])
  #expect(try await observer.pendingOperations().count == 1)
}

@Test func failedSoftDeleteRollsBackTombstoneAndDeleteOutbox() async throws {
  let container = try makeContainer()
  let seedStore = makeStore(container)
  let original = try await seedStore.save(
    draft(name: "爸爸"), id: nil, now: storeNow, timeZone: storeTimeZone)
  let failingStore = makeFailingStore(container)

  await #expect(throws: InjectedCommitFailure.saveFailed) {
    try await failingStore.softDelete(id: original.id, now: storeNow.addingTimeInterval(1))
  }

  let observer = makeStore(container)
  #expect(try await observer.activeBirthdays() == [original])
  #expect(try await observer.pendingOperations().count == 1)
}

@Test func failedRestoreRollsBackActiveStateAndUpsertOutbox() async throws {
  let container = try makeContainer()
  let seedStore = makeStore(container)
  let saved = try await seedStore.save(
    draft(name: "爸爸"), id: nil, now: storeNow, timeZone: storeTimeZone)
  try await seedStore.softDelete(id: saved.id, now: storeNow.addingTimeInterval(1))
  let failingStore = makeFailingStore(container)

  await #expect(throws: InjectedCommitFailure.saveFailed) {
    try await failingStore.restore(id: saved.id, now: storeNow.addingTimeInterval(2))
  }

  let observer = makeStore(container)
  #expect(try await observer.activeBirthdays().isEmpty)
  let operations = try await observer.pendingOperations()
  #expect(operations.count == 2)
  #expect(operations.last?.operationType == "delete")
}
