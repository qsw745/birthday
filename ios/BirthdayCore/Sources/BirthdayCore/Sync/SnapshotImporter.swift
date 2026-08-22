import Foundation

public enum DuplicateDecision: String, Codable, Sendable {
  case keepBoth
  case useRemote
}

public struct DuplicateCandidate: Identifiable, Equatable, Sendable {
  public var id: String {
    "\(local.id.uuidString):\(remote.id.uuidString)"
  }

  public let local: BirthdayRecord
  public let remote: APIBirthday

  public init(local: BirthdayRecord, remote: APIBirthday) {
    self.local = local
    self.remote = remote
  }
}

public struct SnapshotImportPreview: Equatable, Sendable {
  public let remoteCount: Int
  public let duplicates: [DuplicateCandidate]

  public init(remoteCount: Int, duplicates: [DuplicateCandidate]) {
    self.remoteCount = remoteCount
    self.duplicates = duplicates
  }
}

public enum SnapshotImportError: Error, Equatable, Sendable {
  case duplicateRemoteID(UUID)
  case missingDuplicateDecision
}

public enum SnapshotImporter {
  public static func preview(
    local: [BirthdayRecord],
    remote: [APIBirthday]
  ) -> SnapshotImportPreview {
    let activeLocal = local.filter { $0.deletedAt == nil }
    let activeRemote = remote.filter { $0.deletedAt == nil }
    var duplicates: [DuplicateCandidate] = []

    for remoteRecord in activeRemote {
      let remoteKey = normalizedKey(
        name: remoteRecord.name,
        month: remoteRecord.lunarMonth,
        day: remoteRecord.lunarDay,
        isLeapMonth: remoteRecord.isLeapMonth
      )
      for localRecord in activeLocal where localRecord.id != remoteRecord.id {
        let localKey = normalizedKey(
          name: localRecord.name,
          month: localRecord.lunarBirthday.month,
          day: localRecord.lunarBirthday.day,
          isLeapMonth: localRecord.lunarBirthday.isLeapMonth
        )
        if localKey == remoteKey {
          duplicates.append(DuplicateCandidate(local: localRecord, remote: remoteRecord))
        }
      }
    }

    return SnapshotImportPreview(remoteCount: remote.count, duplicates: duplicates)
  }

  private struct NormalizedKey: Hashable {
    let name: String
    let month: Int
    let day: Int
    let isLeapMonth: Bool
  }

  private static func normalizedKey(
    name: String,
    month: Int,
    day: Int,
    isLeapMonth: Bool
  ) -> NormalizedKey {
    NormalizedKey(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      ),
      month: month,
      day: day,
      isLeapMonth: isLeapMonth
    )
  }
}
