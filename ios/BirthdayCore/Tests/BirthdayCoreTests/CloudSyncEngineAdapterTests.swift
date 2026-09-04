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

private actor FakeCloudRepository: CloudSyncRepository {
  let pending: [CloudPendingChange]
  var persistedStates: [Data] = []
  var remoteBatches: [[CloudRemoteChange]] = []
  var successes: [CloudUploadSuccess] = []
  var failures: [(CloudPendingChange, String)] = []

  init(pending: [CloudPendingChange] = []) {
    self.pending = pending
  }

  func persistCloudEngineState(_ serializedState: Data?) throws {
    if let serializedState { persistedStates.append(serializedState) }
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

  func markCloudUploadSucceeded(_ success: CloudUploadSuccess) throws {
    successes.append(success)
  }

  func recordCloudUploadFailure(_ change: CloudPendingChange, category: String) throws {
    failures.append((change, category))
  }
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
