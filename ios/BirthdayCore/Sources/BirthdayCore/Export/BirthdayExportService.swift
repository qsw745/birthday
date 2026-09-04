import Foundation

public struct BirthdayExportArtifact: Equatable, Sendable {
  public let fileName: String
  public let data: Data
  public let visibleBirthdayCount: Int

  public init(fileName: String, data: Data, visibleBirthdayCount: Int) {
    self.fileName = fileName
    self.data = data
    self.visibleBirthdayCount = visibleBirthdayCount
  }
}

public struct BirthdayExportService: Sendable {
  public static let currentFormatVersion = 1

  private let store: BirthdayStore

  public init(store: BirthdayStore) {
    self.store = store
  }

  public func makeExport(
    at exportDate: Date = Date(),
    timeZone: TimeZone = .current
  ) async throws -> BirthdayExportArtifact {
    let records = try await store.activeBirthdays()
      .sorted(by: Self.isOrderedBefore)
    let document = ExportDocument(
      formatVersion: Self.currentFormatVersion,
      exportedAt: Self.iso8601String(exportDate),
      birthdays: records.map(ExportBirthday.init)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(document)
    data.append(0x0A)

    return BirthdayExportArtifact(
      fileName: Self.fileName(for: exportDate, timeZone: timeZone),
      data: data,
      visibleBirthdayCount: records.count
    )
  }

  private static func isOrderedBefore(_ lhs: BirthdayRecord, _ rhs: BirthdayRecord) -> Bool {
    let left = lhs.lunarBirthday
    let right = rhs.lunarBirthday
    if left.month != right.month { return left.month < right.month }
    if left.isLeapMonth != right.isLeapMonth { return !left.isLeapMonth }
    if left.day != right.day { return left.day < right.day }
    if lhs.name != rhs.name { return lhs.name < rhs.name }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private static func fileName(for date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "岁时-生日数据-%04d-%02d-%02d.json",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }

  fileprivate static func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }
}

private struct ExportDocument: Encodable {
  let formatVersion: Int
  let exportedAt: String
  let birthdays: [ExportBirthday]
}

private struct ExportBirthday: Encodable {
  let id: String
  let name: String
  let lunarBirthday: ExportLunarBirthday
  let reminder: ExportReminder
  let createdAt: String
  let updatedAt: String

  init(record: BirthdayRecord) {
    id = record.id.uuidString.lowercased()
    name = record.name
    lunarBirthday = ExportLunarBirthday(
      month: record.lunarBirthday.month,
      day: record.lunarBirthday.day,
      isLeapMonth: record.lunarBirthday.isLeapMonth
    )
    reminder = ExportReminder(
      timeMinutes: record.reminder.timeMinutes,
      notifyDayBefore: record.reminder.notifyDayBefore,
      notifySameDay: record.reminder.notifySameDay
    )
    createdAt = BirthdayExportService.iso8601String(record.createdAt)
    updatedAt = BirthdayExportService.iso8601String(record.updatedAt)
  }
}

private struct ExportLunarBirthday: Encodable {
  let month: Int
  let day: Int
  let isLeapMonth: Bool
}

private struct ExportReminder: Encodable {
  let timeMinutes: Int
  let notifyDayBefore: Bool
  let notifySameDay: Bool
}
