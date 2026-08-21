import Foundation
import Testing

@testable import BirthdayCore

private let reminderPlannerTimeZone = TimeZone(identifier: "Asia/Shanghai")!
private let plannerNow = Date(timeIntervalSince1970: 1_788_000_000)

private struct StubLunarBirthdayCalculator: LunarBirthdayCalculating {
  let occurrenceForMonth: @Sendable (Int) -> Date

  func nextOccurrence(
    of birthday: LunarBirthday,
    reminderMinutes: Int,
    after now: Date,
    in timeZone: TimeZone
  ) throws -> Date {
    occurrenceForMonth(birthday.month)
  }
}

private func plannerRecord(
  id: UUID,
  name: String = "联系人",
  month: Int,
  day: Int = 1,
  notifyDayBefore: Bool = true,
  notifySameDay: Bool = true,
  deletedAt: Date? = nil
) -> BirthdayRecord {
  var record = BirthdayRecord.fixture(id: id, name: name, month: month, day: day)
  record.reminder.notifyDayBefore = notifyDayBefore
  record.reminder.notifySameDay = notifySameDay
  record.deletedAt = deletedAt
  return record
}

private func plannerUUID(_ value: String) -> UUID {
  UUID(uuidString: value)!
}

@Test func capsBirthdayNotificationsAtSixtyAndAddsMaintenance() throws {
  let records = (1...100).map { index in
    plannerRecord(id: UUID(), month: index)
  }
  let calculator = StubLunarBirthdayCalculator { month in
    plannerNow.addingTimeInterval(TimeInterval(month * 2 * 86_400))
  }

  let plan = try ReminderPlanner(calculator: calculator).makePlan(
    records: records,
    now: plannerNow,
    timeZone: reminderPlannerTimeZone
  )

  #expect(plan.birthdayNotifications.count == 60)
  #expect(plan.maintenanceNotification != nil)
  #expect(plan.coverageEnd == plan.birthdayNotifications.last?.triggerDate)
}

@Test func emitsDayBeforeAndSameDayIdentifiers() throws {
  let record = plannerRecord(
    id: plannerUUID("00000000-0000-0000-0000-000000000001"),
    name: "妈妈",
    month: 1
  )
  let occurrence = plannerNow.addingTimeInterval(10 * 86_400)
  let calculator = StubLunarBirthdayCalculator { _ in occurrence }

  let plan = try ReminderPlanner(calculator: calculator).makePlan(
    records: [record],
    now: plannerNow,
    timeZone: reminderPlannerTimeZone
  )

  #expect(plan.birthdayNotifications.map(\.kind) == [.dayBefore, .sameDay])
  #expect(Set(plan.birthdayNotifications.map(\.identifier)).count == 2)
  #expect(
    plan.birthdayNotifications.map(\.identifier) == [
      "birthday.00000000-0000-0000-0000-000000000001.dayBefore.1788777600",
      "birthday.00000000-0000-0000-0000-000000000001.sameDay.1788864000",
    ])
}

@Test func filtersCandidatesAtOrBeforeNow() throws {
  let expired = plannerRecord(id: plannerUUID("00000000-0000-0000-0000-000000000001"), month: 1)
  let future = plannerRecord(id: plannerUUID("00000000-0000-0000-0000-000000000002"), month: 2)
  let calculator = StubLunarBirthdayCalculator { month in
    month == 1 ? plannerNow : plannerNow.addingTimeInterval(3 * 86_400)
  }

  let plan = try ReminderPlanner(calculator: calculator).makePlan(
    records: [expired, future],
    now: plannerNow,
    timeZone: reminderPlannerTimeZone
  )

  #expect(plan.birthdayNotifications.map(\.birthdayId) == [future.id, future.id])
  #expect(plan.birthdayNotifications.allSatisfy { $0.triggerDate > plannerNow })
}

@Test func respectsDisabledReminderSwitches() throws {
  let record = plannerRecord(
    id: plannerUUID("00000000-0000-0000-0000-000000000001"),
    month: 1,
    notifyDayBefore: false,
    notifySameDay: false
  )
  let calculator = StubLunarBirthdayCalculator { _ in plannerNow.addingTimeInterval(10 * 86_400) }

  let plan = try ReminderPlanner(calculator: calculator).makePlan(
    records: [record],
    now: plannerNow,
    timeZone: reminderPlannerTimeZone
  )

  #expect(plan.birthdayNotifications.isEmpty)
  #expect(plan.maintenanceNotification == nil)
  #expect(plan.coverageEnd == nil)
}

@Test func ignoresSoftDeletedRecords() throws {
  let deleted = plannerRecord(
    id: plannerUUID("00000000-0000-0000-0000-000000000001"),
    month: 1,
    deletedAt: plannerNow
  )
  let active = plannerRecord(id: plannerUUID("00000000-0000-0000-0000-000000000002"), month: 2)
  let calculator = StubLunarBirthdayCalculator { _ in plannerNow.addingTimeInterval(10 * 86_400) }

  let plan = try ReminderPlanner(calculator: calculator).makePlan(
    records: [deleted, active],
    now: plannerNow,
    timeZone: reminderPlannerTimeZone
  )

  #expect(plan.birthdayNotifications.map(\.birthdayId) == [active.id, active.id])
}

@Test func ordersCandidatesAtTheSameTimeByIdentifier() throws {
  let first = plannerRecord(id: plannerUUID("00000000-0000-0000-0000-000000000001"), month: 1)
  let second = plannerRecord(id: plannerUUID("00000000-0000-0000-0000-000000000002"), month: 2)
  let occurrence = plannerNow.addingTimeInterval(10 * 86_400)
  let calculator = StubLunarBirthdayCalculator { _ in occurrence }

  let plan = try ReminderPlanner(calculator: calculator).makePlan(
    records: [second, first],
    now: plannerNow,
    timeZone: reminderPlannerTimeZone
  )

  #expect(
    plan.birthdayNotifications.map(\.birthdayId) == [first.id, second.id, first.id, second.id])
}

@Test func addsMaintenanceOnlyWhenItCanStillTriggerAfterNow() throws {
  let record = plannerRecord(
    id: plannerUUID("00000000-0000-0000-0000-000000000001"),
    month: 1,
    notifyDayBefore: false
  )
  let calculator = StubLunarBirthdayCalculator { month in
    plannerNow.addingTimeInterval(TimeInterval(month == 1 ? 30 : 31) * 86_400)
  }

  let boundaryPlan = try ReminderPlanner(calculator: calculator).makePlan(
    records: [record],
    now: plannerNow,
    timeZone: reminderPlannerTimeZone
  )
  var laterRecord = record
  laterRecord.lunarBirthday.month = 2
  let laterPlan = try ReminderPlanner(calculator: calculator).makePlan(
    records: [laterRecord],
    now: plannerNow,
    timeZone: reminderPlannerTimeZone
  )

  #expect(boundaryPlan.maintenanceNotification == nil)
  #expect(laterPlan.maintenanceNotification?.kind == .maintenance)
  #expect(laterPlan.maintenanceNotification?.triggerDate == plannerNow.addingTimeInterval(86_400))
  #expect(laterPlan.maintenanceNotification?.identifier == "birthday.maintenance.1790678400")
}
