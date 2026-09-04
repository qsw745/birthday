import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

@Suite(.serialized) struct CloudSyncStoreTests {
  @Test func bootstrapMarksEveryMigratedV2BirthdayAndTombstoneForUpload() async throws {
    try await withMigratedV2CloudStore { container, store in
      try await store.bootstrapCloudState()

      let pending = try await store.pendingCloudChanges(limit: 10)
      #expect(Set(pending.map(\.snapshot.id)) == [
        UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      ])
      #expect(pending.contains { $0.snapshot.deletedAt != nil })

      let context = ModelContext(container)
      #expect(try context.fetchCount(FetchDescriptor<SyncOperationEntity>()) == 1)
      #expect(try context.fetchCount(FetchDescriptor<SyncMetadataEntity>()) == 1)
      #expect(try context.fetchCount(FetchDescriptor<SyncConflictEntity>()) == 1)
    }
  }

  @Test func localCreateEditDeleteAndRestoreAlwaysRefreshCloudMutation() async throws {
    let store = try makeCloudStore()
    let created = try await store.save(
      cloudDraft("妈妈"), id: nil, now: cloudNow, timeZone: cloudTimeZone)
    let createMutation = try #require(
      try await store.pendingCloudChanges(limit: 10).first?.mutationID)

    _ = try await store.save(
      cloudDraft("妈妈（已编辑）"), id: created.id,
      now: cloudNow.addingTimeInterval(1), timeZone: cloudTimeZone)
    let editMutation = try #require(
      try await store.pendingCloudChanges(limit: 10).first?.mutationID)

    try await store.softDelete(id: created.id, now: cloudNow.addingTimeInterval(2))
    let deleted = try #require(try await store.pendingCloudChanges(limit: 10).first)

    try await store.restore(id: created.id, now: cloudNow.addingTimeInterval(3))
    let restored = try #require(try await store.pendingCloudChanges(limit: 10).first)

    #expect(createMutation != editMutation)
    #expect(editMutation != deleted.mutationID)
    #expect(deleted.snapshot.deletedAt != nil)
    #expect(deleted.mutationID != restored.mutationID)
    #expect(restored.snapshot.deletedAt == nil)
  }

  @Test func failedLocalCommitRollsBackBirthdayServerOutboxAndCloudStateTogether() async throws {
    let container = try makeCloudContainer()
    let store = BirthdayStore(
      modelContainer: container,
      transactionCommitter: { _ in throw CloudCommitFailure.expected }
    )

    await #expect(throws: CloudCommitFailure.expected) {
      try await store.save(
        cloudDraft("不应保存"), id: nil, now: cloudNow, timeZone: cloudTimeZone)
    }

    let context = ModelContext(container)
    #expect(try context.fetchCount(FetchDescriptor<BirthdayEntity>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<SyncOperationEntity>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<CloudRecordStateEntity>()) == 0)
  }

  @Test func remoteCloudApplyRecalculatesDerivedDateWithoutServerOutboxOrEchoUpload() async throws {
    let store = try makeCloudStore()
    let remote = try cloudSnapshot(name: "来自 iCloud")

    try await store.applyRemoteCloudChanges(
      [CloudRemoteChange(snapshot: remote, encodedSystemFields: Data("system".utf8))],
      now: cloudNow,
      timeZone: cloudTimeZone
    )

    let saved = try #require(try await store.activeBirthdays().first)
    #expect(saved.id == remote.id)
    #expect(saved.name == "来自 iCloud")
    #expect(saved.nextSolarDate != nil)
    #expect(try await store.pendingOperations().isEmpty)
    #expect(try await store.pendingCloudChanges(limit: 10).isEmpty)
  }

  @Test func hardCloudDeletionRestagesTheLocalSnapshotWithoutDeletingBusinessData() async throws {
    let store = try makeCloudStore()
    let created = try await store.save(
      cloudDraft("不应被物理删除"), id: nil, now: cloudNow, timeZone: cloudTimeZone)
    let sent = try #require(try await store.pendingCloudChanges(limit: 1).first)
    try await store.markCloudUploadSucceeded(
      CloudUploadSuccess(
        entityID: sent.snapshot.id,
        mutationID: sent.mutationID,
        uploadedSnapshot: sent.snapshot,
        encodedSystemFields: Data("stale-system-fields".utf8)
      )
    )

    try await store.restageCloudRecordsDeletedRemotely([
      created.id,
      UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
    ])

    let stillLocal = try #require(try await store.activeBirthdays().first)
    let pending = try #require(try await store.pendingCloudChanges(limit: 10).first)
    #expect(stillLocal.id == created.id)
    #expect(stillLocal.name == "不应被物理删除")
    #expect(pending.snapshot.id == created.id)
    #expect(pending.encodedSystemFields == nil)
  }

  @Test func cloudUploadAcknowledgementDoesNotClearANewerLocalMutation() async throws {
    let store = try makeCloudStore()
    let created = try await store.save(
      cloudDraft("妈妈"), id: nil, now: cloudNow, timeZone: cloudTimeZone)
    let sent = try #require(try await store.pendingCloudChanges(limit: 1).first)

    _ = try await store.save(
      cloudDraft("更新后的妈妈"), id: created.id,
      now: cloudNow.addingTimeInterval(1), timeZone: cloudTimeZone)
    try await store.markCloudUploadSucceeded(
      CloudUploadSuccess(
        entityID: sent.snapshot.id,
        mutationID: sent.mutationID,
        uploadedSnapshot: sent.snapshot,
        encodedSystemFields: Data("saved-system".utf8)
      )
    )

    let stillPending = try #require(try await store.pendingCloudChanges(limit: 1).first)
    #expect(stillPending.snapshot.name == "更新后的妈妈")
    #expect(stillPending.mutationID != sent.mutationID)
  }

  @Test func cloudConflictKeepsBothSnapshotsAndEitherResolutionAvoidsServerOutbox() async throws {
    let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let base = try cloudSnapshot(id: id, name: "共同基础")
    let local = try cloudSnapshot(id: id, name: "本机修改")
    let remote = try cloudSnapshot(id: id, name: "iCloud 修改")

    let keepLocalStore = try makeSeededCloudStore(base: base, local: local)
    try await keepLocalStore.applyRemoteCloudChanges(
      [CloudRemoteChange(snapshot: remote, encodedSystemFields: Data("remote-system".utf8))],
      now: cloudNow,
      timeZone: cloudTimeZone
    )
    let conflict = try #require(try await keepLocalStore.cloudConflicts().first)
    #expect(conflict.local == local)
    #expect(conflict.iCloud == remote)
    try await keepLocalStore.resolveCloudConflictKeepingLocal(id: id, now: cloudNow)
    #expect(try await keepLocalStore.cloudConflicts().isEmpty)
    #expect(try await keepLocalStore.pendingCloudChanges(limit: 1).count == 1)
    #expect(try await keepLocalStore.pendingOperations().isEmpty)

    let useCloudStore = try makeSeededCloudStore(base: base, local: local)
    try await useCloudStore.applyRemoteCloudChanges(
      [CloudRemoteChange(snapshot: remote, encodedSystemFields: Data("remote-system".utf8))],
      now: cloudNow,
      timeZone: cloudTimeZone
    )
    try await useCloudStore.resolveCloudConflictUsingICloud(
      id: id, now: cloudNow, timeZone: cloudTimeZone)
    #expect(try await useCloudStore.activeBirthdays().first?.name == "iCloud 修改")
    #expect(try await useCloudStore.pendingCloudChanges(limit: 1).isEmpty)
    #expect(try await useCloudStore.pendingOperations().isEmpty)
  }
}

