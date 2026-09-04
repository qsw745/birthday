import CloudKit
import Foundation

public enum CloudErrorCategory: String, Equatable, Sendable {
  case offline
  case notSignedIn
  case accountRestricted
  case quotaExceeded
  case rateLimited
  case serviceUnavailable
  case recordConflict
  case permissionOrConfiguration
  case cancelled
  case unknown
}

public enum CloudErrorClassifier {
  public static func classify(_ error: Error) -> CloudErrorCategory {
    guard let cloudError = error as? CKError else { return .unknown }
    switch cloudError.code {
    case .networkUnavailable, .networkFailure:
      return .offline
    case .notAuthenticated:
      return .notSignedIn
    case .accountTemporarilyUnavailable:
      return .accountRestricted
    case .quotaExceeded:
      return .quotaExceeded
    case .requestRateLimited, .zoneBusy:
      return .rateLimited
    case .serviceUnavailable:
      return .serviceUnavailable
    case .serverRecordChanged, .batchRequestFailed:
      return .recordConflict
    case .permissionFailure, .badContainer, .missingEntitlement, .invalidArguments:
      return .permissionOrConfiguration
    case .operationCancelled:
      return .cancelled
    default:
      return .unknown
    }
  }
}

public struct CloudUploadFailure: Equatable, Sendable {
  public let change: CloudPendingChange
  public let category: CloudErrorCategory

  public init(change: CloudPendingChange, category: CloudErrorCategory) {
    self.change = change
    self.category = category
  }
}

public enum CloudSyncEngineEvent: Equatable, Sendable {
  case stateUpdated(Data)
  case requestsUploadBatch(limit: Int)
  case recordsFetched(
    eventID: UUID,
    changes: [CloudRemoteChange],
    fetchedAt: Date,
    timeZone: TimeZone
  )
  case recordsDeleted(eventID: UUID, entityIDs: [UUID])
  case recordsSent(
    eventID: UUID,
    successes: [CloudUploadSuccess],
    failures: [CloudUploadFailure]
  )
}

public enum CloudSyncEngineResponse: Equatable, Sendable {
  case uploadBatch([CloudPendingChange])
}

public protocol CloudSyncRepository: Sendable {
  func bootstrapCloudState() async throws
  func cloudEngineState() async throws -> CloudEngineStateRecord
  func persistCloudEngineState(_ serializedState: Data?) async throws
  func pendingCloudChanges(limit: Int) async throws -> [CloudPendingChange]
  func applyRemoteCloudChanges(
    _ changes: [CloudRemoteChange],
    now: Date,
    timeZone: TimeZone
  ) async throws
  func restageCloudRecordsDeletedRemotely(_ entityIDs: [UUID]) async throws
  func markCloudUploadSucceeded(_ success: CloudUploadSuccess) async throws
  func recordCloudUploadFailure(_ change: CloudPendingChange, category: String) async throws
}

extension BirthdayStore: CloudSyncRepository {}

public protocol CloudSyncEngineClient: Sendable {
  func start() async throws
  func pause() async
  func send() async throws
  func fetch() async throws
  func close() async
}

public enum SystemCloudSyncEngineAdapterError: Error, Equatable, Sendable {
  case invalidStateSerialization
}

protocol CloudSyncEngineSession: Sendable {
  func addPendingDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange]) async
  func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async
  func fetchChanges() async throws
  func sendChanges() async throws
  func cancelOperations() async
}

typealias CloudSyncEngineSessionFactory = @Sendable (
  _ containerIdentifier: String,
  _ stateSerialization: Data?,
  _ delegate: any CKSyncEngineDelegate
) async throws -> any CloudSyncEngineSession

enum SystemCloudSyncEngineConfiguration {
  static let databaseScope: CKDatabase.Scope = .private

  static func decodeStateSerialization(
    _ data: Data?
  ) throws -> CKSyncEngine.State.Serialization? {
    do {
      return try data.map {
        try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
      }
    } catch {
      throw SystemCloudSyncEngineAdapterError.invalidStateSerialization
    }
  }

  static func privateDatabase(containerIdentifier: String) -> CKDatabase {
    CKContainer(identifier: containerIdentifier).database(with: databaseScope)
  }
}

enum CloudHardDeletionDecoder {
  static func entityID(recordID: CKRecord.ID, recordType: String) -> UUID? {
    guard recordType == CloudRecordCodec.recordType else { return nil }
    guard recordID.zoneID == CloudRecordCodec.zoneID else { return nil }
    guard let entityID = UUID(uuidString: recordID.recordName) else { return nil }
    guard recordID.recordName == entityID.uuidString.lowercased() else { return nil }
    return entityID
  }
}

