import Foundation

public enum ConflictResolutionError: Error, Equatable, Sendable {
  case conflictNotFound
  case birthdayNotFound
  case operationNotFound
  case operationEntityMismatch
  case invalidConflictKind
  case invalidSnapshot
  case snapshotEntityMismatch
  case unsupportedConflictShape
  case operationIDNotFresh
}

public struct ResolvableSyncConflict: Identifiable, Equatable, Sendable {
  public var id: UUID { entityId }
  public let entityId: UUID
  public let operationId: UUID
  public let local: APIBirthday
  public let remote: APIBirthday
  public let kind: SyncConflictKind
  public let createdAt: Date
  public let updatedAt: Date
}

public struct ConflictResolver: Sendable {
  private let store: BirthdayStore
  private let makeOperationID: @Sendable () -> UUID
  private let now: @Sendable () -> Date
  private let timeZone: @Sendable () -> TimeZone

  public init(
    store: BirthdayStore,
    makeOperationID: @escaping @Sendable () -> UUID = UUID.init,
    now: @escaping @Sendable () -> Date = Date.init,
    timeZone: @escaping @Sendable () -> TimeZone = { .current }
  ) {
    self.store = store
    self.makeOperationID = makeOperationID
    self.now = now
    self.timeZone = timeZone
  }

  public func conflicts() async throws -> [ResolvableSyncConflict] {
    try await store.resolvableSyncConflicts()
  }

  public func keepLocal(id: UUID) async throws {
    try await store.resolveConflictKeepingLocal(
      id: id,
      newOperationID: makeOperationID(),
      now: now()
    )
  }

  public func useRemote(id: UUID) async throws {
    try await store.resolveConflictUsingRemote(
      id: id,
      now: now(),
      timeZone: timeZone()
    )
  }
}
