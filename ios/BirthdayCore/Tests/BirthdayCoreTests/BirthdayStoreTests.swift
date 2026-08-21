import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

private func makeStore() throws -> BirthdayStore {
  let container = try ModelContainer(
    for: BirthdayEntity.self,
    SyncOperationEntity.self,
    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
  )
  return BirthdayStore(modelContainer: container)
}

private let storeTimeZone = TimeZone(identifier: "Asia/Shanghai")!
private let storeNow = Date(timeIntervalSince1970: 1_788_000_000)

@Test func savePersistsBirthdayAndOutboxAtomically() async throws {
  let store = try makeStore()
  let draft = BirthdayDraft(
    name: "妈妈",
    lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false),
    reminder: .defaults
  )

  let saved = try await store.save(draft, id: nil, now: storeNow, timeZone: storeTimeZone)

  #expect(await store.activeBirthdays().map(\.id) == [saved.id])
  #expect(await store.pendingOperations().count == 1)
}

@Test func saveRoundTripsAllReminderFieldsAndInitialVersion() async throws {
  let store = try makeStore()
  let reminder = ReminderConfig(
    timeMinutes: 615,
    notifyDayBefore: false,
    notifySameDay: true,
    emailEnabled: true,
    emailAddress: "a@example.com",
    emailMessage: "记得打电话"
  )

  let saved = try await store.save(
    .init(
      name: "  妈妈  ", lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false),
      reminder: reminder),
    id: nil,
    now: storeNow,
    timeZone: storeTimeZone
  )

  #expect(saved.name == "妈妈")
  #expect(saved.reminder == reminder)
  #expect(saved.version == 0)
  #expect(await store.activeBirthdays() == [saved])
}

@Test func saveQueuesARecoverableFullRecordPayload() async throws {
  let store = try makeStore()
  let saved = try await store.save(
    .init(
      name: "奶奶",
      lunarBirthday: .init(month: 1, day: 1, isLeapMonth: true),
      reminder: .init(
        timeMinutes: 300,
        notifyDayBefore: true,
        notifySameDay: false,
        emailEnabled: true,
        emailAddress: "grandma@example.com",
        emailMessage: "生日快乐"
      )
    ),
    id: nil,
    now: storeNow,
    timeZone: storeTimeZone
  )
  let operation = try #require(await store.pendingOperations().first)

  #expect(try JSONDecoder().decode(BirthdayRecord.self, from: operation.payloadJSON) == saved)
}

@Test func activeBirthdaysSortEqualDatesByCreationOrder() async throws {
  let store = try makeStore()
  let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  let draft = BirthdayDraft(
    name: "同日生日",
    lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false),
    reminder: .defaults
  )

  _ = try await store.save(draft, id: firstID, now: storeNow, timeZone: storeTimeZone)
  _ = try await store.save(draft, id: secondID, now: storeNow, timeZone: storeTimeZone)

  #expect(await store.activeBirthdays().map(\.id) == [firstID, secondID])
}

@Test func softDeleteHidesRecordAndCreatesDeleteOperation() async throws {
  let store = try makeStore()
  let saved = try await store.save(
    .init(
      name: "爸爸", lunarBirthday: .init(month: 9, day: 3, isLeapMonth: false), reminder: .defaults),
    id: nil,
    now: storeNow,
    timeZone: storeTimeZone
  )

  try await store.softDelete(id: saved.id, now: storeNow.addingTimeInterval(1))

  #expect(await store.activeBirthdays().isEmpty)
  #expect(await store.pendingOperations().last?.operationType == "delete")
}

@Test func restoreMakesRecordActiveAndQueuesUpsert() async throws {
  let store = try makeStore()
  let saved = try await store.save(
    .init(
      name: "爸爸", lunarBirthday: .init(month: 9, day: 3, isLeapMonth: false), reminder: .defaults),
    id: nil,
    now: storeNow,
    timeZone: storeTimeZone
  )
  try await store.softDelete(id: saved.id, now: storeNow.addingTimeInterval(1))

  try await store.restore(id: saved.id, now: storeNow.addingTimeInterval(2))

  #expect(await store.activeBirthdays().map(\.id) == [saved.id])
  #expect(await store.pendingOperations().last?.operationType == "upsert")
}