public actor SystemCloudSyncEngineAdapter: CloudSyncEngineClient {
  public static let defaultContainerIdentifier = "iCloud.top.qisw.birthday"

  private let repository: any CloudSyncRepository
  private let retainedDelegate: any CKSyncEngineDelegate
  private let session: any CloudSyncEngineSession
  private let requiresZoneCreation: Bool

  public init(
    repository: any CloudSyncRepository,
    containerIdentifier: String = SystemCloudSyncEngineAdapter.defaultContainerIdentifier
  ) async throws {
    try await self.init(
      repository: repository,
      containerIdentifier: containerIdentifier,
      sessionFactory: SystemCloudSyncEngineSession.make
    )
  }

  init(
    repository: any CloudSyncRepository,
    containerIdentifier: String,
    sessionFactory: CloudSyncEngineSessionFactory
  ) async throws {
    let processor = CloudSyncEngineEventProcessor(repository: repository)
    let eventBridge = CloudSyncEngineEventBridge(processor: processor)
    let delegate = SystemCloudSyncEngineDelegate(eventBridge: eventBridge)
    let storedState = try await repository.cloudEngineState().serializedState
    let session: any CloudSyncEngineSession
    let requiresZoneCreation: Bool
    do {
      session = try await sessionFactory(containerIdentifier, storedState, delegate)
      requiresZoneCreation = storedState == nil
    } catch SystemCloudSyncEngineAdapterError.invalidStateSerialization {
      try await repository.persistCloudEngineState(nil)
      session = try await sessionFactory(containerIdentifier, nil, delegate)
      requiresZoneCreation = true
    }
    self.repository = repository
    self.retainedDelegate = delegate
    self.session = session
    self.requiresZoneCreation = requiresZoneCreation
  }

  public func start() async throws {
    try await repository.bootstrapCloudState()
    if requiresZoneCreation {
      await session.addPendingDatabaseChanges([
        .saveZone(CKRecordZone(zoneID: CloudRecordCodec.zoneID))
      ])
      try await session.sendChanges()
    }
    try await session.fetchChanges()
    try await enqueuePendingRecords()
    try await session.sendChanges()
  }

  public func pause() async {
    await session.cancelOperations()
  }

  public func send() async throws {
    try await enqueuePendingRecords()
    try await session.sendChanges()
  }

  public func fetch() async throws {
    try await session.fetchChanges()
  }

  public func close() async {
    await session.cancelOperations()
  }

  private func enqueuePendingRecords() async throws {
    let pending = try await repository.pendingCloudChanges(limit: 400)
    let changes = pending.map { change in
      CKSyncEngine.PendingRecordZoneChange.saveRecord(
        CKRecord.ID(
          recordName: change.snapshot.id.uuidString.lowercased(),
          zoneID: CloudRecordCodec.zoneID
        )
      )
    }
    if !changes.isEmpty {
      await session.addPendingRecordZoneChanges(changes)
    }
  }
}

private struct SystemCloudSyncEngineSession: CloudSyncEngineSession {
  let engine: CKSyncEngine

  static func make(
    containerIdentifier: String,
    stateSerialization: Data?,
    delegate: any CKSyncEngineDelegate
  ) async throws -> any CloudSyncEngineSession {
    let decodedState = try SystemCloudSyncEngineConfiguration.decodeStateSerialization(
      stateSerialization
    )

    var configuration = CKSyncEngine.Configuration(
      database: SystemCloudSyncEngineConfiguration.privateDatabase(
        containerIdentifier: containerIdentifier
      ),
      stateSerialization: decodedState,
      delegate: delegate
    )
    configuration.automaticallySync = false
    configuration.subscriptionID = "BirthdayPrivateSyncV1"
    return SystemCloudSyncEngineSession(engine: CKSyncEngine(configuration))
  }

  func addPendingDatabaseChanges(_ changes: [CKSyncEngine.PendingDatabaseChange]) async {
    engine.state.add(pendingDatabaseChanges: changes)
  }

  func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {
    engine.state.add(pendingRecordZoneChanges: changes)
  }

  func fetchChanges() async throws {
    try await engine.fetchChanges(.init(scope: .zoneIDs([CloudRecordCodec.zoneID])))
  }

  func sendChanges() async throws {
    try await engine.sendChanges(.init(scope: .zoneIDs([CloudRecordCodec.zoneID])))
  }

  func cancelOperations() async {
    await engine.cancelOperations()
  }
}

private final class SystemCloudSyncEngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
  private let eventBridge: CloudSyncEngineEventBridge

  init(eventBridge: CloudSyncEngineEventBridge) {
    self.eventBridge = eventBridge
  }

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    await eventBridge.handle(event)
  }

  func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let pending = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
    return await eventBridge.makeRecordZoneChangeBatch(from: pending)
  }
}

