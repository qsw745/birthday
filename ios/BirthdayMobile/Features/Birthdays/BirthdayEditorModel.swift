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
    case nil: return "保存失败，输入内容已保留，请重试"
    }
  }
}

@MainActor
@Observable
final class BirthdayEditorModel {
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
    case general

    var section: SectionLocation {
      switch self {
      case .name, .lunarBirthday:
        return .basicInformation
      case .reminderTime, .reminderOptions:
        return .reminder
      case .emailAddress:
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

  let recordID: UUID?

  private let store: BirthdayStore

  init(store: BirthdayStore, record: BirthdayRecord?) {
    self.store = store
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
    isSaving || isDeleting
  }

  func save(now: Date = .now, timeZone: TimeZone = .current) async -> Bool {
    guard !isBusy else { return false }
    isSaving = true
    defer { isSaving = false }

    do {
      _ = try await store.save(draft, id: recordID, now: now, timeZone: timeZone)
      errorMessage = nil
      errorField = nil
      return true
    } catch {
      errorMessage = BirthdayErrorMessage.text(for: error)
      errorField = Self.location(for: error)
      return false
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
    case nil:
      return .general
    }
  }
}
