import Foundation

public protocol LunarBirthdayCalculating: Sendable {
    func nextOccurrence(
        of birthday: LunarBirthday,
        reminderMinutes: Int,
        after now: Date,
        in timeZone: TimeZone
    ) throws -> Date
}

public enum LunarBirthdayCalculationError: Error, Equatable {
    case occurrenceNotFound
}

public struct ChineseCalendarBirthdayCalculator: LunarBirthdayCalculating {
    public init() {}

    public func nextOccurrence(
        of birthday: LunarBirthday,
        reminderMinutes: Int,
        after now: Date,
        in timeZone: TimeZone
    ) throws -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = timeZone
        let start = gregorian.startOfDay(for: now)

        if !birthday.isLeapMonth {
            for offset in 0..<800 {
                guard let day = gregorian.date(byAdding: .day, value: offset, to: start) else {
                    continue
                }
                let lunar = chinese.dateComponents([.month, .day, .isLeapMonth], from: day)
                guard lunar.month == birthday.month,
                      lunar.day == birthday.day,
                      lunar.isLeapMonth == false,
                      let candidate = wallTime(on: day, minutes: reminderMinutes, calendar: gregorian),
                      candidate > now else {
                    continue
                }
                return candidate
            }
            throw LunarBirthdayCalculationError.occurrenceNotFound
        }

        var activeLunarYear: String?
        var ordinaryCandidate: Date?
        var leapCandidate: Date?
        for offset in 0..<800 {
            guard let day = gregorian.date(byAdding: .day, value: offset, to: start) else {
                continue
            }
            let lunar = chinese.dateComponents([.era, .year, .month, .day, .isLeapMonth], from: day)
            let lunarYear = "\(lunar.era ?? 0):\(lunar.year ?? 0)"
            if let activeLunarYear, activeLunarYear != lunarYear {
                if let selected = leapCandidate ?? ordinaryCandidate {
                    return selected
                }
                ordinaryCandidate = nil
                leapCandidate = nil
            }
            activeLunarYear = lunarYear

            guard lunar.month == birthday.month,
                  lunar.day == birthday.day,
                  let candidate = wallTime(on: day, minutes: reminderMinutes, calendar: gregorian),
                  candidate > now else {
                continue
            }
            if lunar.isLeapMonth == true {
                leapCandidate = candidate
            } else {
                ordinaryCandidate = candidate
            }
        }
        if let selected = leapCandidate ?? ordinaryCandidate {
            return selected
        }
        throw LunarBirthdayCalculationError.occurrenceNotFound
    }

    private func wallTime(on day: Date, minutes: Int, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        return calendar.date(from: components)
    }
}
