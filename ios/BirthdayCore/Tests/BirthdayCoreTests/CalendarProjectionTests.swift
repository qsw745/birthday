import Foundation
import Testing

@testable import BirthdayCore

@Test func groupsRecordsByGregorianDayForSelectedMonth() {
  let records = [
    BirthdayRecord.fixture(
      id: UUID(),
      name: "妈妈",
      month: 8,
      day: 15,
      nextSolarDate: ISO8601DateFormatter().date(from: "2026-09-25T01:00:00Z")!
    )
  ]

  let projection = CalendarProjection.make(
    records: records,
    monthContaining: ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!,
    timeZone: TimeZone(identifier: "Asia/Shanghai")!
  )

  #expect(projection.daysWithBirthdays == [25])
  #expect(projection.records(onDay: 25).map(\.name) == ["妈妈"])
}

@Test func filtersUsingProvidedTimeZoneAtMonthBoundaries() {
  let formatter = ISO8601DateFormatter()
  let records = [
    BirthdayRecord.fixture(
      id: UUID(), name: "月初", month: 7, day: 20,
      nextSolarDate: formatter.date(from: "2026-08-31T16:00:00Z")!),
    BirthdayRecord.fixture(
      id: UUID(), name: "月末", month: 8, day: 20,
      nextSolarDate: formatter.date(from: "2026-09-30T15:59:59Z")!),
    BirthdayRecord.fixture(
      id: UUID(), name: "上月", month: 7, day: 19,
      nextSolarDate: formatter.date(from: "2026-08-31T15:59:59Z")!),
    BirthdayRecord.fixture(
      id: UUID(), name: "下月", month: 8, day: 21,
      nextSolarDate: formatter.date(from: "2026-09-30T16:00:00Z")!),
    BirthdayRecord.fixture(id: UUID(), name: "未计算", month: 8, day: 22),
  ]

  let projection = CalendarProjection.make(
    records: records,
    monthContaining: formatter.date(from: "2026-09-15T12:00:00Z")!,
    timeZone: TimeZone(identifier: "Asia/Shanghai")!
  )

  #expect(projection.daysWithBirthdays == [1, 30])
  #expect(projection.records(onDay: 1).map(\.name) == ["月初"])
  #expect(projection.records(onDay: 30).map(\.name) == ["月末"])
}

@Test func projectionIgnoresSoftDeletedRecords() {
  let date = ISO8601DateFormatter().date(from: "2026-09-12T01:00:00Z")!
  var deleted = BirthdayRecord.fixture(
    id: UUID(), name: "已删除", month: 8, day: 2, nextSolarDate: date)
  deleted.deletedAt = Date(timeIntervalSince1970: 1_800_000_000)

  let projection = CalendarProjection.make(
    records: [
      deleted,
      BirthdayRecord.fixture(
        id: UUID(), name: "保留", month: 8, day: 2, nextSolarDate: date),
    ],
    monthContaining: date,
    timeZone: TimeZone(secondsFromGMT: 0)!
  )

  #expect(projection.records(onDay: 12).map(\.name) == ["保留"])
}

@Test func sortsRecordsDeterministicallyWithinEachDay() {
  let formatter = ISO8601DateFormatter()
  let earlyDate = formatter.date(from: "2026-09-18T01:00:00Z")!
  let lateDate = formatter.date(from: "2026-09-18T03:00:00Z")!
  let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let highID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  let records = [
    BirthdayRecord.fixture(id: UUID(), name: "C", month: 8, day: 8, nextSolarDate: lateDate),
    BirthdayRecord.fixture(id: highID, name: "A", month: 8, day: 8, nextSolarDate: earlyDate),
    BirthdayRecord.fixture(id: UUID(), name: "B", month: 8, day: 8, nextSolarDate: earlyDate),
    BirthdayRecord.fixture(id: lowID, name: "A", month: 8, day: 8, nextSolarDate: earlyDate),
  ]

  let projection = CalendarProjection.make(
    records: records,
    monthContaining: earlyDate,
    timeZone: TimeZone(secondsFromGMT: 0)!
  )

  #expect(projection.records(onDay: 18).map(\.id) == [lowID, highID, records[2].id, records[0].id])
}

@Test func normalizesMonthStartInProvidedTimeZone() {
  let formatter = ISO8601DateFormatter()
  let projection = CalendarProjection.make(
    records: [],
    monthContaining: formatter.date(from: "2026-09-29T23:30:00Z")!,
    timeZone: TimeZone(identifier: "Asia/Shanghai")!
  )

  #expect(projection.monthStart == formatter.date(from: "2026-08-31T16:00:00Z")!)
}

@Test func keepsSevenCalendarColumnsAtLeastFortyFourPointsWideOnNarrowPhones() {
  for containerWidth in [CGFloat(320), CGFloat(375)] {
    let metrics = SevenColumnGridMetrics.make(containerWidth: containerWidth)

    #expect(metrics.availableCellWidth >= 44)
  }
}
