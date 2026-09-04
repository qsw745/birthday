import CloudKit
import Foundation
import Testing

@testable import BirthdayCore

@Test func cloudEngineEventProcessorPersistsStateAndLoadsPendingFromRepository() async throws {
  let repository = FakeCloudRepository(pending: [try pendingCloudChange()])
  let processor = CloudSyncEngineEventProcessor(repository: repository)

  try await processor.handle(.stateUpdated(Data("state-1".utf8)))
  try await processor.handle(.stateUpdated(Data("state-2".utf8)))
  let response = try await processor.handle(.requestsUploadBatch(limit: 20))

  #expect(await repository.persistedStates == [Data("state-1".utf8), Data("state-2".utf8)])
  #expect(response == .uploadBatch([try pendingCloudChange()]))
}

@Test func cloudEngineEventProcessorAppliesRemoteBatchOnce() async throws {
  let repository = FakeCloudRepository()
  let processor = CloudSyncEngineEventProcessor(repository: repository)
  let eventID = UUID()
  let change = CloudRemoteChange(
    snapshot: try engineSnapshot(name: "云端"),
    encodedSystemFields: Data("system".utf8)
  )
  let event = CloudSyncEngineEvent.recordsFetched(
    eventID: eventID,
    changes: [change],
    fetchedAt: engineNow,
    timeZone: engineTimeZone
  )

  try await processor.handle(event)
  try await processor.handle(event)

  #expect(await repository.remoteBatches.count == 1)
}

@Test func cloudEngineEventProcessorRestagesHardDeletionsOnce() async throws {
  let repository = FakeCloudRepository()
  let processor = CloudSyncEngineEventProcessor(repository: repository)
  let eventID = UUID()
  let entityID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  let event = CloudSyncEngineEvent.recordsDeleted(
    eventID: eventID,
    entityIDs: [entityID]
  )

  try await processor.handle(event)
  try await processor.handle(event)

  #expect(await repository.hardDeletionBatches == [[entityID]])
}

@Test func cloudEngineEventProcessorAcknowledgesSuccessAndRetriesOnlyFailedRecords() async throws {
  let repository = FakeCloudRepository()
  let processor = CloudSyncEngineEventProcessor(repository: repository)
  let pending = try pendingCloudChange()
  let success = CloudUploadSuccess(
    entityID: pending.snapshot.id,
    mutationID: pending.mutationID,
    uploadedSnapshot: pending.snapshot,
    encodedSystemFields: Data("saved".utf8)
  )
  let failed = try pendingCloudChange(
    id: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
  )

  try await processor.handle(
    .recordsSent(
      eventID: UUID(),
      successes: [success],
      failures: [
        CloudUploadFailure(change: failed, category: .rateLimited),
        CloudUploadFailure(change: pending, category: .cancelled),
      ]
    )
  )

  #expect(await repository.successes == [success])
  #expect(await repository.failures.map(\.0.snapshot.id) == [failed.snapshot.id])
  #expect(await repository.failures.map(\.1) == [CloudErrorCategory.rateLimited.rawValue])
}

@Test func cloudErrorClassifierCoversActionableCKErrorFamilies() {
  #expect(CloudErrorClassifier.classify(CKError(.networkUnavailable)) == .offline)
  #expect(CloudErrorClassifier.classify(CKError(.notAuthenticated)) == .notSignedIn)
  #expect(CloudErrorClassifier.classify(CKError(.quotaExceeded)) == .quotaExceeded)
  #expect(CloudErrorClassifier.classify(CKError(.requestRateLimited)) == .rateLimited)
  #expect(CloudErrorClassifier.classify(CKError(.serviceUnavailable)) == .serviceUnavailable)
  #expect(CloudErrorClassifier.classify(CKError(.serverRecordChanged)) == .recordConflict)
  #expect(CloudErrorClassifier.classify(CKError(.permissionFailure)) == .permissionOrConfiguration)
  #expect(CloudErrorClassifier.classify(CKError(.operationCancelled)) == .cancelled)
}

