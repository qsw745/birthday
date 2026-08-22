import Foundation
import SwiftData

public enum BirthdayStoreError: Error, Equatable, Sendable {
  case unknownSyncState(String)
}

public actor BirthdayStore: ModelActor {
  private static let primarySyncMetadataKey = "primary"

  nonisolated public let modelContainer: ModelContainer
  nonisolated public let modelExecutor: any ModelExecutor

  private let calculator: any LunarBirthdayCalculating
  private let transactionCommitter: @Sendable (ModelContext) throws -> Void

  public init(modelContainer: ModelContainer) {
    let context = ModelContext(modelContainer)
    self.modelContainer = modelContainer
    modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    calculator = ChineseCalendarBirthdayCalculator()
    transactionCommitter = { context in try context.save() }
  }

  init(
    modelContainer: ModelContainer,
    transactionCommitter: @escaping @Sendable (ModelContext) throws -> Void
  ) {
    let context = ModelContext(modelContainer)
    self.modelContainer = modelContainer
    modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    calculator = ChineseCalendarBirthdayCalculator()
    self.transactionCommitter = transactionCommitter
  }

  public func save(
    _ draft: BirthdayDraft,
    id: UUID?,
    now: Date,
    timeZone: TimeZone
  ) throws -> BirthdayRecord {
    try BirthdayValidator.validate(draft)
    let nextSolarDate = try calculator.nextOccurrence(
      of: draft.lunarBirthday,
      reminderMinutes: draft.reminder.timeMinutes,
      after: now,
      in: timeZone
    )
    let targetID = id ?? UUID()
    let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.id == targetID })

    do {
      let entity: BirthdayEntity
      if let existing = try modelContext.fetch(descriptor).first {
        _ = try requireKnownSyncState(existing.syncStateRaw)
        entity = existing
        apply(draft, nextSolarDate: nextSolarDate, now: now, to: entity)
      } else {
        entity = BirthdayEntity(id: targetID, draft: draft, nextSolarDate: nextSolarDate, now: now)
        modelContext.insert(entity)
      }

      let record = try map(entity)
      try coalesceOperation(
        entityID: targetID,
        operationType: "upsert",
        record: record,
        createdAt: now
      )
      try transactionCommitter(modelContext)
      return record
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func activeBirthdays() throws -> [BirthdayRecord] {
    let descriptor = FetchDescriptor<BirthdayEntity>(
      predicate: #Predicate { $0.deletedAt == nil },
      sortBy: [
        SortDescriptor(\.nextSolarDate),
        SortDescriptor(\.createdAt),
        SortDescriptor(\.id),
      ]
    )
    return try modelContext.fetch(descriptor).map { try map($0) }
  }

  @discardableResult
  public func refreshNextSolarDates(now: Date, timeZone: TimeZone) throws -> Int {
    let descriptor = FetchDescriptor<BirthdayEntity>(
      predicate: #Predicate { $0.deletedAt == nil }
    )

    do {
      let entities = try modelContext.fetch(descriptor)
      var refreshedCount = 0
      for entity in entities {
        _ = try requireKnownSyncState(entity.syncStateRaw)
        let nextSolarDate = try calculator.nextOccurrence(
          of: LunarBirthday(
            month: entity.lunarMonth,
            day: entity.lunarDay,
            isLeapMonth: entity.isLeapMonth
          ),
          reminderMinutes: entity.reminderTimeMinutes,
          after: now,
          in: timeZone
        )
        guard entity.nextSolarDate != nextSolarDate else { continue }
        entity.nextSolarDate = nextSolarDate
        refreshedCount += 1
      }

      if refreshedCount > 0 {
        try transactionCommitter(modelContext)
      }
      return refreshedCount
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func softDelete(id: UUID, now: Date) throws {
    let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.id == id })

    do {
      guard let entity = try modelContext.fetch(descriptor).first else { return }
      _ = try requireKnownSyncState(entity.syncStateRaw)
      entity.deletedAt = now
      entity.updatedAt = now
      entity.syncStateRaw = SyncState.pendingDelete.rawValue
      let record = try map(entity)
      try coalesceOperation(
        entityID: id,
        operationType: "delete",
        record: record,
        createdAt: now
      )
      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func restore(id: UUID, now: Date) throws {
    let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.id == id })

    do {
      guard let entity = try modelContext.fetch(descriptor).first else { return }
      _ = try requireKnownSyncState(entity.syncStateRaw)
      entity.deletedAt = nil
      entity.updatedAt = now
      entity.syncStateRaw = SyncState.pending.rawValue
      let record = try map(entity)
      try coalesceOperation(
        entityID: id,
        operationType: "upsert",
        record: record,
        createdAt: now
      )
      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func pendingOperations() throws -> [SyncOperation] {
    let descriptor = FetchDescriptor<SyncOperationEntity>(
      sortBy: [
        SortDescriptor(\.createdAt),
        SortDescriptor(\.operationId),
      ]
    )
    return try modelContext.fetch(descriptor).map(map)
  }

  public func syncCursor() throws -> Int64 {
    let key = Self.primarySyncMetadataKey
    let descriptor = FetchDescriptor<SyncMetadataEntity>(
      predicate: #Predicate { $0.key == key }
    )
    return try modelContext.fetch(descriptor).first?.cursor ?? 0
  }

  public func applySnapshot(
    _ snapshot: SnapshotResponse,
    decisions: [DuplicateCandidate.ID: DuplicateDecision]
  ) throws {
    do {
      try validateSnapshot(snapshot)
      let birthdayEntities = try modelContext.fetch(FetchDescriptor<BirthdayEntity>())
      let operationEntities = try modelContext.fetch(FetchDescriptor<SyncOperationEntity>())
      let localRecords = try birthdayEntities.map(map)
      let preview = SnapshotImporter.preview(local: localRecords, remote: snapshot.birthdays)
      guard preview.duplicates.allSatisfy({ decisions[$0.id] != nil }) else {
        throw SnapshotImportError.missingDuplicateDecision
      }

      let pendingIDs = try pendingEntityIDs(
        birthdays: birthdayEntities,
        operations: operationEntities
      )
      let discardedLocalIDs = Set(
        preview.duplicates.compactMap { candidate in
          decisions[candidate.id] == .useRemote ? candidate.local.id : nil
        }
      )

      for localID in discardedLocalIDs {
        guard let entity = birthdayEntities.first(where: { $0.id == localID }) else { continue }
        let matchingRemote = preview.duplicates.first {
          $0.local.id == localID && decisions[$0.id] == .useRemote
        }?.remote
        let discardedAt = max(entity.updatedAt, matchingRemote?.updatedAt ?? entity.updatedAt)
        entity.deletedAt = discardedAt
        entity.updatedAt = discardedAt
        entity.syncStateRaw = SyncState.synced.rawValue
        for operation in operationEntities where operation.entityId == localID {
          modelContext.delete(operation)
        }
      }

      for remote in snapshot.birthdays {
        guard !pendingIDs.contains(remote.id) else { continue }

        if let existing = birthdayEntities.first(where: { $0.id == remote.id }) {
          apply(remote, to: existing)
        } else {
          modelContext.insert(makeEntity(remote))
        }
      }

      let key = Self.primarySyncMetadataKey
      let metadataDescriptor = FetchDescriptor<SyncMetadataEntity>(
        predicate: #Predicate { $0.key == key }
      )
      if let metadata = try modelContext.fetch(metadataDescriptor).first {
        metadata.cursor = snapshot.cursor
      } else {
        modelContext.insert(SyncMetadataEntity(key: key, cursor: snapshot.cursor))
      }

      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  private func validateSnapshot(_ snapshot: SnapshotResponse) throws {
    var remoteIDs = Set<UUID>()
    for remote in snapshot.birthdays {
      guard remoteIDs.insert(remote.id).inserted else {
        throw SnapshotImportError.duplicateRemoteID(remote.id)
      }
      try BirthdayValidator.validate(
        BirthdayDraft(
          name: remote.name,
          lunarBirthday: LunarBirthday(
            month: remote.lunarMonth,
            day: remote.lunarDay,
            isLeapMonth: remote.isLeapMonth
          ),
          reminder: remote.reminder
        )
      )
    }
  }

  private func pendingEntityIDs(
    birthdays: [BirthdayEntity],
    operations: [SyncOperationEntity]
  ) throws -> Set<UUID> {
    var pending = Set(operations.map(\.entityId))
    for birthday in birthdays {
      let state = try requireKnownSyncState(birthday.syncStateRaw)
      if state != .synced {
        pending.insert(birthday.id)
      }
    }
    return pending
  }

  private func makeEntity(_ remote: APIBirthday) -> BirthdayEntity {
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
    apply(remote, to: entity)
    return entity
  }

  private func apply(_ remote: APIBirthday, to entity: BirthdayEntity) {
    entity.name = remote.name.trimmingCharacters(in: .whitespacesAndNewlines)
    entity.lunarMonth = remote.lunarMonth
    entity.lunarDay = remote.lunarDay
    entity.isLeapMonth = remote.isLeapMonth
    entity.reminderTimeMinutes = remote.reminder.timeMinutes
    entity.notifyDayBefore = remote.reminder.notifyDayBefore
    entity.notifySameDay = remote.reminder.notifySameDay
    entity.emailEnabled = remote.reminder.emailEnabled
    entity.emailAddress = remote.reminder.emailAddress
    entity.emailMessage = remote.reminder.emailMessage
    entity.nextSolarDate = remote.nextSolarDate
    entity.version = remote.version
    entity.createdAt = remote.createdAt
    entity.updatedAt = remote.updatedAt
    entity.deletedAt = remote.deletedAt
    entity.syncStateRaw = SyncState.synced.rawValue
  }

  private func apply(
    _ draft: BirthdayDraft, nextSolarDate: Date, now: Date, to entity: BirthdayEntity
  ) {
    entity.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    entity.lunarMonth = draft.lunarBirthday.month
    entity.lunarDay = draft.lunarBirthday.day
    entity.isLeapMonth = draft.lunarBirthday.isLeapMonth
    entity.reminderTimeMinutes = draft.reminder.timeMinutes
    entity.notifyDayBefore = draft.reminder.notifyDayBefore
    entity.notifySameDay = draft.reminder.notifySameDay
    entity.emailEnabled = draft.reminder.emailEnabled
    entity.emailAddress = draft.reminder.emailAddress
    entity.emailMessage = draft.reminder.emailMessage
    entity.nextSolarDate = nextSolarDate
    entity.updatedAt = now
    entity.deletedAt = nil
    entity.syncStateRaw = SyncState.pending.rawValue
  }

  private func coalesceOperation(
    entityID: UUID,
    operationType: String,
    record: BirthdayRecord,
    createdAt: Date
  ) throws {
    let descriptor = FetchDescriptor<SyncOperationEntity>(
      predicate: #Predicate { $0.entityId == entityID },
      sortBy: [
        SortDescriptor(\.createdAt),
        SortDescriptor(\.operationId),
      ]
    )
    let existing = try modelContext.fetch(descriptor)

    if operationType == "delete", record.version == 0,
      existing.contains(where: { $0.operationType == "upsert" && $0.baseVersion == 0 })
    {
      for operation in existing { modelContext.delete(operation) }
      return
    }

    let payloadJSON = try JSONEncoder().encode(BirthdayOutboxPayload(record: record))
    if let keeper = existing.first {
      keeper.operationType = operationType
      keeper.baseVersion = record.version
      keeper.payloadJSON = payloadJSON
      keeper.attemptCount = 0
      keeper.nextRetryAt = nil
      keeper.lastErrorCategory = nil
      for duplicate in existing.dropFirst() { modelContext.delete(duplicate) }
      return
    }

    modelContext.insert(
      SyncOperationEntity(
        operationId: UUID(),
        entityId: entityID,
        operationType: operationType,
        baseVersion: record.version,
        payloadJSON: payloadJSON,
        createdAt: createdAt,
        attemptCount: 0,
        nextRetryAt: nil,
        lastErrorCategory: nil
      ))
  }

  private func map(_ entity: BirthdayEntity) throws -> BirthdayRecord {
    BirthdayRecord(
      id: entity.id,
      name: entity.name,
      lunarBirthday: LunarBirthday(
        month: entity.lunarMonth,
        day: entity.lunarDay,
        isLeapMonth: entity.isLeapMonth
      ),
      reminder: ReminderConfig(
        timeMinutes: entity.reminderTimeMinutes,
        notifyDayBefore: entity.notifyDayBefore,
        notifySameDay: entity.notifySameDay,
        emailEnabled: entity.emailEnabled,
        emailAddress: entity.emailAddress,
        emailMessage: entity.emailMessage
      ),
      nextSolarDate: entity.nextSolarDate,
      version: entity.version,
      createdAt: entity.createdAt,
      updatedAt: entity.updatedAt,
      deletedAt: entity.deletedAt,
      syncState: try requireKnownSyncState(entity.syncStateRaw)
    )
  }

  private func requireKnownSyncState(_ rawValue: String) throws -> SyncState {
    guard let syncState = SyncState(rawValue: rawValue) else {
      throw BirthdayStoreError.unknownSyncState(rawValue)
    }
    return syncState
  }

  private func map(_ entity: SyncOperationEntity) -> SyncOperation {
    SyncOperation(
      operationId: entity.operationId,
      entityId: entity.entityId,
      operationType: entity.operationType,
      baseVersion: entity.baseVersion,
      payloadJSON: entity.payloadJSON,
      createdAt: entity.createdAt,
      attemptCount: entity.attemptCount,
      nextRetryAt: entity.nextRetryAt,
      lastErrorCategory: entity.lastErrorCategory
    )
  }
}
