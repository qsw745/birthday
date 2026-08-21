import Foundation

@testable import BirthdayCore

extension BirthdayRecord {
  static func fixture(id: UUID, name: String, month: Int, day: Int, nextSolarDate: Date? = nil)
    -> BirthdayRecord
  {
    BirthdayRecord(
      id: id,
      name: name,
      lunarBirthday: LunarBirthday(month: month, day: day, isLeapMonth: false),
      reminder: .defaults,
      nextSolarDate: nextSolarDate,
      version: 0,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      deletedAt: nil,
      syncState: .pending
    )
  }
}
