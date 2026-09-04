import Foundation

public enum CloudSyncConflictKind: String, Codable, Equatable, Sendable {
  case editEdit
  case localDeleteRemoteEdit
  case localEditRemoteDelete
}

public enum CloudMergeDecision: Equatable, Sendable {
  case acceptLocal
  case acceptRemote
  case unchanged
  case conflict(kind: CloudSyncConflictKind)
}

public enum CloudMergePolicyError: Error, Equatable, Sendable {
  case differentEntityIdentifiers
}

public enum CloudMergePolicy {
  public static func decide(
    base: CloudBirthdaySnapshot?,
    local: CloudBirthdaySnapshot?,
    remote: CloudBirthdaySnapshot?
  ) throws -> CloudMergeDecision {
    try requireMatchingIdentifiers(base, local, remote)

    guard let base else {
      return initialDecision(local: local, remote: remote)
    }
    guard let local else { return remote == nil ? .unchanged : .acceptRemote }
    guard let remote else { return .acceptLocal }

    if local.isDeleted, remote.isDeleted { return .unchanged }
    if local.hasSameMergeContent(as: remote) { return .unchanged }

    let localChanged = !local.hasSameMergeContent(as: base)
    let remoteChanged = !remote.hasSameMergeContent(as: base)
    switch (localChanged, remoteChanged) {
    case (false, false):
      return .unchanged
    case (true, false):
      return .acceptLocal
    case (false, true):
      return .acceptRemote
    case (true, true):
      return .conflict(kind: conflictKind(local: local, remote: remote))
    }
  }

  private static func initialDecision(
    local: CloudBirthdaySnapshot?,
    remote: CloudBirthdaySnapshot?
  ) -> CloudMergeDecision {
    switch (local, remote) {
    case (nil, nil):
      return .unchanged
    case (.some, nil):
      return .acceptLocal
    case (nil, .some):
      return .acceptRemote
    case let (.some(local), .some(remote)):
      if local.isDeleted, remote.isDeleted { return .unchanged }
      if local.hasSameMergeContent(as: remote) { return .unchanged }
      return .conflict(kind: conflictKind(local: local, remote: remote))
    }
  }

  private static func conflictKind(
    local: CloudBirthdaySnapshot,
    remote: CloudBirthdaySnapshot
  ) -> CloudSyncConflictKind {
    switch (local.isDeleted, remote.isDeleted) {
    case (true, false):
      return .localDeleteRemoteEdit
    case (false, true):
      return .localEditRemoteDelete
    case (false, false), (true, true):
      return .editEdit
    }
  }

  private static func requireMatchingIdentifiers(
    _ snapshots: CloudBirthdaySnapshot?...
  ) throws {
    let identifiers = Set(snapshots.compactMap { $0?.id })
    guard identifiers.count <= 1 else {
      throw CloudMergePolicyError.differentEntityIdentifiers
    }
  }
}

private extension CloudBirthdaySnapshot {
  var isDeleted: Bool { deletedAt != nil }

  func hasSameMergeContent(as other: Self) -> Bool {
    MergeContent(self) == MergeContent(other)
  }
}

private struct MergeContent: Equatable {
  let id: UUID
  let name: String
  let lunarMonth: Int
  let lunarDay: Int
  let isLeapMonth: Bool
  let reminderTimeMinutes: Int
  let notifyDayBefore: Bool
  let notifySameDay: Bool
  let createdAt: Date
  let deletedAt: Date?

  init(_ snapshot: CloudBirthdaySnapshot) {
    id = snapshot.id
    name = snapshot.name
    lunarMonth = snapshot.lunarMonth
    lunarDay = snapshot.lunarDay
    isLeapMonth = snapshot.isLeapMonth
    reminderTimeMinutes = snapshot.reminderTimeMinutes
    notifyDayBefore = snapshot.notifyDayBefore
    notifySameDay = snapshot.notifySameDay
    createdAt = snapshot.createdAt
    deletedAt = snapshot.deletedAt
  }
}
