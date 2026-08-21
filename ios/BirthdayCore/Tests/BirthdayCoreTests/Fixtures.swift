import Foundation

@testable import BirthdayCore

final class InMemorySecureTokenStore: SecureTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  func save(_ data: Data, account: String) throws {
    lock.withLock { values[account] = data }
  }

  func read(account: String) throws -> Data? {
    lock.withLock { values[account] }
  }

  func delete(account: String) throws {
    _ = lock.withLock { values.removeValue(forKey: account) }
  }

  var accounts: [String] {
    lock.withLock { values.keys.sorted() }
  }
}

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
