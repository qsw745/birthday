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

public struct SevenColumnGridMetrics: Equatable, Sendable {
  public static let columnCount = 7
  public static let minimumCellWidth: CGFloat = 44

  public let containerWidth: CGFloat
  public let pageHorizontalPadding: CGFloat
  public let cardHorizontalPadding: CGFloat
  public let columnSpacing: CGFloat

  public var availableCellWidth: CGFloat {
    let horizontalInsets = 2 * (pageHorizontalPadding + cardHorizontalPadding)
    let totalSpacing = CGFloat(Self.columnCount - 1) * columnSpacing
    return max(
      0,
      (containerWidth - horizontalInsets - totalSpacing) / CGFloat(Self.columnCount)
    )
  }

  public static func make(containerWidth: CGFloat) -> SevenColumnGridMetrics {
    if containerWidth <= 340 {
      return SevenColumnGridMetrics(
        containerWidth: containerWidth,
        pageHorizontalPadding: 6,
        cardHorizontalPadding: 0,
        columnSpacing: 0
      )
    }

    if containerWidth <= 390 {
      return SevenColumnGridMetrics(
        containerWidth: containerWidth,
        pageHorizontalPadding: 12,
        cardHorizontalPadding: 8,
        columnSpacing: 2
      )
    }

    return SevenColumnGridMetrics(
      containerWidth: containerWidth,
      pageHorizontalPadding: 16,
      cardHorizontalPadding: 12,
      columnSpacing: 4
    )
  }
}
