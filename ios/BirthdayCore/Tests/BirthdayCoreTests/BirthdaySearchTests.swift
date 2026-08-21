import Foundation
import Testing

@testable import BirthdayCore

@Test func filtersByTrimmedCaseInsensitiveName() {
  let records = [
    BirthdayRecord.fixture(id: UUID(), name: "Alice", month: 1, day: 1),
    BirthdayRecord.fixture(id: UUID(), name: "妈妈", month: 8, day: 15),
  ]

  #expect(BirthdaySearch.filter(records, query: " alice ").map(\.name) == ["Alice"])
  #expect(BirthdaySearch.filter(records, query: "妈").map(\.name) == ["妈妈"])
}

@Test func filtersNamesWithoutRequiringDiacritics() {
  let records = [
    BirthdayRecord.fixture(id: UUID(), name: "José", month: 3, day: 7),
    BirthdayRecord.fixture(id: UUID(), name: "Joseph", month: 4, day: 8),
  ]

  #expect(BirthdaySearch.filter(records, query: "jose").map(\.name) == ["José", "Joseph"])
}

@Test func emptyQueryPreservesInputOrder() {
  let ids = [UUID(), UUID(), UUID()]
  let records = [
    BirthdayRecord.fixture(id: ids[0], name: "乙", month: 2, day: 2),
    BirthdayRecord.fixture(id: ids[1], name: "甲", month: 1, day: 1),
    BirthdayRecord.fixture(id: ids[2], name: "丙", month: 3, day: 3),
  ]

  #expect(BirthdaySearch.filter(records, query: " \n ").map(\.id) == ids)
}

@Test func sortsByNextSolarDateAndPreservesEqualDateOrder() {
  let early = Date(timeIntervalSince1970: 100)
  let same = Date(timeIntervalSince1970: 200)
  let late = Date(timeIntervalSince1970: 300)
  let records = [
    BirthdayRecord.fixture(id: UUID(), name: "稍后", month: 1, day: 1, nextSolarDate: late),
    BirthdayRecord.fixture(id: UUID(), name: "同日甲", month: 1, day: 2, nextSolarDate: same),
    BirthdayRecord.fixture(id: UUID(), name: "未计算", month: 1, day: 3),
    BirthdayRecord.fixture(id: UUID(), name: "最早", month: 1, day: 4, nextSolarDate: early),
    BirthdayRecord.fixture(id: UUID(), name: "同日乙", month: 1, day: 5, nextSolarDate: same),
  ]

  #expect(
    BirthdaySearch.sortedByNextSolarDate(records).map(\.name)
      == ["最早", "同日甲", "同日乙", "稍后", "未计算"]
  )
}
