import Foundation

public struct CalendarProjection: Sendable {
  public let monthStart: Date
  public let recordsByDay: [Int: [BirthdayRecord]]

  public var daysWithBirthdays: [Int] {
    recordsByDay.keys.sorted()
  }

  public func records(onDay day: Int) -> [BirthdayRecord] {
    recordsByDay[day] ?? []
  }

  public static func make(
    records: [BirthdayRecord],
    monthContaining date: Date,
    timeZone: TimeZone
  ) -> CalendarProjection {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    let selectedComponents = calendar.dateComponents([.year, .month], from: date)
    let monthStart = calendar.date(
      from: DateComponents(
        timeZone: timeZone,
        year: selectedComponents.year,
        month: selectedComponents.month,
        day: 1
      )) ?? date

    var recordsByDay: [Int: [BirthdayRecord]] = [:]
    for record in records {
      guard record.deletedAt == nil, let nextSolarDate = record.nextSolarDate else { continue }
      let components = calendar.dateComponents([.year, .month, .day], from: nextSolarDate)
      guard components.year == selectedComponents.year,
        components.month == selectedComponents.month,
        let day = components.day
      else { continue }

      recordsByDay[day, default: []].append(record)
    }

    return CalendarProjection(
      monthStart: monthStart,
      recordsByDay: recordsByDay.mapValues { records in
        records.sorted { lhs, rhs in
          let lhsDate = lhs.nextSolarDate ?? .distantFuture
          let rhsDate = rhs.nextSolarDate ?? .distantFuture
          if lhsDate != rhsDate {
            return lhsDate < rhsDate
          }
          if lhs.name != rhs.name {
            return lhs.name < rhs.name
          }
          return lhs.id.uuidString < rhs.id.uuidString
        }
      }
    )
  }
}
