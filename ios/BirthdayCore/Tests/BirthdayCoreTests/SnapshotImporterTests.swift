import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

private enum SnapshotCommitFailure: Error, Equatable {
  case failed
}

private final class SnapshotCommitRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var countStorage = 0
  private let shouldFail: Bool

  init(shouldFail: Bool = false) {
    self.shouldFail = shouldFail
  }

  var count: Int {
    lock.withLock { countStorage }
  }

  func commit(_ context: ModelContext) throws {
    try lock.withLock {
      countStorage += 1
      if shouldFail {
        throw SnapshotCommitFailure.failed
      }
    }
    try context.save()
  }
}

private let snapshotNow = Date(timeIntervalSince1970: 1_788_000_000)
private let snapshotTimeZone = TimeZone(identifier: "Asia/Shanghai")!

private func localDraft(name: String, month: Int = 8, day: Int = 15) -> BirthdayDraft {
  BirthdayDraft(
    name: name,
    lunarBirthday: LunarBirthday(month: month, day: day, isLeapMonth: false),
    reminder: .defaults
  )
}

@Suite(.serialized) struct SnapshotImporterTests {
  @Test func previewUsesTrimmedCaseAndDiacriticInsensitiveNameWithLunarKey() {
    let local = BirthdayRecord.fixture(id: UUID(), name: "  MÁMĀ  ", month: 8, day: 15)
    let remote = makeAPIBirthday(id: UUID(), name: "mama", month: 8, day: 15)

    let preview = SnapshotImporter.preview(local: [local], remote: [remote])

    #expect(preview.remoteCount == 1)
    #expect(preview.duplicates.count == 1)
    #expect(preview.duplicates.first?.local.id == local.id)
    #expect(preview.duplicates.first?.remote.id == remote.id)
  }

  @Test func previewDoesNotFlagMatchingUUIDOrRemoteTombstonesAsDuplicates() {
    let id = UUID()
    let local = BirthdayRecord.fixture(id: id, name: "妈妈", month: 8, day: 15)
    let sameID = makeAPIBirthday(id: id, name: "妈妈", month: 8, day: 15)
    let tombstone = makeAPIBirthday(
      id: UUID(),
      name: "妈妈",
      month: 8,
      day: 15,
      deletedAt: snapshotNow
    )

    let preview = SnapshotImporter.preview(local: [local], remote: [sameID, tombstone])

    #expect(preview.remoteCount == 2)
    #expect(preview.duplicates.isEmpty)
  }

  @Test func missingDuplicateDecisionWritesNothingAndDoesNotAdvanceCursor() async throws {
    let store = try makeSyncStore()
    let local = try await store.save(
      localDraft(name: "妈妈"),
      id: UUID(),
      now: snapshotNow,
      timeZone: snapshotTimeZone
    )
    let remote = makeAPIBirthday(id: UUID(), name: "妈妈")

    await #expect(throws: SnapshotImportError.missingDuplicateDecision) {
      try await store.applySnapshot(
        SnapshotResponse(cursor: 41, birthdays: [remote]),
        decisions: [:]
      )
    }

