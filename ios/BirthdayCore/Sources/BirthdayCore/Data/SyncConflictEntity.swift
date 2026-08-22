import Foundation
import SwiftData

@Model
public final class SyncConflictEntity {
  @Attribute(.unique) public var entityId: UUID
  public var operationId: UUID?
  public var localSnapshotJSON: Data
  public var remoteSnapshotJSON: Data
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    entityId: UUID,
    operationId: UUID?,
    localSnapshotJSON: Data,
    remoteSnapshotJSON: Data,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.entityId = entityId
    self.operationId = operationId
    self.localSnapshotJSON = localSnapshotJSON
    self.remoteSnapshotJSON = remoteSnapshotJSON
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct SyncConflictRecord: Equatable, Sendable {
  public let entityId: UUID
  public let operationId: UUID?
  public let localSnapshotJSON: Data
  public let remoteSnapshotJSON: Data
  public let createdAt: Date
  public let updatedAt: Date

  init(_ entity: SyncConflictEntity) {
    entityId = entity.entityId
    operationId = entity.operationId
    localSnapshotJSON = entity.localSnapshotJSON
    remoteSnapshotJSON = entity.remoteSnapshotJSON
    createdAt = entity.createdAt
    updatedAt = entity.updatedAt
  }
}
