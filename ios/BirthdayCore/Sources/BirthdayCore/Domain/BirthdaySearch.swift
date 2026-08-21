import Foundation

public enum BirthdaySearch {
  public static func filter(_ records: [BirthdayRecord], query: String) -> [BirthdayRecord] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return records }
    return records.filter { $0.name.localizedStandardContains(needle) }
  }

  public static func sortedByNextSolarDate(_ records: [BirthdayRecord]) -> [BirthdayRecord] {
    records.enumerated().sorted { left, right in
      switch (left.element.nextSolarDate, right.element.nextSolarDate) {
      case (let leftDate?, let rightDate?) where leftDate != rightDate:
        return leftDate < rightDate
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return left.offset < right.offset
      }
    }.map(\.element)
  }
}
