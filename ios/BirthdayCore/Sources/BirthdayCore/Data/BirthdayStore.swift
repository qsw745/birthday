import Foundation
import SwiftData

@ModelActor
public actor BirthdayStore {
  private let calculator: any LunarBirthdayCalculating = ChineseCalendarBirthdayCalculator()

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
        entity = existing
        apply(draft, nextSolarDate: nextSolarDate, now: now, to: entity)
      } else {
        entity = BirthdayEntity(id: targetID, draft: draft, nextSolarDate: nextSolarDate, now: now)
        modelContext.insert(entity)
      }

      let record = map(entity)
      modelContext.insert(
        try makeOperation(
          entityID: targetID,
          operationType: "upsert",
          record: record,
          createdAt: now
        ))
      try modelContext.save()
      return record
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func activeBirthdays() -> [BirthdayRecord] {
    let descriptor = FetchDescriptor<BirthdayEntity>(
      predicate: #Predicate { $0.deletedAt == nil },
      sortBy: [
        SortDescriptor(\.nextSolarDate),
        SortDescriptor(\.createdAt),
        SortDescriptor(\.id),
      ]
    )
    return (try? modelContext.fetch(descriptor).map(map)) ?? []
  }

  public func softDelete(id: UUID, now: Date) throws {
    let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.id == id })

    do {
      guard let entity = try modelContext.fetch(descriptor).first else { return }
      entity.deletedAt = now
      entity.updatedAt = now
      entity.syncStateRaw = SyncState.pendingDelete.rawValue
      let record = map(entity)
      modelContext.insert(
        try makeOperation(
          entityID: id,
          operationType: "delete",
          record: record,
          createdAt: now
        ))
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func restore(id: UUID, now: Date) throws {
    let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.id == id })

    do {
      guard let entity = try modelContext.fetch(descriptor).first else { return }
      entity.deletedAt = nil
      entity.updatedAt = now
      entity.syncStateRaw = SyncState.pending.rawValue
      let record = map(entity)
      modelContext.insert(
        try makeOperation(
          entityID: id,
          operationType: "upsert",
          record: record,
          createdAt: now
        ))
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func pendingOperations() -> [SyncOperation] {
    let descriptor = FetchDescriptor<SyncOperationEntity>(
      sortBy: [
        SortDescriptor(\.createdAt),
        SortDescriptor(\.operationId),
      ]
    )
    return (try? modelContext.fetch(descriptor).map(map)) ?? []
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

  private func makeOperation(
    entityID: UUID,
    operationType: String,
    record: BirthdayRecord,
    createdAt: Date
  ) throws -> SyncOperationEntity {
    let payloadJSON = try JSONEncoder().encode(record)
    return SyncOperationEntity(
      operationId: UUID(),
      entityId: entityID,
      operationType: operationType,
      baseVersion: record.version,
      payloadJSON: payloadJSON,
      createdAt: createdAt,
      attemptCount: 0,
      nextRetryAt: nil,
      lastErrorCategory: nil
    )
  }

  private func map(_ entity: BirthdayEntity) -> BirthdayRecord {
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
      syncState: SyncState(rawValue: entity.syncStateRaw) ?? .pending
    )
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
