import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

@Suite(.serialized)
struct BirthdayExportServiceTests {
  @Test func exportIsStableVersionedAndContainsOnlyVisibleUserFields() async throws {
    let container = try BirthdayModelContainer.make(
      configuration: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let store = BirthdayStore(modelContainer: container)
    let service = BirthdayExportService(store: store)
    let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let createdAt = ISO8601DateFormatter().date(from: "2026-09-01T02:03:04Z")!
    let exportedAt = ISO8601DateFormatter().date(from: "2026-09-05T02:03:04Z")!
    let laterID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let earlierID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let deletedID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let privateReminder = ReminderConfig(
      timeMinutes: 615,
      notifyDayBefore: false,
      notifySameDay: true,
      emailEnabled: true,
      emailAddress: "private@example.com",
      emailMessage: "不要导出这段隐藏邮件内容"
    )

    _ = try await store.save(
      BirthdayDraft(
        name: "八月生日",
        lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: privateReminder
      ),
      id: laterID,
      now: createdAt,
      timeZone: timeZone
    )
    _ = try await store.save(
      BirthdayDraft(
        name: "正月生日",
        lunarBirthday: LunarBirthday(month: 1, day: 2, isLeapMonth: true),
        reminder: .defaults
      ),
      id: earlierID,
      now: createdAt.addingTimeInterval(1),
      timeZone: timeZone
    )
    _ = try await store.save(
      BirthdayDraft(
        name: "已删除生日",
        lunarBirthday: LunarBirthday(month: 2, day: 3, isLeapMonth: false),
        reminder: .defaults
      ),
      id: deletedID,
      now: createdAt.addingTimeInterval(2),
      timeZone: timeZone
    )
    try await store.softDelete(id: deletedID, now: createdAt.addingTimeInterval(3))

    let first = try await service.makeExport(at: exportedAt, timeZone: timeZone)
    let second = try await service.makeExport(at: exportedAt, timeZone: timeZone)

    #expect(first.fileName == "岁时-生日数据-2026-09-05.json")
    #expect(first.visibleBirthdayCount == 2)
    #expect(first.data == second.data)

    let root = try #require(
      try JSONSerialization.jsonObject(with: first.data) as? [String: Any]
    )
    #expect(root["formatVersion"] as? Int == 1)
    #expect(root["exportedAt"] as? String == "2026-09-05T02:03:04.000Z")
    let birthdays = try #require(root["birthdays"] as? [[String: Any]])
    #expect(birthdays.compactMap { $0["id"] as? String } == [
      earlierID.uuidString.lowercased(), laterID.uuidString.lowercased(),
    ])
    #expect(birthdays.compactMap { $0["name"] as? String } == ["正月生日", "八月生日"])

    let firstBirthday = try #require(birthdays.first)
    let lunar = try #require(firstBirthday["lunarBirthday"] as? [String: Any])
    #expect(lunar["month"] as? Int == 1)
    #expect(lunar["day"] as? Int == 2)
    #expect(lunar["isLeapMonth"] as? Bool == true)
    let reminder = try #require(firstBirthday["reminder"] as? [String: Any])
    #expect(reminder["timeMinutes"] as? Int == 540)
    #expect(reminder["notifyDayBefore"] as? Bool == true)
    #expect(reminder["notifySameDay"] as? Bool == true)

    let allKeys = recursivelyCollectedKeys(from: root)
    let forbiddenKeys: Set<String> = [
      "accessToken", "refreshToken", "version", "syncState", "changeTag", "zoneName",
      "accountFingerprint", "conflict", "authorizationStatus", "deletedAt", "nextSolarDate",
      "emailEnabled", "emailAddress", "emailMessage",
    ]
    #expect(allKeys.isDisjoint(with: forbiddenKeys))
    let jsonText = try #require(String(data: first.data, encoding: .utf8))
    #expect(!jsonText.contains("private@example.com"))
    #expect(!jsonText.contains("不要导出这段隐藏邮件内容"))
    #expect(!jsonText.contains("已删除生日"))
  }
}

private func recursivelyCollectedKeys(from value: Any) -> Set<String> {
  if let dictionary = value as? [String: Any] {
    return dictionary.reduce(into: Set(dictionary.keys)) { result, pair in
      result.formUnion(recursivelyCollectedKeys(from: pair.value))
    }
  }
  if let array = value as? [Any] {
    return array.reduce(into: []) { result, item in
      result.formUnion(recursivelyCollectedKeys(from: item))
    }
  }
  return []
}
