import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

@Test func legacyThreeModelDiskStoreOpensWithConflictModelAvailable() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("birthday-schema-migration-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let storeURL = directory.appendingPathComponent("Birthday.store")
  let birthdayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

  try seedLegacyThreeModelStore(at: storeURL, birthdayID: birthdayID)

  let upgraded = try BirthdayModelContainer.make(
    configuration: ModelConfiguration(url: storeURL)
  )
  let context = ModelContext(upgraded)
  let birthdays = try context.fetch(FetchDescriptor<BirthdayEntity>())
  #expect(birthdays.map(\.id) == [birthdayID])
  #expect(birthdays.map(\.name) == ["旧版妈妈"])

  context.insert(
    SyncConflictEntity(
      entityId: birthdayID,
      operationId: nil,
      localSnapshotJSON: Data("{}".utf8),
      remoteSnapshotJSON: Data("{}".utf8),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
  )
  try context.save()
  #expect(try context.fetchCount(FetchDescriptor<SyncConflictEntity>()) == 1)
}

private func seedLegacyThreeModelStore(at storeURL: URL, birthdayID: UUID) throws {
  let legacy = try ModelContainer(
    for: BirthdayEntity.self,
    SyncOperationEntity.self,
    SyncMetadataEntity.self,
    configurations: ModelConfiguration(url: storeURL)
  )
  let context = ModelContext(legacy)
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let birthday = BirthdayEntity(
    id: birthdayID,
    draft: BirthdayDraft(
      name: "旧版妈妈",
      lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
      reminder: .defaults
    ),
    nextSolarDate: now.addingTimeInterval(86_400),
    now: now
  )
  birthday.syncStateRaw = SyncState.synced.rawValue
  context.insert(birthday)
  context.insert(SyncMetadataEntity(key: "primary", cursor: 9))
  try context.save()
}
