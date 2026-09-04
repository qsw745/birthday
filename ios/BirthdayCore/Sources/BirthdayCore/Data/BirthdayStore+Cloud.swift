import Foundation
import SwiftData

public enum CloudSyncStoreError: Error, Equatable, Sendable {
  case missingBirthday
  case missingCloudState
  case conflictNotFound
  case invalidStoredSnapshot
  case duplicateRemoteEntity
}

public struct CloudPendingChange: Equatable, Sendable {
  public let snapshot: CloudBirthdaySnapshot
  public let encodedSystemFields: Data?
  public let mutationID: UUID
  public let lastErrorCategory: String?
}

public struct CloudRemoteChange: Equatable, Sendable {
  public let snapshot: CloudBirthdaySnapshot
  public let encodedSystemFields: Data

  public init(snapshot: CloudBirthdaySnapshot, encodedSystemFields: Data) {
    self.snapshot = snapshot
    self.encodedSystemFields = encodedSystemFields
  }
}

public struct CloudUploadSuccess: Equatable, Sendable {
  public let entityID: UUID
  public let mutationID: UUID
  public let uploadedSnapshot: CloudBirthdaySnapshot
  public let encodedSystemFields: Data

  public init(
    entityID: UUID,
    mutationID: UUID,
    uploadedSnapshot: CloudBirthdaySnapshot,
    encodedSystemFields: Data
  ) {
    self.entityID = entityID
    self.mutationID = mutationID
    self.uploadedSnapshot = uploadedSnapshot
    self.encodedSystemFields = encodedSystemFields
  }
}

public struct CloudConflictRecord: Equatable, Sendable {
  public let entityID: UUID
  public let local: CloudBirthdaySnapshot
  public let iCloud: CloudBirthdaySnapshot
  public let kind: CloudSyncConflictKind
  public let createdAt: Date
  public let updatedAt: Date
}

public struct CloudEngineStateRecord: Equatable, Sendable {
  public let serializedState: Data?
  public let initialMergeCompleted: Bool
  public let lastSuccessfulFetchAt: Date?
}