private actor CloudSyncEngineEventBridge {
  private let processor: CloudSyncEngineEventProcessor
  private var inFlightChanges: [CKRecord.ID: CloudPendingChange] = [:]

  init(processor: CloudSyncEngineEventProcessor) {
    self.processor = processor
  }

  func handle(_ event: CKSyncEngine.Event) async {
    do {
      switch event {
      case .stateUpdate(let update):
        let serialized = try JSONEncoder().encode(update.stateSerialization)
        try await processor.handle(.stateUpdated(serialized))

      case .fetchedRecordZoneChanges(let fetched):
        let changes: [CloudRemoteChange] = try fetched.modifications.compactMap { modification in
          let record = modification.record
          guard
            record.recordType == CloudRecordCodec.recordType,
            record.recordID.zoneID == CloudRecordCodec.zoneID
          else { return nil }
          return CloudRemoteChange(
            snapshot: try CloudRecordCodec.decode(record: record),
            encodedSystemFields: try CloudRecordCodec.encodeSystemFields(of: record)
          )
        }
        try await processor.handle(
          .recordsFetched(
            eventID: UUID(),
            changes: changes,
            fetchedAt: Date(),
            timeZone: .autoupdatingCurrent
          )
        )
        let hardDeletedEntityIDs = fetched.deletions.compactMap { deletion in
          CloudHardDeletionDecoder.entityID(
            recordID: deletion.recordID,
            recordType: deletion.recordType
          )
        }
        if !hardDeletedEntityIDs.isEmpty {
          try await processor.handle(
            .recordsDeleted(eventID: UUID(), entityIDs: hardDeletedEntityIDs)
          )
        }

      case .sentRecordZoneChanges(let sent):
        let successes = try sent.savedRecords.compactMap { record -> CloudUploadSuccess? in
          guard let pending = inFlightChanges[record.recordID] else { return nil }
          return CloudUploadSuccess(
            entityID: pending.snapshot.id,
            mutationID: pending.mutationID,
            uploadedSnapshot: pending.snapshot,
            encodedSystemFields: try CloudRecordCodec.encodeSystemFields(of: record)
          )
        }
        let failures = sent.failedRecordSaves.compactMap { failure -> CloudUploadFailure? in
          guard let pending = inFlightChanges[failure.record.recordID] else { return nil }
          return CloudUploadFailure(
            change: pending,
            category: CloudErrorClassifier.classify(failure.error)
          )
        }
        try await processor.handle(
          .recordsSent(eventID: UUID(), successes: successes, failures: failures)
        )
        for record in sent.savedRecords {
          inFlightChanges.removeValue(forKey: record.recordID)
        }
        for failure in sent.failedRecordSaves {
          inFlightChanges.removeValue(forKey: failure.record.recordID)
        }

      default:
        break
      }
    } catch {
      // CKSyncEngine delegate callbacks cannot throw. Repository state remains pending so the
      // next explicit or scheduled attempt can retry without changing local birthday data.
    }
  }

  func makeRecordZoneChangeBatch(
    from pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    do {
      guard
        case .uploadBatch(let localChanges) =
          try await processor.handle(.requestsUploadBatch(limit: max(400, pendingChanges.count)))
      else { return nil }
      let changesByRecordID = Dictionary(uniqueKeysWithValues: localChanges.map { change in
        (
          CKRecord.ID(
            recordName: change.snapshot.id.uuidString.lowercased(),
            zoneID: CloudRecordCodec.zoneID
          ),
          change
        )
      })
      var records: [CKRecord] = []
      for pendingChange in pendingChanges {
        guard case .saveRecord(let recordID) = pendingChange else { continue }
        guard let localChange = changesByRecordID[recordID] else { continue }
        records.append(
          try CloudRecordCodec.encode(
            snapshot: localChange.snapshot,
            systemFields: localChange.encodedSystemFields
          )
        )
        inFlightChanges[recordID] = localChange
      }
      guard !records.isEmpty else { return nil }
      return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, atomicByZone: true)
    } catch {
      return nil
    }
  }
}

public actor CloudSyncEngineEventProcessor {
  private let repository: any CloudSyncRepository
  private var processedEventIDs: Set<UUID> = []

  public init(repository: any CloudSyncRepository) {
    self.repository = repository
  }

  @discardableResult
  public func handle(_ event: CloudSyncEngineEvent) async throws -> CloudSyncEngineResponse? {
    switch event {
    case .stateUpdated(let serialization):
      try await repository.persistCloudEngineState(serialization)
      return nil

    case .requestsUploadBatch(let limit):
      return .uploadBatch(try await repository.pendingCloudChanges(limit: limit))

    case let .recordsFetched(eventID, changes, fetchedAt, timeZone):
      guard processedEventIDs.insert(eventID).inserted else { return nil }
      do {
        try await repository.applyRemoteCloudChanges(
          changes,
          now: fetchedAt,
          timeZone: timeZone
        )
      } catch {
        processedEventIDs.remove(eventID)
        throw error
      }
      return nil

    case let .recordsDeleted(eventID, entityIDs):
      guard processedEventIDs.insert(eventID).inserted else { return nil }
      do {
        try await repository.restageCloudRecordsDeletedRemotely(entityIDs)
      } catch {
        processedEventIDs.remove(eventID)
        throw error
      }
      return nil

    case let .recordsSent(eventID, successes, failures):
      guard processedEventIDs.insert(eventID).inserted else { return nil }
      do {
        for success in successes {
          try await repository.markCloudUploadSucceeded(success)
        }
        for failure in failures where failure.category != .cancelled {
          try await repository.recordCloudUploadFailure(
            failure.change,
            category: failure.category.rawValue
          )
        }
      } catch {
        processedEventIDs.remove(eventID)
        throw error
      }
      return nil
    }
  }
}
