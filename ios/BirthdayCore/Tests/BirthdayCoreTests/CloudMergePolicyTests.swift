import Foundation
import Testing

@testable import BirthdayCore

@Test func cloudMergeAcceptsTheOnlySideChangedFromBase() throws {
  let base = try cloudSnapshot(name: "妈妈")
  let localEdit = try cloudSnapshot(name: "妈妈（本机）")
  let remoteEdit = try cloudSnapshot(name: "妈妈（iCloud）")

  #expect(try CloudMergePolicy.decide(base: base, local: localEdit, remote: base) == .acceptLocal)
  #expect(try CloudMergePolicy.decide(base: base, local: base, remote: remoteEdit) == .acceptRemote)
}

@Test func cloudMergeTreatsMatchingContentAndTimestampOnlyChangesAsUnchanged() throws {
  let base = try cloudSnapshot(name: "妈妈")
  let sameContentLater = try cloudSnapshot(
    name: "妈妈",
    updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
  )
  let sharedEditLocal = try cloudSnapshot(
    name: "共同修改",
    updatedAt: Date(timeIntervalSince1970: 1_700_001_100)
  )
  let sharedEditRemote = try cloudSnapshot(
    name: "共同修改",
    updatedAt: Date(timeIntervalSince1970: 1_700_001_200)
  )

  #expect(
    try CloudMergePolicy.decide(base: base, local: sameContentLater, remote: base)
      == .unchanged
  )
  #expect(
    try CloudMergePolicy.decide(base: base, local: sharedEditLocal, remote: sharedEditRemote)
      == .unchanged
  )
}

@Test func cloudMergePreservesConcurrentEditsAsConflicts() throws {
  let base = try cloudSnapshot(name: "妈妈")
  let local = try cloudSnapshot(name: "本机妈妈")
  let remote = try cloudSnapshot(name: "云端妈妈")

  #expect(
    try CloudMergePolicy.decide(base: base, local: local, remote: remote)
      == .conflict(kind: .editEdit)
  )
}

@Test func cloudMergeClassifiesDeleteEditDirectionsAndConvergesDoubleDeletes() throws {
  let deletedAt = Date(timeIntervalSince1970: 1_700_002_000)
  let base = try cloudSnapshot(name: "妈妈")
  let localDeleted = try cloudSnapshot(name: "妈妈", deletedAt: deletedAt)
  let remoteDeleted = try cloudSnapshot(
    name: "云端旧名字",
    deletedAt: deletedAt.addingTimeInterval(30)
  )
  let localEdited = try cloudSnapshot(name: "本机编辑")
  let remoteEdited = try cloudSnapshot(name: "云端编辑")

  #expect(
    try CloudMergePolicy.decide(base: base, local: localDeleted, remote: remoteEdited)
      == .conflict(kind: .localDeleteRemoteEdit)
  )
  #expect(
    try CloudMergePolicy.decide(base: base, local: localEdited, remote: remoteDeleted)
      == .conflict(kind: .localEditRemoteDelete)
  )
  #expect(
    try CloudMergePolicy.decide(base: base, local: localDeleted, remote: remoteDeleted)
      == .unchanged
  )
}

@Test func cloudMergePerformsSafeInitialUnionWithoutTreatingEmptyCloudAsAuthority() throws {
  let local = try cloudSnapshot(name: "仅本机")
  let remote = try cloudSnapshot(name: "仅云端")
  let matching = try cloudSnapshot(name: "相同")
  let differingLocal = try cloudSnapshot(name: "本机版本")
  let differingRemote = try cloudSnapshot(name: "云端版本")

  #expect(try CloudMergePolicy.decide(base: nil, local: local, remote: nil) == .acceptLocal)
  #expect(try CloudMergePolicy.decide(base: nil, local: nil, remote: remote) == .acceptRemote)
  #expect(try CloudMergePolicy.decide(base: nil, local: matching, remote: matching) == .unchanged)
  #expect(
    try CloudMergePolicy.decide(base: nil, local: differingLocal, remote: differingRemote)
      == .conflict(kind: .editEdit)
  )
  #expect(try CloudMergePolicy.decide(base: nil, local: nil, remote: nil) == .unchanged)
}

@Test func cloudMergeNeverCombinesSameNameRecordsWithDifferentUUIDs() throws {
  let local = try cloudSnapshot(name: "妈妈")
  let remote = try cloudSnapshot(
    id: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
    name: "妈妈"
  )

  #expect(throws: CloudMergePolicyError.differentEntityIdentifiers) {
    try CloudMergePolicy.decide(base: nil, local: local, remote: remote)
  }
}

private func cloudSnapshot(
  id: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
  name: String,
  deletedAt: Date? = nil,
  updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_600)
) throws -> CloudBirthdaySnapshot {
  try CloudBirthdaySnapshot(
    id: id,
    name: name,
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    reminderTimeMinutes: 510,
    notifyDayBefore: true,
    notifySameDay: true,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: updatedAt,
    deletedAt: deletedAt
  )
}
