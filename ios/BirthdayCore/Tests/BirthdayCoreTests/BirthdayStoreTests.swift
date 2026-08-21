import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

private enum InjectedCommitFailure: Error, Equatable {
  case saveFailed
}

private final class FailOnceCommitter: @unchecked Sendable {
  private let lock = NSLock()
  private var hasFailed = false

  func commit(_ modelContext: ModelContext) throws {
    lock.lock()
    let shouldFail = !hasFailed
    hasFailed = true
    lock.unlock()

    if shouldFail {
      throw InjectedCommitFailure.saveFailed
    }
    try modelContext.save()
  }
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

private func makeFailOnceStore(_ container: ModelContainer) -> BirthdayStore {
  let committer = FailOnceCommitter()
  return BirthdayStore(
    modelContainer: container,
    transactionCommitter: { modelContext in
      try committer.commit(modelContext)
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

private struct Plan3BirthdayPayloadDTO: Decodable, Equatable {
  let id: UUID
  let name: String
  let lunarMonth: Int
  let lunarDay: Int
  let isLeapMonth: Bool
  let reminderTimeMinutes: Int
  let notifyDayBefore: Bool
  let notifySameDay: Bool
  let emailEnabled: Bool
  let emailAddress: String
  let emailMessage: String
}

private func insertSyncedBirthday(
  into container: ModelContainer,
  id: UUID = UUID(),
  version: Int64 = 3,
  deletedAt: Date? = nil
) throws -> UUID {
  let context = ModelContext(container)
  let entity = BirthdayEntity(
    id: id,
    draft: draft(name: "服务器已有记录"),
    nextSolarDate: storeNow.addingTimeInterval(86_400),
    now: storeNow.addingTimeInterval(-60)
  )
  entity.version = version
  entity.deletedAt = deletedAt
  entity.syncStateRaw = deletedAt == nil ? SyncState.synced.rawValue : SyncState.pendingDelete.rawValue
  context.insert(entity)
  try context.save()
  return id
}

@Suite(.serialized) struct BirthdayStoreTests {

@Test func savePersistsBirthdayAndOutboxAtomically() async throws {
  let store = makeStore(try makeContainer())

  let saved = try await store.save(
    draft(name: "妈妈"), id: nil, now: storeNow, timeZone: storeTimeZone)

  #expect(try await store.activeBirthdays().map(\.id) == [saved.id])
  #expect(try await store.pendingOperations().count == 1)
}

@Test func overlongEnabledEmailIsRejectedBeforeBirthdayOrOutboxPersistence() async throws {
  let store = makeStore(try makeContainer())
  let reminder = ReminderConfig(
    timeMinutes: 540,
    notifyDayBefore: true,
    notifySameDay: true,
    emailEnabled: true,
    emailAddress: "a@b",
    emailMessage: String(repeating: "a", count: 8_192)
  )

  await #expect(throws: BirthdayValidationError.emailMessageTooLong) {
    try await store.save(
      draft(name: "M", reminder: reminder), id: nil, now: storeNow, timeZone: storeTimeZone)
  }
  #expect(try await store.activeBirthdays().isEmpty)
  #expect(try await store.pendingOperations().isEmpty)
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

@Test func createThenRepeatedEditsCoalesceIntoOneLatestUpsert() async throws {
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

  let firstOperation = try #require(try await store.pendingOperations().first)
  _ = try await store.save(
    draft(name: "中间名字"),
    id: original.id,
    now: updatedAt.addingTimeInterval(-1),
    timeZone: storeTimeZone
  )
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
  let operation = try #require(operations.last)

  #expect(updated.id == original.id)
  #expect(updated.name == "妈妈的新名字")
  #expect(updated.lunarBirthday == .init(month: 9, day: 3, isLeapMonth: true))
  #expect(updated.reminder == updatedReminder)
  #expect(updated.createdAt == original.createdAt)
  #expect(updated.updatedAt == updatedAt)
  #expect(updated.version == original.version)
  #expect(operations.count == 1)
  #expect(operation.operationId == firstOperation.operationId)
  #expect(operation.operationType == "upsert")
  #expect(operation.entityId == original.id)
  #expect(operation.baseVersion == original.version)
  #expect(operation.createdAt == firstOperation.createdAt)
  #expect(try JSONDecoder().decode(BirthdayOutboxPayload.self, from: operation.payloadJSON).name == updated.name)
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

@Test func createThenDeleteLeavesNoRemoteOperation() async throws {
  let store = makeStore(try makeContainer())
  let saved = try await store.save(
    draft(name: "爸爸"), id: nil, now: storeNow, timeZone: storeTimeZone)

  try await store.softDelete(id: saved.id, now: storeNow.addingTimeInterval(1))

  #expect(try await store.activeBirthdays().isEmpty)
  #expect(try await store.pendingOperations().isEmpty)
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
  #expect(try JSONDecoder().decode(BirthdayOutboxPayload.self, from: operation.payloadJSON).id == restored.id)
}

@Test func editThenDeleteCoalescesToOneDeleteAtServerBaseVersion() async throws {
  let container = try makeContainer()
  let id = try insertSyncedBirthday(into: container, version: 7)
  let store = makeStore(container)

  _ = try await store.save(
    draft(name: "本机编辑"),
    id: id,
    now: storeNow,
    timeZone: storeTimeZone
  )
  try await store.softDelete(id: id, now: storeNow.addingTimeInterval(1))

  let operation = try #require(try await store.pendingOperations().only)
  #expect(operation.operationType == "delete")
  #expect(operation.baseVersion == 7)
}

@Test func deleteThenRestoreCoalescesToOneCompleteUpsert() async throws {
  let container = try makeContainer()
  let id = try insertSyncedBirthday(into: container, version: 9)
  let store = makeStore(container)

  try await store.softDelete(id: id, now: storeNow)
  let deleteOperation = try #require(try await store.pendingOperations().only)
  try await store.restore(id: id, now: storeNow.addingTimeInterval(1))

  let operation = try #require(try await store.pendingOperations().only)
  let payload = try JSONDecoder().decode(BirthdayOutboxPayload.self, from: operation.payloadJSON)
  #expect(operation.operationId == deleteOperation.operationId)
  #expect(operation.operationType == "upsert")
  #expect(operation.baseVersion == 9)
  #expect(payload.id == id)
  #expect(payload.name == "服务器已有记录")
}

@Test func outboxPayloadIsVersionedFlatAndDecodesAsPlan3BirthdayPayload() async throws {
  let store = makeStore(try makeContainer())
  let saved = try await store.save(
    draft(name: "妈妈"), id: nil, now: storeNow, timeZone: storeTimeZone)
  let operation = try #require(try await store.pendingOperations().only)

  let versioned = try JSONDecoder().decode(BirthdayOutboxPayload.self, from: operation.payloadJSON)
  let plan3 = try JSONDecoder().decode(Plan3BirthdayPayloadDTO.self, from: operation.payloadJSON)
  let object = try #require(
    JSONSerialization.jsonObject(with: operation.payloadJSON) as? [String: Any]
  )

  #expect(versioned.schemaVersion == 1)
  #expect(plan3.id == saved.id)
  #expect(plan3.name == "妈妈")
  #expect(plan3.lunarMonth == 8)
  #expect(plan3.reminderTimeMinutes == 540)
  #expect(object["lunarBirthday"] == nil)
  #expect(object["reminder"] == nil)
  #expect(object["nextSolarDate"] == nil)
}

@Test func disabledEmailOutboxClearsUnusedAddressAndMessageWithoutRewritingLocalRecord() async throws {
  let store = makeStore(try makeContainer())
  let reminder = ReminderConfig(
    timeMinutes: 540,
    notifyDayBefore: true,
    notifySameDay: true,
    emailEnabled: false,
    emailAddress: "keep-locally@example.com",
    emailMessage: String(repeating: "🎂", count: 9_000)
  )

  let saved = try await store.save(
    draft(name: "妈妈", reminder: reminder),
    id: nil,
    now: storeNow,
    timeZone: storeTimeZone
  )
  let operation = try #require(try await store.pendingOperations().only)
  let payload = try JSONDecoder().decode(BirthdayOutboxPayload.self, from: operation.payloadJSON)

  #expect(saved.reminder.emailAddress == "keep-locally@example.com")
  #expect(saved.reminder.emailMessage == reminder.emailMessage)
  #expect(payload.emailEnabled == false)
  #expect(payload.emailAddress == "")
  #expect(payload.emailMessage == "")
}

@Test func derivedDateRefreshRollsYearWithoutOutboxOrServerVersionMutation() async throws {
  let store = makeStore(try makeContainer())
  let saved = try await store.save(
    draft(name: "妈妈"),
    id: nil,
    now: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!,
    timeZone: storeTimeZone
  )
  let outboxBefore = try await store.pendingOperations()
  let afterOccurrence = ISO8601DateFormatter().date(from: "2026-09-25T02:00:00Z")!

  let refreshedCount = try await store.refreshNextSolarDates(
    now: afterOccurrence,
    timeZone: storeTimeZone
  )
  let refreshed = try #require(try await store.activeBirthdays().first)

  #expect(refreshedCount == 1)
  #expect(refreshed.nextSolarDate != saved.nextSolarDate)
  #expect(refreshed.nextSolarDate! > ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!)
  #expect(refreshed.version == saved.version)
  #expect(refreshed.updatedAt == saved.updatedAt)
  #expect(try await store.pendingOperations() == outboxBefore)
}

@Test func derivedDateRefreshReinterpretsWallTimeAfterTimeZoneChangeWithoutOutbox() async throws {
  let store = makeStore(try makeContainer())
  let reference = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
  let saved = try await store.save(
    draft(name: "妈妈"), id: nil, now: reference, timeZone: storeTimeZone)
  let outboxBefore = try await store.pendingOperations()
  let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

  _ = try await store.refreshNextSolarDates(now: reference, timeZone: losAngeles)
  let refreshed = try #require(try await store.activeBirthdays().first)
  let localComponents = Calendar(identifier: .gregorian).dateComponents(
    in: losAngeles,
    from: refreshed.nextSolarDate!
  )

  #expect(refreshed.nextSolarDate != saved.nextSolarDate)
  #expect(localComponents.hour == 9)
  #expect(localComponents.minute == 0)
  #expect(try await store.pendingOperations() == outboxBefore)
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

@Test func failedNewSaveLeavesSameStoreReadyForOneCleanLaterCommit() async throws {
  let container = try makeContainer()
  let store = makeFailOnceStore(container)

  await #expect(throws: InjectedCommitFailure.saveFailed) {
    try await store.save(draft(name: "妈妈"), id: nil, now: storeNow, timeZone: storeTimeZone)
  }

  let saved = try await store.save(
    draft(name: "成功保存"), id: nil, now: storeNow.addingTimeInterval(1), timeZone: storeTimeZone)
  let operation = try #require(try await store.pendingOperations().last)

  #expect(try await store.activeBirthdays() == [saved])
  #expect(try await store.pendingOperations().count == 1)
  #expect(operation.operationType == "upsert")
  #expect(operation.entityId == saved.id)
  #expect(try JSONDecoder().decode(BirthdayOutboxPayload.self, from: operation.payloadJSON).id == saved.id)
}

@Test func failedUpdateLeavesSameStoreReadyForOneCleanLaterCommit() async throws {
  let container = try makeContainer()
  let seedStore = makeStore(container)
  let original = try await seedStore.save(
    draft(name: "原始姓名"), id: nil, now: storeNow, timeZone: storeTimeZone)
  let failingStore = makeFailOnceStore(container)

  await #expect(throws: InjectedCommitFailure.saveFailed) {
    try await failingStore.save(
      draft(name: "不应提交的新姓名"),
      id: original.id,
      now: storeNow.addingTimeInterval(1),
      timeZone: storeTimeZone
    )
  }

  let updated = try await failingStore.save(
    draft(name: "成功更新"),
    id: original.id,
    now: storeNow.addingTimeInterval(2),
    timeZone: storeTimeZone
  )
  let operation = try #require(try await failingStore.pendingOperations().last)

  #expect(try await failingStore.activeBirthdays() == [updated])
  #expect(try await failingStore.pendingOperations().count == 1)
  #expect(operation.operationType == "upsert")
  #expect(operation.entityId == original.id)
  #expect(try JSONDecoder().decode(BirthdayOutboxPayload.self, from: operation.payloadJSON).name == updated.name)
}

@Test func failedSoftDeleteLeavesSameStoreReadyForOneCleanLaterCommit() async throws {
  let container = try makeContainer()
  let seedStore = makeStore(container)
  let original = try await seedStore.save(
    draft(name: "爸爸"), id: nil, now: storeNow, timeZone: storeTimeZone)
  let failingStore = makeFailOnceStore(container)

  await #expect(throws: InjectedCommitFailure.saveFailed) {
    try await failingStore.softDelete(id: original.id, now: storeNow.addingTimeInterval(1))
  }

  let deletedAt = storeNow.addingTimeInterval(2)
  try await failingStore.softDelete(id: original.id, now: deletedAt)
  #expect(try await failingStore.activeBirthdays().isEmpty)
  #expect(try await failingStore.pendingOperations().isEmpty)
}

@Test func failedRestoreLeavesSameStoreReadyForOneCleanLaterCommit() async throws {
  let container = try makeContainer()
  let seedStore = makeStore(container)
  let saved = try await seedStore.save(
    draft(name: "爸爸"), id: nil, now: storeNow, timeZone: storeTimeZone)
  try await seedStore.softDelete(id: saved.id, now: storeNow.addingTimeInterval(1))
  let failingStore = makeFailOnceStore(container)

  await #expect(throws: InjectedCommitFailure.saveFailed) {
    try await failingStore.restore(id: saved.id, now: storeNow.addingTimeInterval(2))
  }

  try await failingStore.restore(id: saved.id, now: storeNow.addingTimeInterval(3))
  let restored = try #require(try await failingStore.activeBirthdays().first)
  let operation = try #require(try await failingStore.pendingOperations().last)

  #expect(restored.id == saved.id)
  #expect(restored.deletedAt == nil)
  #expect(restored.syncState == .pending)
  #expect(try await failingStore.pendingOperations().count == 1)
  #expect(operation.operationType == "upsert")
  #expect(operation.entityId == saved.id)
  #expect(try JSONDecoder().decode(BirthdayOutboxPayload.self, from: operation.payloadJSON).id == restored.id)
}

}

private extension Array {
  var only: Element? {
    count == 1 ? first : nil
  }
}
