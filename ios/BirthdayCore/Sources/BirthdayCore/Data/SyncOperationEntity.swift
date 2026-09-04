import Foundation
import SwiftData

extension BirthdaySchemaV2 {
  @Model
  public final class SyncOperationEntity {
    @Attribute(.unique) public var operationId: UUID
    public var entityId: UUID
    public var operationType: String
    public var baseVersion: Int64
    public var payloadJSON: Data
    public var createdAt: Date
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var lastErrorCategory: String?

    public init(
      operationId: UUID,
      entityId: UUID,
      operationType: String,
      baseVersion: Int64,
      payloadJSON: Data,
      createdAt: Date,
      attemptCount: Int,
      nextRetryAt: Date?,
      lastErrorCategory: String?
    ) {
      self.operationId = operationId
      self.entityId = entityId
      self.operationType = operationType
      self.baseVersion = baseVersion
      self.payloadJSON = payloadJSON
      self.createdAt = createdAt
      self.attemptCount = attemptCount
      self.nextRetryAt = nextRetryAt
      self.lastErrorCategory = lastErrorCategory
    }
  }
}

public typealias SyncOperationEntity = BirthdaySchemaV3.SyncOperationEntity