@Test func systemCloudSyncEngineAdapterRecoversInvalidStateAndReenumeratesLocalPendingChanges() async throws {
  let pending = try pendingCloudChange()
  let repository = FakeCloudRepository(
    pending: [pending],
    engineState: CloudEngineStateRecord(
      serializedState: Data("broken-state".utf8),
      initialMergeCompleted: false,
      lastSuccessfulFetchAt: nil
    )
  )
  let session = FakeCloudSyncEngineSession()
  let factory = FakeCloudSyncEngineSessionFactory(session: session, rejectStoredState: true)
  let adapter = try await SystemCloudSyncEngineAdapter(
    repository: repository,
    containerIdentifier: "iCloud.top.qisw.birthday",
    sessionFactory: { containerIdentifier, stateSerialization, delegate in
      try await factory.makeSession(
        containerIdentifier: containerIdentifier,
        stateSerialization: stateSerialization,
        delegate: delegate
      )
    }
  )

  #expect(await factory.containerIdentifiers == [
    "iCloud.top.qisw.birthday",
    "iCloud.top.qisw.birthday",
  ])
  #expect(await factory.serializedStates == [Data("broken-state".utf8), nil])
  #expect(await repository.persistedStates == [nil])

  try await adapter.start()

  #expect(await repository.bootstrapCount == 1)
  #expect(repository.pending == [pending])
  #expect(await session.savedZoneNames == [CloudRecordCodec.zoneName])
  #expect(await session.savedRecordNames == [pending.snapshot.id.uuidString.lowercased()])
  #expect(await session.operations == [.saveZone, .send, .fetch, .saveRecord, .send])
}

@Test func systemCloudSyncEngineAdapterRetainsTheWeakCloudKitDelegate() async throws {
  let repository = FakeCloudRepository()
  let session = FakeCloudSyncEngineSession()
  let delegateReference = WeakCloudSyncEngineDelegateReference()
  let adapter = try await SystemCloudSyncEngineAdapter(
    repository: repository,
    containerIdentifier: "iCloud.top.qisw.birthday",
    sessionFactory: { _, _, delegate in
      delegateReference.value = delegate
      return session
    }
  )

  #expect(delegateReference.value != nil)
  _ = adapter
}

@Test func systemCloudSyncEngineConfigurationUsesThePrivateDatabase() {
  #expect(SystemCloudSyncEngineConfiguration.databaseScope == .private)
}

@Test func systemCloudSyncEngineConfigurationRejectsMalformedSerializedState() {
  #expect(throws: SystemCloudSyncEngineAdapterError.invalidStateSerialization) {
    _ = try SystemCloudSyncEngineConfiguration.decodeStateSerialization(
      Data("not-a-cloudkit-state".utf8)
    )
  }
}

@Test func cloudHardDeletionDecoderAcceptsOnlyCanonicalBirthdayRecordsInTheDedicatedZone() {
  let entityID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  let validRecordID = CKRecord.ID(
    recordName: entityID.uuidString.lowercased(),
    zoneID: CloudRecordCodec.zoneID
  )
  let wrongZoneRecordID = CKRecord.ID(
    recordName: entityID.uuidString.lowercased(),
    zoneID: CKRecordZone.ID(zoneName: "OtherZone", ownerName: CKCurrentUserDefaultName)
  )

  #expect(
    CloudHardDeletionDecoder.entityID(
      recordID: validRecordID,
      recordType: CloudRecordCodec.recordType
    ) == entityID
  )
  #expect(
    CloudHardDeletionDecoder.entityID(
      recordID: validRecordID,
      recordType: "OtherRecord"
    ) == nil
  )
  #expect(
    CloudHardDeletionDecoder.entityID(
      recordID: wrongZoneRecordID,
      recordType: CloudRecordCodec.recordType
    ) == nil
  )
}

