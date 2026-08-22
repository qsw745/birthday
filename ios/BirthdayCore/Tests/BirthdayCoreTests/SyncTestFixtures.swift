import Foundation
import SwiftData

@testable import BirthdayCore

func makeSyncContainer() throws -> ModelContainer {
  try ModelContainer(
    for: BirthdayEntity.self,
    SyncOperationEntity.self,
    SyncMetadataEntity.self,
    SyncConflictEntity.self,
    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
  )
}

func makeSyncStore() throws -> BirthdayStore {
  BirthdayStore(modelContainer: try makeSyncContainer())
}

let canonicalRemoteReminder = ReminderConfig(
  timeMinutes: 540,
  notifyDayBefore: true,
  notifySameDay: true,
  emailEnabled: false,
  emailAddress: "",
  emailMessage: ""
)

func makeAPIBirthday(
  id: UUID = UUID(),
  name: String = "妈妈",
  month: Int = 8,
  day: Int = 15,
  isLeapMonth: Bool = false,
  reminder: ReminderConfig = canonicalRemoteReminder,
  nextSolarDate: Date? = nil,
  version: Int64 = 1,
  createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
  updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
  deletedAt: Date? = nil
) -> APIBirthday {
  APIBirthday(
    id: id,
    name: name,
    lunarMonth: month,
    lunarDay: day,
    isLeapMonth: isLeapMonth,
    reminder: reminder,
    nextSolarDate: nextSolarDate,
    version: version,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt
  )
}

func insertSyncedBirthday(
  _ remote: APIBirthday,
  into container: ModelContainer
) throws {
  let context = ModelContext(container)
  let entity = BirthdayEntity(
    id: remote.id,
    draft: BirthdayDraft(
      name: remote.name,
      lunarBirthday: LunarBirthday(
        month: remote.lunarMonth,
        day: remote.lunarDay,
        isLeapMonth: remote.isLeapMonth
      ),
      reminder: remote.reminder
    ),
    nextSolarDate: remote.nextSolarDate ?? remote.updatedAt,
    now: remote.createdAt
  )
  entity.nextSolarDate = remote.nextSolarDate
  entity.version = remote.version
  entity.updatedAt = remote.updatedAt
  entity.deletedAt = remote.deletedAt
  entity.syncStateRaw = SyncState.synced.rawValue
  context.insert(entity)
  try context.save()
}
