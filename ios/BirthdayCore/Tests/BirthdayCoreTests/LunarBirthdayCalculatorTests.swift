import Foundation
import Testing
@testable import BirthdayCore

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

private func isoDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func shanghaiGregorianComponents(_ date: Date) -> DateComponents {
    Calendar(identifier: .gregorian).dateComponents(in: shanghai, from: date)
}

@Test func maps2026LunarNewYear() throws {
    let result = try ChineseCalendarBirthdayCalculator().nextOccurrence(
        of: .init(month: 1, day: 1, isLeapMonth: false),
        reminderMinutes: 540,
        after: isoDate("2026-01-01T00:00:00Z"),
        in: shanghai
    )
    let components = shanghaiGregorianComponents(result)
    #expect(components.year == 2026 && components.month == 2 && components.day == 17 && components.hour == 9)
}

@Test func maps2026LunarMidAutumn() throws {
    let result = try ChineseCalendarBirthdayCalculator().nextOccurrence(
        of: .init(month: 8, day: 15, isLeapMonth: false),
        reminderMinutes: 540,
        after: isoDate("2026-01-01T00:00:00Z"),
        in: shanghai
    )
    let components = shanghaiGregorianComponents(result)
    #expect(components.year == 2026 && components.month == 9 && components.day == 25 && components.hour == 9)
}

@Test func usesLeapSixthMonthWhenPresent() throws {
    let result = try ChineseCalendarBirthdayCalculator().nextOccurrence(
        of: .init(month: 6, day: 1, isLeapMonth: true),
        reminderMinutes: 540,
        after: isoDate("2025-01-01T00:00:00Z"),
        in: shanghai
    )
    let components = shanghaiGregorianComponents(result)
    #expect(components.year == 2025 && components.month == 7 && components.day == 25)
}

@Test func fallsBackToOrdinaryMonthWhenLeapMonthIsMissing() throws {
    let result = try ChineseCalendarBirthdayCalculator().nextOccurrence(
        of: .init(month: 6, day: 1, isLeapMonth: true),
        reminderMinutes: 540,
        after: isoDate("2026-01-01T00:00:00Z"),
        in: shanghai
    )
    let components = shanghaiGregorianComponents(result)
    #expect(components.year == 2026 && components.month == 7 && components.day == 14 && components.hour == 9)
}

@Test func rollsPastOccurrenceIntoNextYear() throws {
    let result = try ChineseCalendarBirthdayCalculator().nextOccurrence(
        of: .init(month: 8, day: 15, isLeapMonth: false),
        reminderMinutes: 540,
        after: isoDate("2026-09-25T02:00:00Z"),
        in: shanghai
    )
    #expect(result > isoDate("2027-01-01T00:00:00Z"))
}
