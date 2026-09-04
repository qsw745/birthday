import Foundation
import SwiftData

extension BirthdaySchemaV2 {
  @Model
  public final class SyncConflictEntity {
    @Attribute(.unique) public var entityId: UUID
    public var operationId: UUID?
    public var localSnapshotJSON: Data
    public var remoteSnapshotJSON: Data
    public var createdAt: Date
    public var updatedAt: Date
    public var kindRaw: String = "editEdit"

    public init(
      entityId: UUID,
      operationId: UUID?,
      localSnapshotJSON: Data,
      remoteSnapshotJSON: Data,
      createdAt: Date,
      updatedAt: Date,
      kindRaw: String = SyncConflictKind.editEdit.rawValue
    ) {
      self.entityId = entityId
      self.operationId = operationId
      self.localSnapshotJSON = localSnapshotJSON
      self.remoteSnapshotJSON = remoteSnapshotJSON
      self.createdAt = createdAt
      self.updatedAt = updatedAt
      self.kindRaw = kindRaw
    }
  }
}

public typealias SyncConflictEntity = BirthdaySchemaV3.SyncConflictEntity

public enum SyncConflictKind: String, Codable, Equatable, Sendable {
  case editEdit
  case deleteEdit
}

public enum SyncConflictSnapshotSide: String, Codable, Equatable, Sendable {
  case local
  case remote
}

public enum SyncConflictSnapshotError: Error, Equatable, Sendable {
  case malformedSnapshot
  case unsupportedFormatVersion(Int)
  case unexpectedSide(expected: SyncConflictSnapshotSide, actual: SyncConflictSnapshotSide)
}

public struct SyncConflictSnapshot: Codable, Equatable, Sendable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public let side: SyncConflictSnapshotSide
  public let record: APIBirthday

  private init(formatVersion: Int, side: SyncConflictSnapshotSide, record: APIBirthday) {
    self.formatVersion = formatVersion
    self.side = side
    self.record = record
  }

  public static func encode(_ record: APIBirthday, side: SyncConflictSnapshotSide) throws -> Data {
    try MobileJSON.encoder.encode(
      SyncConflictSnapshot(
        formatVersion: currentFormatVersion,
        side: side,
        record: record
      ))
  }

  public static func decode(_ data: Data, expectedSide: SyncConflictSnapshotSide) throws -> Self {
    let probe: FormatVersionProbe
    do {
      probe = try MobileJSON.decoder.decode(FormatVersionProbe.self, from: data)
    } catch {
      throw SyncConflictSnapshotError.malformedSnapshot
    }

    if let formatVersion = probe.formatVersion {
      guard formatVersion == currentFormatVersion else {
        throw SyncConflictSnapshotError.unsupportedFormatVersion(formatVersion)
      }
      let snapshot: SyncConflictSnapshot
      do {
        snapshot = try MobileJSON.decoder.decode(SyncConflictSnapshot.self, from: data)
      } catch {
        throw SyncConflictSnapshotError.malformedSnapshot
      }
      guard snapshot.side == expectedSide else {
        throw SyncConflictSnapshotError.unexpectedSide(
          expected: expectedSide,
          actual: snapshot.side
        )
      }
      return snapshot
    }

    do {
      return SyncConflictSnapshot(
        formatVersion: 0,
        side: expectedSide,
        record: try MobileJSON.decoder.decode(APIBirthday.self, from: data)
      )
    } catch {
      throw SyncConflictSnapshotError.malformedSnapshot
    }
  }
}

private struct FormatVersionProbe: Decodable {
  let formatVersion: Int?
}

public struct SyncConflictRecord: Equatable, Sendable {
  public let entityId: UUID
  public let operationId: UUID?
  public let localSnapshotJSON: Data
  public let remoteSnapshotJSON: Data
  public let createdAt: Date
  public let updatedAt: Date
  public let kindRaw: String

  init(_ entity: SyncConflictEntity) {
    entityId = entity.entityId
    operationId = entity.operationId
    localSnapshotJSON = entity.localSnapshotJSON
    remoteSnapshotJSON = entity.remoteSnapshotJSON
    createdAt = entity.createdAt
    updatedAt = entity.updatedAt
    kindRaw = entity.kindRaw
  }
}