private actor FakeCloudRepository: CloudSyncRepository {
  let pending: [CloudPendingChange]
  let engineState: CloudEngineStateRecord
  var bootstrapCount = 0
  var persistedStates: [Data?] = []
  var remoteBatches: [[CloudRemoteChange]] = []
  var hardDeletionBatches: [[UUID]] = []
  var successes: [CloudUploadSuccess] = []
  var failures: [(CloudPendingChange, String)] = []

  init(
    pending: [CloudPendingChange] = [],
    engineState: CloudEngineStateRecord = CloudEngineStateRecord(
      serializedState: nil,
      initialMergeCompleted: false,
      lastSuccessfulFetchAt: nil
    )
  ) {
    self.pending = pending
    self.engineState = engineState
  }

  func bootstrapCloudState() throws {
    bootstrapCount += 1
  }

  func cloudEngineState() throws -> CloudEngineStateRecord {
    engineState
  }

  func persistCloudEngineState(_ serializedState: Data?) throws {
    persistedStates.append(serializedState)
  }

  func pendingCloudChanges(limit: Int) throws -> [CloudPendingChange] {
    Array(pending.prefix(limit))
  }

  func applyRemoteCloudChanges(
    _ changes: [CloudRemoteChange],
    now: Date,
    timeZone: TimeZone
  ) throws {
    remoteBatches.append(changes)
  }

  func restageCloudRecordsDeletedRemotely(_ entityIDs: [UUID]) throws {
    hardDeletionBatches.append(entityIDs)
  }

  func markCloudUploadSucceeded(_ success: CloudUploadSuccess) throws {
    successes.append(success)
  }

  func recordCloudUploadFailure(_ change: CloudPendingChange, category: String) throws {
    failures.append((change, category))
  }
}

private actor FakeCloudSyncEngineSession: CloudSyncEngineSession {
  enum Operation: Equatable, Sendable {
    case saveZone
    case saveRecord
    case fetch
    case send
  }

  var savedZoneNames: [String] = []
  var savedRecordNames: [String] = []
  var operations: [Operation] = []

  func addPendingDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange]) {
    for change in changes {
      guard case .saveZone(let zone) = change else { continue }
      savedZoneNames.append(zone.zoneID.zoneName)
      operations.append(.saveZone)
    }
  }

  func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
    for change in changes {
      guard case .saveRecord(let recordID) = change else { continue }
      savedRecordNames.append(recordID.recordName)
      operations.append(.saveRecord)
    }
  }

  func fetchChanges() {
    operations.append(.fetch)
  }

  func sendChanges() {
    operations.append(.send)
  }

  func cancelOperations() {}
}

private actor FakeCloudSyncEngineSessionFactory {
  let session: FakeCloudSyncEngineSession
  let rejectStoredState: Bool
  var containerIdentifiers: [String] = []
  var serializedStates: [Data?] = []

  init(session: FakeCloudSyncEngineSession, rejectStoredState: Bool) {
    self.session = session
    self.rejectStoredState = rejectStoredState
  }

  func makeSession(
    containerIdentifier: String,
    stateSerialization: Data?,
    delegate: any CKSyncEngineDelegate
  ) throws -> any CloudSyncEngineSession {
    containerIdentifiers.append(containerIdentifier)
    serializedStates.append(stateSerialization)
    if rejectStoredState, stateSerialization != nil {
      throw SystemCloudSyncEngineAdapterError.invalidStateSerialization
    }
    return session
  }
}

private final class WeakCloudSyncEngineDelegateReference: @unchecked Sendable {
  weak var value: (any CKSyncEngineDelegate)?
}

private let engineNow = Date(timeIntervalSince1970: 1_788_000_000)
private let engineTimeZone = TimeZone(identifier: "Asia/Shanghai")!

private func engineSnapshot(
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
    createdAt: engineNow,
    updatedAt: engineNow,
    deletedAt: nil
  )
}

private func pendingCloudChange(
  id: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
) throws -> CloudPendingChange {
  CloudPendingChange(
    snapshot: try engineSnapshot(id: id, name: "待上传"),
    encodedSystemFields: nil,
    mutationID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
    lastErrorCategory: nil
  )
}
