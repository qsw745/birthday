import BirthdayCore
import Foundation
import Observation

extension BirthdayDraft {
  init(record: BirthdayRecord) {
    self.init(
      name: record.name,
      lunarBirthday: record.lunarBirthday,
      reminder: record.reminder
    )
  }
}

enum BirthdayErrorMessage {
  static func text(for error: Error) -> String {
    switch error as? BirthdayValidationError {
    case .emptyName: return "请输入姓名"
    case .nameTooLong: return "姓名不能超过 64 个字符"
    case .invalidLunarMonth, .invalidLunarDay: return "请选择有效的农历生日"
    case .invalidReminderTime: return "请选择有效提醒时间"
    case .noNotificationSelected: return "至少开启一种本地提醒"
    case .invalidEmail: return "请输入有效收件邮箱"
    case .emailMessageTooLong: return "提醒内容过长"
    case nil: return "保存失败，输入内容已保留，请重试"
    }
  }
}

@MainActor
@Observable
final class BirthdayEditorModel {
  enum SaveOutcome: Equatable {
    case saved(immediateReminder: OneShotNotificationResult?)
    case requiresPassedReminderChoice
    case failed
  }

  enum SectionLocation: Hashable {
    case basicInformation
    case reminder
    case email
    case general
  }

  enum FieldLocation: Hashable {
    case name
    case lunarBirthday
    case reminderTime
    case reminderOptions
    case emailAddress
    case emailMessage
    case general

    var section: SectionLocation {
      switch self {
      case .name, .lunarBirthday:
        return .basicInformation
      case .reminderTime, .reminderOptions:
        return .reminder
      case .emailAddress, .emailMessage:
        return .email
      case .general:
        return .general
      }
    }
  }

  var draft: BirthdayDraft
  private(set) var errorMessage: String?
  private(set) var errorField: FieldLocation?
  private(set) var isSaving = false
  private(set) var isDeleting = false
  private(set) var hasSaved = false

  let recordID: UUID?

  private let store: BirthdayStore
  private let oneShotNotificationScheduler: any OneShotNotificationScheduling

  init(
    store: BirthdayStore,
    record: BirthdayRecord?,
    oneShotNotificationScheduler: any OneShotNotificationScheduling
  ) {
    self.store = store
    self.oneShotNotificationScheduler = oneShotNotificationScheduler
    recordID = record?.id
    draft =
      record.map(BirthdayDraft.init(record:))
      ?? BirthdayDraft(
        name: "",
        lunarBirthday: LunarBirthday(month: 1, day: 1, isLeapMonth: false),
        reminder: .defaults
      )
  }

  var isBusy: Bool {
    isSaving || isDeleting || hasSaved
  }

  func save(
    resolution: PassedSameDayReminderResolution? = nil,
    now: Date = .now,
    timeZone: TimeZone = .current
  ) async -> SaveOutcome {
    guard !isBusy else { return .failed }
    isSaving = true
    defer { isSaving = false }

    do {
      let decision = try SameDayReminderDecision.evaluate(
        draft: draft,
        now: now,
        timeZone: timeZone
      )
      if decision == .chooseImmediateOrNextYear, resolution == nil {
        return .requiresPassedReminderChoice
      }

      let saved = try await store.save(draft, id: recordID, now: now, timeZone: timeZone)
      errorMessage = nil
      errorField = nil
      hasSaved = true

      guard resolution == .remindNow else {
        return .saved(immediateReminder: nil)
      }
      let result = await oneShotNotificationScheduler.schedule(
        birthdayID: saved.id,
        name: saved.name,
        now: now
      )
      return .saved(immediateReminder: result)
    } catch {
      errorMessage = BirthdayErrorMessage.text(for: error)
      errorField = Self.location(for: error)
      return .failed
    }
  }

  func delete(now: Date = .now) async -> Bool {
    guard let recordID, !isBusy else { return false }
    isDeleting = true
    defer { isDeleting = false }

    do {
      try await store.softDelete(id: recordID, now: now)
      errorMessage = nil
      errorField = nil
      return true
    } catch {
      errorMessage = "删除失败，本地记录仍然保留，请重试"
      errorField = .general
      return false
    }
  }

  private static func location(for error: Error) -> FieldLocation {
    switch error as? BirthdayValidationError {
    case .emptyName, .nameTooLong:
      return .name
    case .invalidLunarMonth, .invalidLunarDay:
      return .lunarBirthday
    case .invalidReminderTime:
      return .reminderTime
    case .noNotificationSelected:
      return .reminderOptions
    case .invalidEmail:
      return .emailAddress
    case .emailMessageTooLong:
      return .emailMessage
    case nil:
      return .general
    }
  }
}
