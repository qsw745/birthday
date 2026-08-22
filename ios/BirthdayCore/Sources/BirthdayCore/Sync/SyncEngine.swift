import Foundation

public enum RetryPolicy {
  public static func delay(attempt: Int) -> TimeInterval {
    let nonnegativeAttempt = max(0, attempt)
    guard nonnegativeAttempt < 10 else { return 21_600 }
    return min(21_600, 30 * pow(2, Double(nonnegativeAttempt)))
  }
}

public enum PushBatcherError: Error, Equatable, Sendable {
  case operationExceedsLimits(UUID)
  case invalidOperation(UUID)
}

public enum SyncErrorCategory: String, Equatable, Sendable {
  case transport
  case server
  case invalidResponse = "invalid_response"
}

public enum PushBatcher {
  public static let maximumOperations = 50
  public static let maximumRequestBytes = 61_440

  public static func makeBatches(_ operations: [SyncOperation]) throws -> [[PushOperationDTO]] {
    var batches: [[PushOperationDTO]] = []
    var current: [PushOperationDTO] = []

    for operation in operations {
      let dto: PushOperationDTO
      do {
        dto = try PushOperationDTO(operation)
      } catch {
        throw PushBatcherError.invalidOperation(operation.operationId)
      }
      let candidate = current + [dto]
      if candidate.count <= maximumOperations, try encodedSize(candidate) <= maximumRequestBytes {
        current = candidate
        continue
      }

      if !current.isEmpty {
        batches.append(current)
        current = [dto]
      } else {
        throw PushBatcherError.operationExceedsLimits(operation.operationId)
      }

      if try encodedSize(current) > maximumRequestBytes {
        throw PushBatcherError.operationExceedsLimits(operation.operationId)
      }
    }

    if !current.isEmpty {
      batches.append(current)
    }
    return batches
  }

  private static func encodedSize(_ operations: [PushOperationDTO]) throws -> Int {
    try MobileJSON.encoder.encode(PushRequest(operations: operations)).count
  }
}

public enum SyncError: Error, Equatable, Sendable {
  case invalidReadyOperation
  case rebindRequired
}

public struct SyncSummary: Sendable, Equatable {
  public let uploaded: Int
  public let downloaded: Int
  public let conflicts: Int
  public let cursor: Int64

  public init(uploaded: Int, downloaded: Int, conflicts: Int, cursor: Int64) {
    self.uploaded = uploaded
    self.downloaded = downloaded
    self.conflicts = conflicts
    self.cursor = cursor
  }
}

public actor SyncEngine {
  private let api: any MobileAPI
  private let store: BirthdayStore
  private let credentials: DeviceCredentialStore
  private let now: @Sendable () -> Date
  private let timeZone: TimeZone

  public init(
    api: any MobileAPI,
    store: BirthdayStore,
    credentials: DeviceCredentialStore,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZone: TimeZone = .current
  ) {
    self.api = api
    self.store = store
    self.credentials = credentials
    self.now = now
    self.timeZone = timeZone
  }

  public func syncNow() async throws -> SyncSummary {
    var uploaded = 0
    var conflicts = 0

    while true {
      let ready = await store.readyOperations(limit: 200, now: now())
      if ready.isEmpty { break }

      let batches: [[PushOperationDTO]]
      do {
        batches = try PushBatcher.makeBatches(ready)
      } catch let error as PushBatcherError {
        switch error {
        case .operationExceedsLimits(let operationID), .invalidOperation(let operationID):
          try await store.markOperationTerminal(operationID: operationID)
          continue
        }
      }
      guard !batches.isEmpty else { throw SyncError.invalidReadyOperation }

      for batch in batches {
        do {
          let response = try await authorized { accessToken in
            try await self.api.push(PushRequest(operations: batch), accessToken: accessToken)
          }
          try await store.applyPushResults(
            response.results,
            expectedOperationIDs: batch.map(\.operationId),
            expectedOperations: batch,
            now: now(),
            timeZone: timeZone
          )
          uploaded += response.results.filter { $0.status == .applied }.count
          conflicts += response.results.filter { $0.status == .conflict }.count
        } catch {
          try await store.recordRetry(
            operationIDs: batch.map(\.operationId),
            category: retryCategory(for: error),
            now: now()
          )
          throw error
        }
      }
    }

    var cursor = try await store.syncCursor()
    var downloaded = 0
    while true {
      let pageCursor = cursor
      let page = try await authorized { accessToken in
        try await self.api.pull(cursor: pageCursor, accessToken: accessToken)
      }
      try await store.applyPull(page, now: now(), timeZone: timeZone)
      downloaded += page.changes.count
      cursor = page.nextCursor
      if !page.hasMore { break }
    }
    return SyncSummary(
      uploaded: uploaded, downloaded: downloaded, conflicts: conflicts, cursor: cursor)
  }

  private func authorized<Value: Sendable>(
    _ action: @Sendable (String) async throws -> Value
  ) async throws -> Value {
    var current = try loadCredentialsForSync()
    var refreshed = false
    if current.accessExpiresAt.timeIntervalSince(now()) < 60 {
      current = try await refresh(current)
      refreshed = true
    }

    do {
      return try await action(current.accessToken)
    } catch MobileAPIError.accessExpired {
      guard !refreshed else { throw SyncError.rebindRequired }
      current = try await refresh(current)
      refreshed = true
      do {
        return try await action(current.accessToken)
      } catch MobileAPIError.accessExpired {
        throw SyncError.rebindRequired
      } catch MobileAPIError.refreshInvalid {
        throw SyncError.rebindRequired
      }
    } catch MobileAPIError.refreshInvalid {
      throw SyncError.rebindRequired
    }
  }

  private func loadCredentialsForSync() throws -> DeviceCredentials {
    do {
      guard let saved = try credentials.load(), saved.refreshExpiresAt > now() else {
        throw SyncError.rebindRequired
      }
      return saved
    } catch is SyncError {
      throw SyncError.rebindRequired
    } catch {
      throw SyncError.rebindRequired
    }
  }

  private func refresh(_ current: DeviceCredentials) async throws -> DeviceCredentials {
    do {
      let response = try await api.refresh(RefreshRequest(refreshToken: current.refreshToken))
      guard response.deviceId == current.deviceId else { throw SyncError.rebindRequired }
      let rotated = DeviceCredentials(response)
      try credentials.replaceAfterRefresh(rotated, expectedDeviceID: current.deviceId)
      return rotated
    } catch MobileAPIError.refreshInvalid {
      throw SyncError.rebindRequired
    } catch is SyncError {
      throw SyncError.rebindRequired
    } catch {
      throw SyncError.rebindRequired
    }
  }

  private func retryCategory(for error: Error) -> SyncErrorCategory {
    switch error {
    case MobileAPIError.transport:
      .transport
    case MobileAPIError.server:
      .server
    default:
      .invalidResponse
    }
  }
}