private enum CloudCommitFailure: Error, Equatable {
  case expected
}

private let cloudNow = Date(timeIntervalSince1970: 1_788_000_000)
private let cloudTimeZone = TimeZone(identifier: "Asia/Shanghai")!

private func cloudDraft(_ name: String) -> BirthdayDraft {
  BirthdayDraft(
    name: name,
    lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
    reminder: .defaults
  )
}

private func cloudSnapshot(
  id: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
  name: String
) throws -> CloudBirthdaySnapshot {
  try CloudBirthdaySnapshot(
    id: id,
    name: name,
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    reminderTimeMinutes: 540,
    notifyDayBefore: true,
    notifySameDay: true,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_600),
    deletedAt: nil
  )
}

private func makeCloudContainer() throws -> ModelContainer {
  try BirthdayModelContainer.make(
    configuration: ModelConfiguration(isStoredInMemoryOnly: true)
  )
}

private func makeCloudStore() throws -> BirthdayStore {
  BirthdayStore(modelContainer: try makeCloudContainer())
}

private func makeSeededCloudStore(
  base: CloudBirthdaySnapshot,
  local: CloudBirthdaySnapshot
) throws -> BirthdayStore {
  let container = try makeCloudContainer()
  let context = ModelContext(container)
  let entity = BirthdayEntity(
    id: local.id,
    draft: cloudDraft(local.name),
    nextSolarDate: cloudNow.addingTimeInterval(86_400),
    now: local.createdAt
  )
  entity.updatedAt = local.updatedAt
  entity.syncStateRaw = SyncState.synced.rawValue
  context.insert(entity)
  context.insert(
    CloudRecordStateEntity(
      entityId: local.id,
      baseSnapshotJSON: try JSONEncoder().encode(base),
      encodedSystemFields: Data("base-system".utf8),
      needsUpload: true,
      lastMutationID: UUID()
    )
  )
  try context.save()
  return BirthdayStore(modelContainer: container)
}

private func withMigratedV2CloudStore(
  _ body: (ModelContainer, BirthdayStore) async throws -> Void
) async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("birthday-cloud-bootstrap-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let storeURL = directory.appendingPathComponent("Birthday.store")
  let fixture = try #require(
    Bundle.module.url(
      forResource: "v2-pre-cloud",
      withExtension: "store",
      subdirectory: "Fixtures"
    )
  )
  try FileManager.default.copyItem(at: fixture, to: storeURL)
  let container = try BirthdayModelContainer.make(
    configuration: ModelConfiguration(url: storeURL)
  )
  try await body(container, BirthdayStore(modelContainer: container))
}
