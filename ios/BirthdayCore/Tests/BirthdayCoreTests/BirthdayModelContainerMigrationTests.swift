import CryptoKit
import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

@Test func frozenV1DiskStoreMigratesToV2WithoutLosingSyncState() throws {
  try withTemporaryStore { storeURL in
    let fixture = MigrationFixture()
    let legacy = try ModelContainer(
      for: Schema(versionedSchema: BirthdaySchemaV1.self),
      configurations: ModelConfiguration(url: storeURL)
    )
    try fixture.seedLegacy(in: legacy)

    let upgraded = try BirthdayModelContainer.make(
      configuration: ModelConfiguration(url: storeURL)
    )
    try fixture.assertPreservedAndConflictWritable(in: upgraded)
  }
}

@Test func previouslyUnversionedThreeModelDiskStoreIsAcceptedByV2MigrationPlan() throws {
  try withTemporaryStore { storeURL in
    let fixture = MigrationFixture()
    try copyHistoricalUnversionedFixture(to: storeURL)

    let upgraded = try BirthdayModelContainer.make(
      configuration: ModelConfiguration(url: storeURL)
    )
    try fixture.assertPreservedAndConflictWritable(in: upgraded)
  }
}

@Test func historicalUnversionedFixtureMatchesReviewedSHA256() throws {
  let digest = SHA256.hash(data: try Data(contentsOf: historicalUnversionedFixtureURL()))
  let hexDigest = digest.map { String(format: "%02x", $0) }.joined()

  #expect(hexDigest == "eb16f77c40cc12eb91715b75f975cb51a013d2a38149f4b496c359c10bedb769")
}

@Test func frozenV2PreCloudStoreMigratesToV3WithoutLosingLocalOrServerState() throws {
  try withTemporaryStore { storeURL in
    try copyV2PreCloudFixture(to: storeURL)

    let upgraded = try BirthdayModelContainer.make(
      configuration: ModelConfiguration(url: storeURL)
    )
    let context = ModelContext(upgraded)

    let birthdays = try context.fetch(FetchDescriptor<BirthdayEntity>())
    let birthdaysByID = Dictionary(uniqueKeysWithValues: birthdays.map { ($0.id, $0) })
    let activeBirthdayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let tombstoneID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    #expect(birthdays.count == 2)
    #expect(birthdaysByID[activeBirthdayID]?.name == "V2 妈妈")
    #expect(birthdaysByID[activeBirthdayID]?.deletedAt == nil)
    #expect(birthdaysByID[tombstoneID]?.name == "V2 已删除好友")
    #expect(birthdaysByID[tombstoneID]?.deletedAt == Date(timeIntervalSince1970: 1_700_000_300))

    let operations = try context.fetch(FetchDescriptor<SyncOperationEntity>())
    #expect(operations.map(\.operationId) == [
      UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    ])
    #expect(operations.map(\.baseVersion) == [7])
    #expect(operations.map(\.attemptCount) == [2])
    #expect(operations.map(\.lastErrorCategory) == ["network"])

    let metadata = try context.fetch(FetchDescriptor<SyncMetadataEntity>())
    #expect(metadata.map(\.key) == ["primary"])
    #expect(metadata.map(\.cursor) == [19])

    let serverConflicts = try context.fetch(FetchDescriptor<SyncConflictEntity>())
    #expect(serverConflicts.map(\.entityId) == [
      UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    ])
    #expect(serverConflicts.map(\.kindRaw) == [SyncConflictKind.editEdit.rawValue])
    #expect(serverConflicts.map(\.localSnapshotJSON) == [
      Data(#"{"side":"local","name":"本机妈妈"}"#.utf8)
    ])
    #expect(serverConflicts.map(\.remoteSnapshotJSON) == [
      Data(#"{"side":"remote","name":"云端妈妈"}"#.utf8)
    ])

    #expect(try context.fetchCount(FetchDescriptor<CloudRecordStateEntity>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<CloudSyncEngineStateEntity>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<CloudSyncConflictEntity>()) == 0)
  }
}

