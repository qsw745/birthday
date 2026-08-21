import Foundation

public enum ReminderKind: String, Codable, Sendable {
  case dayBefore
  case sameDay
  case maintenance
}

public struct ReminderCandidate: Equatable, Sendable {
  public let identifier: String
  public let birthdayId: UUID?
  public let kind: ReminderKind
  public let triggerDate: Date
  public let title: String
  public let body: String

  public init(
    identifier: String,
    birthdayId: UUID?,
    kind: ReminderKind,
    triggerDate: Date,
    title: String,
    body: String
  ) {
    self.identifier = identifier
    self.birthdayId = birthdayId
    self.kind = kind
    self.triggerDate = triggerDate
    self.title = title
    self.body = body
  }
}

public struct ReminderPlan: Equatable, Sendable {
  public let birthdayNotifications: [ReminderCandidate]
  public let maintenanceNotification: ReminderCandidate?
  public let coverageEnd: Date?

  public init(
    birthdayNotifications: [ReminderCandidate],
    maintenanceNotification: ReminderCandidate?,
    coverageEnd: Date?
  ) {
    self.birthdayNotifications = birthdayNotifications
    self.maintenanceNotification = maintenanceNotification
    self.coverageEnd = coverageEnd
  }
}

public struct ReminderPlanner: Sendable {
  private let calculator: any LunarBirthdayCalculating

  public init(calculator: any LunarBirthdayCalculating = ChineseCalendarBirthdayCalculator()) {
    self.calculator = calculator
  }

  public func makePlan(records: [BirthdayRecord], now: Date, timeZone: TimeZone) throws
    -> ReminderPlan
  {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    var candidates: [ReminderCandidate] = []
    for record in records where record.deletedAt == nil {
      let occurrence = try calculator.nextOccurrence(
        of: record.lunarBirthday,
        reminderMinutes: record.reminder.timeMinutes,
        after: now,
        in: timeZone
      )

      if record.reminder.notifyDayBefore,
        let trigger = calendar.date(byAdding: .day, value: -1, to: occurrence),
        trigger > now
      {
        candidates.append(candidate(for: record, kind: .dayBefore, trigger: trigger))
      }

      if record.reminder.notifySameDay, occurrence > now {
        candidates.append(candidate(for: record, kind: .sameDay, trigger: occurrence))
      }
    }

    let birthdayNotifications = Array(
      candidates
        .sorted(by: candidateOrder)
        .prefix(60)
    )
    let coverageEnd = birthdayNotifications.last?.triggerDate
    let maintenanceNotification = maintenanceNotification(
      before: coverageEnd,
      now: now,
      calendar: calendar
    )

    return ReminderPlan(
      birthdayNotifications: birthdayNotifications,
      maintenanceNotification: maintenanceNotification,
      coverageEnd: coverageEnd
    )
  }

  private func candidate(for record: BirthdayRecord, kind: ReminderKind, trigger: Date)
    -> ReminderCandidate
  {
    let timestamp = String(Int(trigger.timeIntervalSince1970))
    let title = kind == .dayBefore ? "明天是\(record.name)的生日" : "今天是\(record.name)的生日"
    let body = kind == .dayBefore ? "提前准备一份心意吧。" : "别忘了送上生日祝福。"

    return ReminderCandidate(
      identifier: "birthday.\(record.id.uuidString).\(kind.rawValue).\(timestamp)",
      birthdayId: record.id,
      kind: kind,
      triggerDate: trigger,
      title: title,
      body: body
    )
  }

  private func maintenanceNotification(
    before coverageEnd: Date?,
    now: Date,
    calendar: Calendar
  ) -> ReminderCandidate? {
    guard let coverageEnd,
      let trigger = calendar.date(byAdding: .day, value: -30, to: coverageEnd),
      trigger > now
    else {
      return nil
    }

    return ReminderCandidate(
      identifier: "birthday.maintenance.\(Int(coverageEnd.timeIntervalSince1970))",
      birthdayId: nil,
      kind: .maintenance,
      triggerDate: trigger,
      title: "请更新生日提醒",
      body: "打开岁时，继续安排后续本地提醒。"
    )
  }

  private func candidateOrder(_ lhs: ReminderCandidate, _ rhs: ReminderCandidate) -> Bool {
    if lhs.triggerDate != rhs.triggerDate {
      return lhs.triggerDate < rhs.triggerDate
    }
    return lhs.identifier < rhs.identifier
  }
}
