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
  func persistCloudEngineState(_ serializedState: Data?) async throws
  func pendingCloudChanges(limit: Int) async throws -> [CloudPendingChange]
  func applyRemoteCloudChanges(
    _ changes: [CloudRemoteChange],
    now: Date,
    timeZone: TimeZone
  ) async throws
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
