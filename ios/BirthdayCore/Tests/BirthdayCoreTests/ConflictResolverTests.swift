import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

@Suite(.serialized)
struct ConflictResolverTests {
  private let freshOperationID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  private let resolutionDate = Date(timeIntervalSince1970: 1_700_001_000)
  private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

  @Test func snapshotEnvelopeIsVersionedCompleteAndLegacyLossless() throws {
    let record = makeAPIBirthday(
      id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
      name: "完整快照",
      month: 12,
      day: 29,
      isLeapMonth: true,
      reminder: ReminderConfig(
        timeMinutes: 1_439,
        notifyDayBefore: false,
        notifySameDay: true,
        emailEnabled: true,
        emailAddress: "full@example.com",
        emailMessage: "完整邮件正文"
      ),
      nextSolarDate: Date(timeIntervalSince1970: 1_800_000_000),
      version: 9,
      createdAt: Date(timeIntervalSince1970: 1_600_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let encoded = try SyncConflictSnapshot.encode(record, side: .local)
    let decoded = try SyncConflictSnapshot.decode(encoded, expectedSide: .local)
    #expect(decoded.formatVersion == SyncConflictSnapshot.currentFormatVersion)
    #expect(decoded.side == .local)
    #expect(decoded.record == record)

    let legacy = try MobileJSON.encoder.encode(record)
    let decodedLegacy = try SyncConflictSnapshot.decode(legacy, expectedSide: .remote)
    #expect(decodedLegacy.formatVersion == 0)
    #expect(decodedLegacy.side == .remote)
    #expect(decodedLegacy.record == record)
  }

  @Test func snapshotDecoderRejectsUnknownWrongSideAndMalformedEnvelopes() throws {
    let record = makeAPIBirthday()
    let valid = try SyncConflictSnapshot.encode(record, side: .local)
    var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    object["formatVersion"] = 2
    let unknownVersion = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: SyncConflictSnapshotError.unsupportedFormatVersion(2)) {
      try SyncConflictSnapshot.decode(unknownVersion, expectedSide: .local)
    }
    #expect(throws: SyncConflictSnapshotError.unexpectedSide(expected: .remote, actual: .local)) {
      try SyncConflictSnapshot.decode(valid, expectedSide: .remote)
    }
    #expect(throws: SyncConflictSnapshotError.malformedSnapshot) {
      try SyncConflictSnapshot.decode(Data("{}".utf8), expectedSide: .local)
    }
  }

  @Test func realTask5ConflictWithLocalDefaultsListsAndResolvesBothChoices() async throws {
    for choice in ResolutionChoice.allCases {
      let store = try makeSyncStore()
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      let local = try await store.save(
        BirthdayDraft(
          name: "真实本机",
          lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
          reminder: .defaults
        ),
        id: UUID(),
        now: now,
        timeZone: timeZone
      )
      let operation = try #require(try await store.readyOperations(limit: 1, now: now).first)
      let remote = makeAPIBirthday(
        id: local.id,
        name: "真实云端",
        version: 5,
        updatedAt: now.addingTimeInterval(60)
      )
      try await store.applyPushResults(
        [
          PushResult(
            operationId: operation.operationId,
            status: .conflict,
            record: nil,
            remote: remote
          )
        ],
        expectedOperationIDs: [operation.operationId],
        now: now,
        timeZone: timeZone
      )

      let resolver = makeResolver(store)
      let listed = try await resolver.conflicts()
      let conflict = try #require(listed.first)
      #expect(listed.count == 1)
      #expect(conflict.local.reminder.emailEnabled == false)
      #expect(conflict.local.reminder.emailMessage == ReminderConfig.defaults.emailMessage)

      switch choice {
      case .keepLocal:
        try await resolver.keepLocal(id: local.id)
        let current = try #require(try await store.activeBirthdays().first)
        let replacement = try #require(try await store.pendingOperations().first)
        #expect(current.name == "真实本机")
        #expect(current.reminder == .defaults)
        #expect(replacement.operationId == freshOperationID)
        #expect(replacement.operationId != operation.operationId)
        #expect(replacement.baseVersion == remote.version)
      case .useRemote:
        try await resolver.useRemote(id: local.id)
        let current = try #require(try await store.activeBirthdays().first)
        #expect(current.id == remote.id)
        #expect(current.name == remote.name)
        #expect(current.lunarBirthday.month == remote.lunarMonth)
        #expect(current.lunarBirthday.day == remote.lunarDay)
        #expect(current.lunarBirthday.isLeapMonth == remote.isLeapMonth)
        #expect(current.reminder == remote.reminder)
        #expect(current.nextSolarDate != nil)
        #expect(current.version == remote.version)
        #expect(current.createdAt == remote.createdAt)
        #expect(current.updatedAt == remote.updatedAt)
        #expect(current.deletedAt == remote.deletedAt)
        #expect(current.syncState == .synced)
        #expect(try await store.pendingOperations().isEmpty)
      }
      #expect(try await store.syncConflicts().isEmpty)
    }
  }

  @Test func keepLocalCreatesFreshOperationOnRemoteVersion() async throws {
    let fixture = try makeConflictFixture()
    try await makeResolver(fixture.store).keepLocal(id: fixture.birthdayId)

    let operations = try await fixture.store.pendingOperations()
    let operation = try #require(operations.first)
    let current = try #require(try await fixture.store.activeBirthdays().first)
    #expect(operations.count == 1)
    #expect(operation.operationId == freshOperationID)
    #expect(operation.operationId != fixture.operationId)
    #expect(operation.entityId == fixture.birthdayId)
    #expect(operation.baseVersion == fixture.remote.version)
    #expect(operation.operationType == "upsert")
    #expect(operation.lastErrorCategory == nil)
    #expect(
      try MobileJSON.decoder.decode(BirthdayPayloadDTO.self, from: operation.payloadJSON)
        == BirthdayPayloadDTO(record: current)
    )
    let submission = try PushOperationDTO(operation)
    #expect(submission.operationId == freshOperationID)
    #expect(submission.entityId == fixture.birthdayId)
    #expect(submission.baseVersion == fixture.remote.version)
    #expect(current.version == fixture.remote.version)
    #expect(current.syncState == .pending)
    #expect(try await fixture.store.syncConflicts().isEmpty)
  }

  @Test func keepLocalRestoresEditAgainstRemoteTombstoneVersion() async throws {
    let fixture = try makeConflictFixture(remoteVersion: 8, remoteDeleted: true)
    try await makeResolver(fixture.store).keepLocal(id: fixture.birthdayId)

    let current = try #require(try await fixture.store.activeBirthdays().first)
    let operation = try #require(try await fixture.store.pendingOperations().first)
    #expect(current.name == fixture.local.name)
    #expect(current.deletedAt == nil)
    #expect(current.version == 8)
    #expect(operation.operationType == "upsert")
    #expect(operation.baseVersion == 8)
    #expect(operation.operationId == freshOperationID)
    #expect(try await fixture.store.syncConflicts().isEmpty)
  }

  @Test func useRemoteReplacesEveryLocalFieldAndClearsConflictOperation() async throws {
    let fixture = try makeConflictFixture()
    try await makeResolver(fixture.store).useRemote(id: fixture.birthdayId)

    let current = try #require(try await fixture.store.activeBirthdays().first)
    #expect(current == fixture.remote.asRecord(syncState: .synced))
    #expect(try await fixture.store.pendingOperations().isEmpty)
    #expect(try await fixture.store.syncConflicts().isEmpty)
  }

  @Test func useRemoteTombstoneReplacesFieldsAndHidesBirthday() async throws {
    let fixture = try makeConflictFixture(remoteVersion: 8, remoteDeleted: true)
    try await makeResolver(fixture.store).useRemote(id: fixture.birthdayId)

    #expect(try await fixture.store.activeBirthdays().isEmpty)
    #expect(try await fixture.store.pendingOperations().isEmpty)
    #expect(try await fixture.store.syncConflicts().isEmpty)
    let context = ModelContext(fixture.container)
    let entity = try #require(try context.fetch(FetchDescriptor<BirthdayEntity>()).first)
    #expect(entity.name == fixture.remote.name)
    #expect(entity.lunarMonth == fixture.remote.lunarMonth)
    #expect(entity.lunarDay == fixture.remote.lunarDay)
    #expect(entity.isLeapMonth == fixture.remote.isLeapMonth)
    #expect(entity.reminderTimeMinutes == fixture.remote.reminder.timeMinutes)
    #expect(entity.notifyDayBefore == fixture.remote.reminder.notifyDayBefore)
    #expect(entity.notifySameDay == fixture.remote.reminder.notifySameDay)
    #expect(entity.emailEnabled == fixture.remote.reminder.emailEnabled)
    #expect(entity.emailAddress == fixture.remote.reminder.emailAddress)
    #expect(entity.emailMessage == fixture.remote.reminder.emailMessage)
    #expect(entity.nextSolarDate == fixture.remote.nextSolarDate)
    #expect(entity.version == fixture.remote.version)
    #expect(entity.createdAt == fixture.remote.createdAt)
    #expect(entity.updatedAt == fixture.remote.updatedAt)
    #expect(entity.deletedAt == fixture.remote.deletedAt)
    #expect(entity.syncStateRaw == SyncState.synced.rawValue)
  }

  @Test func missingOrMismatchedConflictRelationsFailWithoutWrites() async throws {
    for corruption in RelationCorruption.allCases {
      let fixture = try makeConflictFixture()
      let context = ModelContext(fixture.container)
      switch corruption {
      case .missingBirthday:
        let birthday = try #require(try context.fetch(FetchDescriptor<BirthdayEntity>()).first)
        context.delete(birthday)
      case .missingOperation:
        let operation = try #require(
          try context.fetch(FetchDescriptor<SyncOperationEntity>()).first)
        context.delete(operation)
      case .missingAssociation:
        let conflict = try #require(
          try context.fetch(FetchDescriptor<SyncConflictEntity>()).first)
        conflict.operationId = nil
      case .mismatchedOperation:
        let operation = try #require(
          try context.fetch(FetchDescriptor<SyncOperationEntity>()).first)
        operation.entityId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
      case .duplicateOperation:
        let operation = try #require(
          try context.fetch(FetchDescriptor<SyncOperationEntity>()).first)
        context.insert(
          SyncOperationEntity(
            operationId: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
            entityId: operation.entityId,
            operationType: operation.operationType,
            baseVersion: operation.baseVersion,
            payloadJSON: operation.payloadJSON,
            createdAt: operation.createdAt,
            attemptCount: operation.attemptCount,
            nextRetryAt: operation.nextRetryAt,
            lastErrorCategory: operation.lastErrorCategory
          ))
      }
      try context.save()

      await #expect(throws: ConflictResolutionError.self) {
        try await makeResolver(fixture.store).keepLocal(id: fixture.birthdayId)
      }
      #expect(try await fixture.store.syncConflicts().count == 1)
      #expect(
        try await fixture.store.pendingOperations().contains {
          $0.operationId == fixture.operationId
        } == (corruption != .missingOperation)
      )
    }
  }

  @Test func missingConflictFailsWithoutTouchingBirthdayOrOperation() async throws {
    let fixture = try makeConflictFixture()
    let context = ModelContext(fixture.container)
    let conflict = try #require(
      try context.fetch(FetchDescriptor<SyncConflictEntity>()).first)
    context.delete(conflict)
    try context.save()

    await #expect(throws: ConflictResolutionError.conflictNotFound) {
      try await makeResolver(fixture.store).keepLocal(id: fixture.birthdayId)
    }
    let birthday = try #require(try await fixture.store.activeBirthdays().first)
    #expect(birthday == fixture.local.asRecord(syncState: .conflict))
    #expect(try await fixture.store.pendingOperations().map(\.operationId) == [fixture.operationId])
  }

  @Test func ordinarySaveAndDeleteCannotUnblockAConflictOperation() async throws {
    for mutation in ConflictMutation.allCases {
      let fixture = try makeConflictFixture()
      let original = try #require(try await fixture.store.activeBirthdays().first)

      await #expect(throws: BirthdayStoreError.conflictRequiresResolution) {
        switch mutation {
        case .save:
          _ = try await fixture.store.save(
            BirthdayDraft(
              name: "绕过冲突的编辑",
              lunarBirthday: original.lunarBirthday,
              reminder: original.reminder
            ),
            id: fixture.birthdayId,
            now: resolutionDate,
            timeZone: timeZone
          )
        case .delete:
          try await fixture.store.softDelete(id: fixture.birthdayId, now: resolutionDate)
        }
      }

      #expect(try await fixture.store.activeBirthdays().first == original)
      let operation = try #require(try await fixture.store.pendingOperations().first)
      #expect(operation.operationId == fixture.operationId)
      #expect(operation.lastErrorCategory == "conflict_blocked")
      #expect(try await fixture.store.readyOperations(limit: 1, now: resolutionDate).isEmpty)
      #expect(try await fixture.store.syncConflicts().count == 1)
    }
  }

  @Test func legacyEditAndDeleteConflictsResolveBothChoicesEndToEnd() async throws {
    for remoteDeleted in [false, true] {
      for choice in ResolutionChoice.allCases {
        let fixture = try makeConflictFixture(remoteDeleted: remoteDeleted)
        let context = ModelContext(fixture.container)
        let conflict = try #require(
          try context.fetch(FetchDescriptor<SyncConflictEntity>()).first)
        conflict.localSnapshotJSON = try MobileJSON.encoder.encode(fixture.local)
        conflict.remoteSnapshotJSON = try MobileJSON.encoder.encode(fixture.remote)
        conflict.kindRaw = SyncConflictKind.editEdit.rawValue
        try context.save()

        let resolver = makeResolver(fixture.store)
        let listed = try await resolver.conflicts()
        #expect(listed.first?.kind == (remoteDeleted ? .deleteEdit : .editEdit))

        switch choice {
        case .keepLocal:
          try await resolver.keepLocal(id: fixture.birthdayId)
          let replacement = try #require(try await fixture.store.pendingOperations().first)
          #expect(replacement.operationId == freshOperationID)
          #expect(replacement.operationId != fixture.operationId)
          #expect(replacement.baseVersion == fixture.remote.version)
        case .useRemote:
          try await resolver.useRemote(id: fixture.birthdayId)
          #expect(try await fixture.store.pendingOperations().isEmpty)
          #expect(
            try await fixture.store.activeBirthdays().isEmpty
              == remoteDeleted
          )
        }
        #expect(try await fixture.store.syncConflicts().isEmpty)
      }
    }
  }

  @Test func v1RemoteTombstoneStillRequiresExplicitDeleteEditKind() async throws {
    let fixture = try makeConflictFixture(remoteDeleted: true)
    let context = ModelContext(fixture.container)
    let conflict = try #require(
      try context.fetch(FetchDescriptor<SyncConflictEntity>()).first)
    conflict.kindRaw = SyncConflictKind.editEdit.rawValue
    try context.save()

    await #expect(throws: ConflictResolutionError.unsupportedConflictShape) {
      try await makeResolver(fixture.store).useRemote(id: fixture.birthdayId)
    }
    #expect(try await fixture.store.pendingOperations().map(\.operationId) == [fixture.operationId])
    #expect(try await fixture.store.syncConflicts().count == 1)
  }

  @Test func malformedSnapshotAndUnsupportedReverseShapeFailWithZeroWrites() async throws {
    let malformed = try makeConflictFixture()
    let malformedContext = ModelContext(malformed.container)
    let conflict = try #require(
      try malformedContext.fetch(FetchDescriptor<SyncConflictEntity>()).first)
    conflict.remoteSnapshotJSON = Data("{\"formatVersion\":1}".utf8)
    try malformedContext.save()

    await #expect(throws: ConflictResolutionError.invalidSnapshot) {
      try await makeResolver(malformed.store).useRemote(id: malformed.birthdayId)
    }
    #expect(
      try await malformed.store.pendingOperations().map(\.operationId) == [malformed.operationId])
    #expect(try await malformed.store.syncConflicts().count == 1)

    let reverse = try makeConflictFixture(localDeleted: true)
    await #expect(throws: ConflictResolutionError.unsupportedConflictShape) {
      try await makeResolver(reverse.store).keepLocal(id: reverse.birthdayId)
    }
    #expect(try await reverse.store.pendingOperations().map(\.operationId) == [reverse.operationId])
    #expect(try await reverse.store.syncConflicts().count == 1)
  }

  @Test func failedCommitRollsBackEitherResolutionCompletely() async throws {
    for choice in ResolutionChoice.allCases {
      let fixture = try makeConflictFixture(remoteDeleted: choice == .useRemote)
      let failingStore = BirthdayStore(
        modelContainer: fixture.container,
        transactionCommitter: { _ in throw ConflictCommitFailure.expected }
      )
      let resolver = makeResolver(failingStore)

      await #expect(throws: ConflictCommitFailure.expected) {
        switch choice {
        case .keepLocal:
          try await resolver.keepLocal(id: fixture.birthdayId)
        case .useRemote:
          try await resolver.useRemote(id: fixture.birthdayId)
        }
      }

      let fresh = BirthdayStore(modelContainer: fixture.container)
      let local = try #require(try await fresh.activeBirthdays().first)
      #expect(local.name == fixture.local.name)
      #expect(local.version == fixture.local.version)
      #expect(local.syncState == .conflict)
      #expect(try await fresh.pendingOperations().map(\.operationId) == [fixture.operationId])
      #expect(try await fresh.syncConflicts().count == 1)
    }
  }

  private func makeResolver(_ store: BirthdayStore) -> ConflictResolver {
    ConflictResolver(
      store: store,
      makeOperationID: { freshOperationID },
      now: { resolutionDate },
      timeZone: { timeZone }
    )
  }
}

private enum RelationCorruption: CaseIterable {
  case missingBirthday
  case missingOperation
  case missingAssociation
  case mismatchedOperation
  case duplicateOperation
}

private enum ResolutionChoice: CaseIterable {
  case keepLocal
  case useRemote
}

private enum ConflictMutation: CaseIterable {
  case save
  case delete
}

private enum ConflictCommitFailure: Error {
  case expected
}