@Test func frozenV2PreCloudFixtureMatchesReviewedSHA256() throws {
  let digest = SHA256.hash(data: try Data(contentsOf: v2PreCloudFixtureURL()))
  let hexDigest = digest.map { String(format: "%02x", $0) }.joined()

  #expect(hexDigest == "1dd21673d890fff38f97f9cc7de92b52ba1d607cfb9faf2be082ef090766b4d1")
}

private func copyHistoricalUnversionedFixture(to storeURL: URL) throws {
  try FileManager.default.copyItem(at: historicalUnversionedFixtureURL(), to: storeURL)
}

private func historicalUnversionedFixtureURL() throws -> URL {
  try #require(
    Bundle.module.url(
      forResource: "d457260-unversioned",
      withExtension: "store",
      subdirectory: "Fixtures"
    )
  )
}

private func copyV2PreCloudFixture(to storeURL: URL) throws {
  try FileManager.default.copyItem(at: v2PreCloudFixtureURL(), to: storeURL)
}

private func v2PreCloudFixtureURL() throws -> URL {
  try #require(
    Bundle.module.url(
      forResource: "v2-pre-cloud",
      withExtension: "store",
      subdirectory: "Fixtures"
    )
  )
}

private struct MigrationFixture {
  let birthdayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  let operationID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let payload = Data(#"{"name":"旧版妈妈"}"#.utf8)

  func seedLegacy(in container: ModelContainer) throws {
    let context = ModelContext(container)
    let birthday = BirthdaySchemaV1.BirthdayEntity(
      id: birthdayID,
      draft: BirthdayDraft(
        name: "旧版妈妈",
        lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ),
      nextSolarDate: now.addingTimeInterval(86_400),
      now: now
    )
    birthday.syncStateRaw = SyncState.pending.rawValue
    context.insert(birthday)
    context.insert(
      BirthdaySchemaV1.SyncOperationEntity(
        operationId: operationID,
        entityId: birthdayID,
        operationType: "update",
        baseVersion: 7,
        payloadJSON: payload,
        createdAt: now.addingTimeInterval(60),
        attemptCount: 2,
        nextRetryAt: nil,
        lastErrorCategory: nil
      )
    )
    context.insert(BirthdaySchemaV1.SyncMetadataEntity(key: "primary", cursor: 9))
    try context.save()
  }

  func assertPreservedAndConflictWritable(in container: ModelContainer) throws {
    let context = ModelContext(container)

    let birthdays = try context.fetch(FetchDescriptor<BirthdayEntity>())
    #expect(birthdays.map(\.id) == [birthdayID])
    #expect(birthdays.map(\.name) == ["旧版妈妈"])
    #expect(birthdays.map(\.syncStateRaw) == [SyncState.pending.rawValue])

    let operations = try context.fetch(FetchDescriptor<SyncOperationEntity>())
    #expect(operations.map(\.operationId) == [operationID])
    #expect(operations.map(\.entityId) == [birthdayID])
    #expect(operations.map(\.operationType) == ["update"])
    #expect(operations.map(\.baseVersion) == [7])
    #expect(operations.map(\.payloadJSON) == [payload])
    #expect(operations.map(\.attemptCount) == [2])

    let metadata = try context.fetch(FetchDescriptor<SyncMetadataEntity>())
    #expect(metadata.map(\.key) == ["primary"])
    #expect(metadata.map(\.cursor) == [9])

    context.insert(
      SyncConflictEntity(
        entityId: birthdayID,
        operationId: operationID,
        localSnapshotJSON: Data("{}".utf8),
        remoteSnapshotJSON: Data("{}".utf8),
        createdAt: now.addingTimeInterval(120),
        updatedAt: now.addingTimeInterval(120)
      )
    )
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<SyncConflictEntity>()) == 1)
  }
}

private func withTemporaryStore(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("birthday-schema-migration-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory.appendingPathComponent("Birthday.store"))
}