extension BirthdayStore {
  public func bootstrapCloudState() throws {
    do {
      let birthdays = try modelContext.fetch(FetchDescriptor<BirthdayEntity>())
      let states = try modelContext.fetch(FetchDescriptor<CloudRecordStateEntity>())
      let existingIDs = Set(states.map(\.entityId))
      var inserted = false
      for birthday in birthdays where !existingIDs.contains(birthday.id) {
        modelContext.insert(
          CloudRecordStateEntity(
            entityId: birthday.id,
            needsUpload: true,
            lastMutationID: UUID()
          )
        )
        inserted = true
      }
      if inserted { try transactionCommitter(modelContext) }
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func pendingCloudChanges(limit: Int) throws -> [CloudPendingChange] {
    guard limit > 0 else { return [] }
    let states = try modelContext.fetch(
      FetchDescriptor<CloudRecordStateEntity>(predicate: #Predicate { $0.needsUpload })
    )
    let birthdays = try modelContext.fetch(FetchDescriptor<BirthdayEntity>())
    let birthdaysByID = Dictionary(uniqueKeysWithValues: birthdays.map { ($0.id, $0) })
    return try states.compactMap { state in
      guard let mutationID = state.lastMutationID else { return nil }
      guard let birthday = birthdaysByID[state.entityId] else {
        throw CloudSyncStoreError.missingBirthday
      }
      return CloudPendingChange(
        snapshot: try cloudSnapshot(from: birthday),
        encodedSystemFields: state.encodedSystemFields,
        mutationID: mutationID,
        lastErrorCategory: state.lastErrorCategory
      )
    }
    .sorted {
      if $0.snapshot.updatedAt != $1.snapshot.updatedAt {
        return $0.snapshot.updatedAt < $1.snapshot.updatedAt
      }
      return $0.snapshot.id.uuidString < $1.snapshot.id.uuidString
    }
    .prefix(limit)
    .map { $0 }
  }

  public func applyRemoteCloudChanges(
    _ changes: [CloudRemoteChange],
    now: Date,
    timeZone: TimeZone
  ) throws {
    let identifiers = changes.map(\.snapshot.id)
    guard Set(identifiers).count == identifiers.count else {
      throw CloudSyncStoreError.duplicateRemoteEntity
    }

    do {
      for change in changes {
        try applyRemoteCloudChange(change, now: now, timeZone: timeZone)
      }
      if !changes.isEmpty { try transactionCommitter(modelContext) }
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func restageCloudRecordsDeletedRemotely(_ entityIDs: [UUID]) throws {
    do {
      var changed = false
      for entityID in Set(entityIDs) {
        guard let birthday = try birthday(id: entityID) else { continue }
        try stageLocalCloudChange(for: birthday)
        let state = try requireCloudState(id: entityID)
        state.encodedSystemFields = nil
        changed = true
      }
      if changed { try transactionCommitter(modelContext) }
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func resetCloudStateForAccountChange() throws {
    do {
      let birthdays = try modelContext.fetch(FetchDescriptor<BirthdayEntity>())
      let states = try modelContext.fetch(FetchDescriptor<CloudRecordStateEntity>())
      let birthdaysByID = Dictionary(uniqueKeysWithValues: birthdays.map { ($0.id, $0) })
      var statesByID = Dictionary(uniqueKeysWithValues: states.map { ($0.entityId, $0) })

      for state in states where birthdaysByID[state.entityId] == nil {
        modelContext.delete(state)
        statesByID.removeValue(forKey: state.entityId)
      }
      for birthday in birthdays {
        let state = statesByID[birthday.id] ?? CloudRecordStateEntity(entityId: birthday.id)
        if statesByID[birthday.id] == nil { modelContext.insert(state) }
        state.baseSnapshotJSON = nil
        state.encodedSystemFields = nil
        state.needsUpload = true
        state.lastMutationID = UUID()
        state.lastErrorCategory = nil
      }
      for conflict in try modelContext.fetch(FetchDescriptor<CloudSyncConflictEntity>()) {
        modelContext.delete(conflict)
      }
      let engineState = try loadOrCreateEngineState()
      engineState.serializedState = nil
      engineState.initialMergeCompleted = false
      engineState.lastSuccessfulFetchAt = nil
      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func markCloudUploadSucceeded(_ success: CloudUploadSuccess) throws {
    do {
      let state = try requireCloudState(id: success.entityID)
      state.baseSnapshotJSON = try encodeCloudSnapshot(success.uploadedSnapshot)
      state.encodedSystemFields = success.encodedSystemFields
      state.lastErrorCategory = nil
      if state.lastMutationID == success.mutationID {
        state.needsUpload = false
        state.lastMutationID = nil
      }
      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func recordCloudUploadFailure(
    _ change: CloudPendingChange,
    category: String
  ) throws {
    do {
      let state = try requireCloudState(id: change.snapshot.id)
      if state.lastMutationID == change.mutationID {
        state.lastErrorCategory = category
      }
      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func persistCloudEngineState(_ serializedState: Data?) throws {
    do {
      let state = try loadOrCreateEngineState()
      state.serializedState = serializedState
      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func cloudEngineState() throws -> CloudEngineStateRecord {
    let descriptor = FetchDescriptor<CloudSyncEngineStateEntity>(
      predicate: #Predicate { $0.key == "primary" }
    )
    guard let state = try modelContext.fetch(descriptor).first else {
      return CloudEngineStateRecord(
        serializedState: nil,
        initialMergeCompleted: false,
        lastSuccessfulFetchAt: nil
      )
    }
    return CloudEngineStateRecord(
      serializedState: state.serializedState,
      initialMergeCompleted: state.initialMergeCompleted,
      lastSuccessfulFetchAt: state.lastSuccessfulFetchAt
    )
  }

  public func markCloudInitialMergeCompleted(at date: Date) throws {
    do {
      let state = try loadOrCreateEngineState()
      state.initialMergeCompleted = true
      state.lastSuccessfulFetchAt = date
      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func cloudConflicts() throws -> [CloudConflictRecord] {
    try modelContext.fetch(
      FetchDescriptor<CloudSyncConflictEntity>(
        sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.entityId)]
      )
    ).map { entity in
      guard let kind = CloudSyncConflictKind(rawValue: entity.kindRaw) else {
        throw CloudSyncStoreError.invalidStoredSnapshot
      }
      return CloudConflictRecord(
        entityID: entity.entityId,
        local: try decodeCloudSnapshot(entity.localSnapshotJSON),
        iCloud: try decodeCloudSnapshot(entity.iCloudSnapshotJSON),
        kind: kind,
        createdAt: entity.createdAt,
        updatedAt: entity.updatedAt
      )
    }
  }

  public func resolveCloudConflictKeepingLocal(id: UUID, now: Date) throws {
    do {
      let conflict = try requireCloudConflict(id: id)
      let birthday = try requireBirthday(id: id)
      modelContext.delete(conflict)
      try stageLocalCloudChange(for: birthday)
      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  public func resolveCloudConflictUsingICloud(
    id: UUID,
    now: Date,
    timeZone: TimeZone
  ) throws {
    do {
      let conflict = try requireCloudConflict(id: id)
      let remote = try decodeCloudSnapshot(conflict.iCloudSnapshotJSON)
      _ = try upsertRemoteSnapshot(remote, now: now, timeZone: timeZone)
      let state = try requireCloudState(id: id)
      state.baseSnapshotJSON = try encodeCloudSnapshot(remote)
      state.needsUpload = false
      state.lastMutationID = nil
      state.lastErrorCategory = nil
      modelContext.delete(conflict)
      try transactionCommitter(modelContext)
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  func stageLocalCloudChange(for birthday: BirthdayEntity) throws {
    let birthdayID = birthday.id
    let descriptor = FetchDescriptor<CloudRecordStateEntity>(
      predicate: #Predicate { $0.entityId == birthdayID }
    )
    let state: CloudRecordStateEntity
    if let existing = try modelContext.fetch(descriptor).first {
      state = existing
    } else {
      state = CloudRecordStateEntity(entityId: birthday.id)
      modelContext.insert(state)
    }
    state.needsUpload = true
    state.lastMutationID = UUID()
    state.lastErrorCategory = nil
  }

  private func applyRemoteCloudChange(
    _ change: CloudRemoteChange,
    now: Date,
    timeZone: TimeZone
  ) throws {
    let id = change.snapshot.id
    let state = try cloudState(id: id)
    let birthday = try birthday(id: id)
    let base = try state?.baseSnapshotJSON.map(decodeCloudSnapshot)
    let local = try birthday.map(cloudSnapshot)
    let decision = try CloudMergePolicy.decide(
      base: base,
      local: local,
      remote: change.snapshot
    )
    let targetState = state ?? CloudRecordStateEntity(entityId: id)
    if state == nil { modelContext.insert(targetState) }
    targetState.encodedSystemFields = change.encodedSystemFields

    switch decision {
    case .acceptRemote, .unchanged:
      if decision == .acceptRemote {
        _ = try upsertRemoteSnapshot(change.snapshot, now: now, timeZone: timeZone)
      }
      targetState.baseSnapshotJSON = try encodeCloudSnapshot(change.snapshot)
      targetState.needsUpload = false
      targetState.lastMutationID = nil
      targetState.lastErrorCategory = nil
    case .acceptLocal:
      targetState.baseSnapshotJSON = try encodeCloudSnapshot(change.snapshot)
      targetState.needsUpload = true
      if targetState.lastMutationID == nil { targetState.lastMutationID = UUID() }
      targetState.lastErrorCategory = nil
    case .conflict(let kind):
      guard let local else { throw CloudSyncStoreError.missingBirthday }
      try saveCloudConflict(local: local, remote: change.snapshot, kind: kind, now: now)
      targetState.baseSnapshotJSON = try base.map(encodeCloudSnapshot)
      targetState.needsUpload = false
      targetState.lastMutationID = nil
      targetState.lastErrorCategory = "conflict"
    }
  }

  private func upsertRemoteSnapshot(
    _ snapshot: CloudBirthdaySnapshot,
    now: Date,
    timeZone: TimeZone
  ) throws -> BirthdayEntity {
    let existing = try birthday(id: snapshot.id)
    let reminder = ReminderConfig(
      timeMinutes: snapshot.reminderTimeMinutes,
      notifyDayBefore: snapshot.notifyDayBefore,
      notifySameDay: snapshot.notifySameDay,
      emailEnabled: existing?.emailEnabled ?? false,
      emailAddress: existing?.emailAddress ?? "",
      emailMessage: existing?.emailMessage ?? ""
    )
    let draft = BirthdayDraft(
      name: snapshot.name,
      lunarBirthday: LunarBirthday(
        month: snapshot.lunarMonth,
        day: snapshot.lunarDay,
        isLeapMonth: snapshot.isLeapMonth
      ),
      reminder: reminder
    )
    let nextSolarDate: Date?
    if snapshot.deletedAt == nil {
      nextSolarDate = try calculator.nextOccurrence(
        of: draft.lunarBirthday,
        reminderMinutes: draft.reminder.timeMinutes,
        after: now,
        in: timeZone
      )
    } else {
      nextSolarDate = nil
    }

    let entity: BirthdayEntity
    if let existing {
      entity = existing
      entity.name = snapshot.name
      entity.lunarMonth = snapshot.lunarMonth
      entity.lunarDay = snapshot.lunarDay
      entity.isLeapMonth = snapshot.isLeapMonth
      entity.reminderTimeMinutes = snapshot.reminderTimeMinutes
      entity.notifyDayBefore = snapshot.notifyDayBefore
      entity.notifySameDay = snapshot.notifySameDay
    } else {
      entity = BirthdayEntity(
        id: snapshot.id,
        draft: draft,
        nextSolarDate: nextSolarDate ?? now,
        now: snapshot.createdAt
      )
      entity.syncStateRaw = SyncState.synced.rawValue
      modelContext.insert(entity)
    }
    entity.createdAt = snapshot.createdAt
    entity.updatedAt = snapshot.updatedAt
    entity.deletedAt = snapshot.deletedAt
    entity.nextSolarDate = nextSolarDate
    return entity
  }

  private func saveCloudConflict(
    local: CloudBirthdaySnapshot,
    remote: CloudBirthdaySnapshot,
    kind: CloudSyncConflictKind,
    now: Date
  ) throws {
    let descriptor = FetchDescriptor<CloudSyncConflictEntity>(
      predicate: #Predicate { $0.entityId == local.id }
    )
    if let existing = try modelContext.fetch(descriptor).first {
      existing.localSnapshotJSON = try encodeCloudSnapshot(local)
      existing.iCloudSnapshotJSON = try encodeCloudSnapshot(remote)
      existing.kindRaw = kind.rawValue
      existing.updatedAt = now
    } else {
      modelContext.insert(
        CloudSyncConflictEntity(
          entityId: local.id,
          localSnapshotJSON: try encodeCloudSnapshot(local),
          iCloudSnapshotJSON: try encodeCloudSnapshot(remote),
          kindRaw: kind.rawValue,
          createdAt: now,
          updatedAt: now
        )
      )
    }
  }

  private func birthday(id: UUID) throws -> BirthdayEntity? {
    let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.id == id })
    return try modelContext.fetch(descriptor).first
  }

  private func requireBirthday(id: UUID) throws -> BirthdayEntity {
    guard let birthday = try birthday(id: id) else { throw CloudSyncStoreError.missingBirthday }
    return birthday
  }

  private func cloudState(id: UUID) throws -> CloudRecordStateEntity? {
    let descriptor = FetchDescriptor<CloudRecordStateEntity>(
      predicate: #Predicate { $0.entityId == id }
    )
    return try modelContext.fetch(descriptor).first
  }

  private func requireCloudState(id: UUID) throws -> CloudRecordStateEntity {
    guard let state = try cloudState(id: id) else {
      throw CloudSyncStoreError.missingCloudState
    }
    return state
  }

  private func requireCloudConflict(id: UUID) throws -> CloudSyncConflictEntity {
    let descriptor = FetchDescriptor<CloudSyncConflictEntity>(
      predicate: #Predicate { $0.entityId == id }
    )
    guard let conflict = try modelContext.fetch(descriptor).first else {
      throw CloudSyncStoreError.conflictNotFound
    }
    return conflict
  }

  private func loadOrCreateEngineState() throws -> CloudSyncEngineStateEntity {
    let descriptor = FetchDescriptor<CloudSyncEngineStateEntity>(
      predicate: #Predicate { $0.key == "primary" }
    )
    if let existing = try modelContext.fetch(descriptor).first { return existing }
    let state = CloudSyncEngineStateEntity(key: "primary")
    modelContext.insert(state)
    return state
  }

  private func cloudSnapshot(from entity: BirthdayEntity) throws -> CloudBirthdaySnapshot {
    try CloudBirthdaySnapshot(
      id: entity.id,
      name: entity.name,
      lunarMonth: entity.lunarMonth,
      lunarDay: entity.lunarDay,
      isLeapMonth: entity.isLeapMonth,
      reminderTimeMinutes: entity.reminderTimeMinutes,
      notifyDayBefore: entity.notifyDayBefore,
      notifySameDay: entity.notifySameDay,
      createdAt: entity.createdAt,
      updatedAt: entity.updatedAt,
      deletedAt: entity.deletedAt
    )
  }

  private func encodeCloudSnapshot(_ snapshot: CloudBirthdaySnapshot) throws -> Data {
    try JSONEncoder().encode(snapshot)
  }

  private func decodeCloudSnapshot(_ data: Data) throws -> CloudBirthdaySnapshot {
    do {
      let decoded = try JSONDecoder().decode(CloudBirthdaySnapshot.self, from: data)
      return try CloudBirthdaySnapshot(
        schemaVersion: decoded.schemaVersion,
        id: decoded.id,
        name: decoded.name,
        lunarMonth: decoded.lunarMonth,
        lunarDay: decoded.lunarDay,
        isLeapMonth: decoded.isLeapMonth,
        reminderTimeMinutes: decoded.reminderTimeMinutes,
        notifyDayBefore: decoded.notifyDayBefore,
        notifySameDay: decoded.notifySameDay,
        createdAt: decoded.createdAt,
        updatedAt: decoded.updatedAt,
        deletedAt: decoded.deletedAt
      )
    } catch {
      throw CloudSyncStoreError.invalidStoredSnapshot
    }
  }
}
