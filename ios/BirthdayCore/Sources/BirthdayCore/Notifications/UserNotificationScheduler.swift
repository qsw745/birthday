import Foundation
@preconcurrency import UserNotifications

public enum NotificationAuthorization: Equatable, Sendable {
  case notDetermined
  case authorized
  case denied
  case provisional
  case ephemeral
  case unknown
}

public enum NotificationHealthState: Equatable, Sendable {
  case scheduled
  case permissionDenied
  case notRequested
  case failed
}

public struct NotificationHealth: Equatable, Sendable {
  public let state: NotificationHealthState
  public let scheduledCount: Int
  public let coverageEnd: Date?
  public let errorCategory: String?

  public init(
    state: NotificationHealthState,
    scheduledCount: Int,
    coverageEnd: Date?,
    errorCategory: String?
  ) {
    self.state = state
    self.scheduledCount = scheduledCount
    self.coverageEnd = coverageEnd
    self.errorCategory = errorCategory
  }
}

public protocol NotificationCenterClient: Sendable {
  func authorization() async -> NotificationAuthorization
  func pendingIdentifiers() async -> [String]
  func remove(identifiers: [String]) async
  func add(_ candidate: ReminderCandidate) async throws
}

public protocol NotificationScheduling: Sendable {
  func apply(_ plan: ReminderPlan) async throws -> NotificationHealth
}

public struct UserNotificationScheduler: NotificationScheduling {
  private static let namespace = "birthday."
  private let center: any NotificationCenterClient

  public init(center: any NotificationCenterClient) {
    self.center = center
  }

  public func apply(_ plan: ReminderPlan) async throws -> NotificationHealth {
    let authorization = await center.authorization()
    guard authorization.isAllowedToSchedule else {
      return NotificationHealth(
        state: authorization == .notDetermined ? .notRequested : .permissionDenied,
        scheduledCount: 0,
        coverageEnd: nil,
        errorCategory: nil
      )
    }

    let candidates = plan.birthdayNotifications + [plan.maintenanceNotification].compactMap { $0 }
    guard candidates.allSatisfy({ $0.identifier.hasPrefix(Self.namespace) }) else {
      return failedHealth(category: "invalid_identifier")
    }
    guard Set(candidates.map(\.identifier)).count == candidates.count else {
      return failedHealth(category: "duplicate_identifier")
    }

    do {
      for candidate in candidates {
        try await center.add(candidate)
      }
    } catch {
      return failedHealth(category: "schedule_failed")
    }

    let desiredIdentifiers = Set(candidates.map(\.identifier))
    let staleOwnedIdentifiers = await center.pendingIdentifiers().filter {
      $0.hasPrefix(Self.namespace) && !desiredIdentifiers.contains($0)
    }
    await center.remove(identifiers: staleOwnedIdentifiers)

    return NotificationHealth(
      state: .scheduled,
      scheduledCount: candidates.count,
      coverageEnd: plan.coverageEnd,
      errorCategory: nil
    )
  }

  private func failedHealth(category: String) -> NotificationHealth {
    NotificationHealth(state: .failed, scheduledCount: 0, coverageEnd: nil, errorCategory: category)
  }
}

public enum SystemNotificationCenterClientError: Error, Equatable, Sendable {
  case invalidIdentifier
}

public final class SystemNotificationCenterClient: @unchecked Sendable, NotificationCenterClient {
  private let center: UNUserNotificationCenter

  public init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  public func authorization() async -> NotificationAuthorization {
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined:
      return .notDetermined
    case .authorized:
      return .authorized
    case .denied:
      return .denied
    case .provisional:
      return .provisional
    case .ephemeral:
      return .ephemeral
    @unknown default:
      return .unknown
    }
  }

  public func pendingIdentifiers() async -> [String] {
    await center.pendingNotificationRequests().map(\.identifier)
  }

  public func remove(identifiers: [String]) async {
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  public func add(_ candidate: ReminderCandidate) async throws {
    guard candidate.identifier.hasPrefix("birthday.") else {
      throw SystemNotificationCenterClientError.invalidIdentifier
    }
    try await center.add(Self.request(for: candidate))
  }

  static func request(for candidate: ReminderCandidate) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = candidate.title
    content.body = candidate.body
    content.sound = .default

    let components = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: candidate.triggerDate
    )
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    return UNNotificationRequest(identifier: candidate.identifier, content: content, trigger: trigger)
  }
}

private extension NotificationAuthorization {
  var isAllowedToSchedule: Bool {
    switch self {
    case .authorized, .provisional, .ephemeral:
      true
    case .notDetermined, .denied, .unknown:
      false
    }
  }
}