    #expect(try await store.activeBirthdays() == [local])
    #expect(try await store.pendingOperations().map(\.entityId) == [local.id])
    #expect(try await store.syncCursor() == 0)
  }

  @Test func invalidSnapshotPrevalidatesEveryRecordBeforeWriting() async throws {
    let store = try makeSyncStore()
    let valid = makeAPIBirthday(id: UUID(), name: "妈妈")
    let invalid = makeAPIBirthday(id: UUID(), name: "   ")

    await #expect(throws: BirthdayValidationError.emptyName) {
      try await store.applySnapshot(
        SnapshotResponse(cursor: 41, birthdays: [valid, invalid]),
        decisions: [:]
      )
    }

    #expect(try await store.activeBirthdays().isEmpty)
    #expect(try await store.pendingOperations().isEmpty)
    #expect(try await store.syncCursor() == 0)
  }

  @Test func duplicateRemoteUUIDFailsBeforeWriting() async throws {
    let store = try makeSyncStore()
    let id = UUID()

    await #expect(throws: SnapshotImportError.duplicateRemoteID(id)) {
      try await store.applySnapshot(
        SnapshotResponse(
          cursor: 41,
          birthdays: [
            makeAPIBirthday(id: id, name: "妈妈"),
            makeAPIBirthday(id: id, name: "爸爸"),
          ]
        ),
        decisions: [:]
      )
    }

    #expect(try await store.activeBirthdays().isEmpty)
    #expect(try await store.syncCursor() == 0)
  }

  @Test func emptyLocalSnapshotImportsAllRecordsAdvancesCursorAndSavesOnce() async throws {
    let container = try makeSyncContainer()
    let recorder = SnapshotCommitRecorder()
    let store = BirthdayStore(
      modelContainer: container,
      transactionCommitter: recorder.commit
    )
    let active = makeAPIBirthday(id: UUID(), name: "妈妈", version: 3)
    let tombstone = makeAPIBirthday(
      id: UUID(),
      name: "旧记录",
      version: 7,
      deletedAt: snapshotNow
    )

    try await store.applySnapshot(
      SnapshotResponse(cursor: 41, birthdays: [active, tombstone]),
      decisions: [:]
    )

    #expect(try await store.activeBirthdays().map(\.id) == [active.id])
    #expect(try await store.pendingOperations().isEmpty)
    #expect(try await store.syncCursor() == 41)
    #expect(recorder.count == 1)

    let context = ModelContext(container)
    let all = try context.fetch(FetchDescriptor<BirthdayEntity>())
    #expect(all.count == 2)
    #expect(all.first(where: { $0.id == tombstone.id })?.deletedAt == snapshotNow)
  }

  @Test func matchingUUIDUpdatesSyncedLocalWithoutBecomingDuplicate() async throws {
    let container = try makeSyncContainer()
    let id = UUID()
    try insertSyncedBirthday(
      makeAPIBirthday(id: id, name: "旧名字", version: 2),
      into: container
    )
    let store = BirthdayStore(modelContainer: container)
    let remote = makeAPIBirthday(id: id, name: "服务器新名字", month: 9, day: 3, version: 4)

    try await store.applySnapshot(
      SnapshotResponse(cursor: 9, birthdays: [remote]),
      decisions: [:]
    )

    let imported = try #require(try await store.activeBirthdays().first)
    #expect(imported.id == id)
    #expect(imported.name == "服务器新名字")
    #expect(imported.lunarBirthday == LunarBirthday(month: 9, day: 3, isLeapMonth: false))
    #expect(imported.version == 4)
    #expect(imported.syncState == .synced)
    #expect(try await store.syncCursor() == 9)
  }

  @Test func matchingUUIDWithLocalPendingUpsertPreservesLocalRecordAndOutbox() async throws {
    let store = try makeSyncStore()
    let id = UUID()
    let local = try await store.save(
      localDraft(name: "本机编辑"),
      id: id,
      now: snapshotNow,
      timeZone: snapshotTimeZone
    )
    let operation = try #require(try await store.pendingOperations().first)

    try await store.applySnapshot(
      SnapshotResponse(
        cursor: 12,
        birthdays: [makeAPIBirthday(id: id, name: "服务器旧值", version: 4)]
      ),
      decisions: [:]
    )

    #expect(try await store.activeBirthdays() == [local])
    #expect(try await store.pendingOperations() == [operation])
    #expect(try await store.syncCursor() == 12)
  }

  @Test func matchingUUIDWithLocalPendingDeletePreservesTombstoneAndOutbox() async throws {
    let container = try makeSyncContainer()
    let id = UUID()
    try insertSyncedBirthday(makeAPIBirthday(id: id, name: "本机删除前", version: 3), into: container)
    let store = BirthdayStore(modelContainer: container)
    try await store.softDelete(id: id, now: snapshotNow)
    let operation = try #require(try await store.pendingOperations().first)

    try await store.applySnapshot(
      SnapshotResponse(
        cursor: 13,
        birthdays: [makeAPIBirthday(id: id, name: "服务器仍存在", version: 4)]
      ),
      decisions: [:]
    )

    #expect(try await store.activeBirthdays().isEmpty)
    #expect(try await store.pendingOperations() == [operation])
    #expect(try await store.syncCursor() == 13)
  }

  @Test func keepBothPreservesLocalPendingRecordAndImportsRemoteUUID() async throws {
    let store = try makeSyncStore()
    let local = try await store.save(
      localDraft(name: "妈妈"),
      id: UUID(),
      now: snapshotNow,
      timeZone: snapshotTimeZone
    )
    let remote = makeAPIBirthday(id: UUID(), name: "妈妈", version: 5)
    let candidate = try #require(
      SnapshotImporter.preview(local: [local], remote: [remote]).duplicates.first
    )

    try await store.applySnapshot(
      SnapshotResponse(cursor: 14, birthdays: [remote]),
      decisions: [candidate.id: .keepBoth]
    )

    let records = try await store.activeBirthdays()
    #expect(Set(records.map(\.id)) == Set([local.id, remote.id]))
    #expect(records.first(where: { $0.id == local.id })?.syncState == .pending)
    #expect(records.first(where: { $0.id == remote.id })?.syncState == .synced)
    #expect(try await store.pendingOperations().map(\.entityId) == [local.id])
    #expect(try await store.syncCursor() == 14)
  }

  @Test func useRemoteSoftDeletesLocalWithoutOutboxAndImportsRemoteUUID() async throws {
    let container = try makeSyncContainer()
    let store = BirthdayStore(modelContainer: container)
    let local = try await store.save(
      localDraft(name: "妈妈"),
      id: UUID(),
      now: snapshotNow,
      timeZone: snapshotTimeZone
    )
    let remote = makeAPIBirthday(
      id: UUID(),
      name: "妈妈",
      version: 5,
      updatedAt: snapshotNow.addingTimeInterval(60)
    )
    let candidate = try #require(
      SnapshotImporter.preview(local: [local], remote: [remote]).duplicates.first
    )

    try await store.applySnapshot(
      SnapshotResponse(cursor: 15, birthdays: [remote]),
      decisions: [candidate.id: .useRemote]
    )

    #expect(try await store.activeBirthdays().map(\.id) == [remote.id])
    #expect(try await store.pendingOperations().isEmpty)
    #expect(try await store.syncCursor() == 15)

    let context = ModelContext(container)
    let all = try context.fetch(FetchDescriptor<BirthdayEntity>())
    let discarded = try #require(all.first(where: { $0.id == local.id }))
    #expect(discarded.deletedAt == remote.updatedAt)
    #expect(discarded.syncStateRaw == SyncState.synced.rawValue)
  }

  @Test func commitFailureRollsBackBirthdaysAndCursor() async throws {
    let container = try makeSyncContainer()
    let recorder = SnapshotCommitRecorder(shouldFail: true)
    let store = BirthdayStore(
      modelContainer: container,
      transactionCommitter: recorder.commit
    )

    await #expect(throws: SnapshotCommitFailure.failed) {
      try await store.applySnapshot(
        SnapshotResponse(cursor: 99, birthdays: [makeAPIBirthday()]),
        decisions: [:]
      )
    }

    #expect(try await store.activeBirthdays().isEmpty)
    #expect(try await store.syncCursor() == 0)
    #expect(recorder.count == 1)
  }
}
