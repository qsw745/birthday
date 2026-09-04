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

public struct NotificationRequestSnapshot: Equatable, Sendable {
  public let identifier: String
  public let triggerDate: Date?
  public let title: String
  public let body: String
  public let playsSound: Bool

  public init(
    identifier: String,
    triggerDate: Date,
    title: String,
    body: String,
    playsSound: Bool = true
  ) {
    self.identifier = identifier
    self.triggerDate = Date(
      timeIntervalSince1970: triggerDate.timeIntervalSince1970.rounded(.up)
    )
    self.title = title
    self.body = body
    self.playsSound = playsSound
  }

  public init(candidate: ReminderCandidate) {
    self.init(
      identifier: candidate.identifier,
      triggerDate: candidate.triggerDate,
      title: candidate.title,
      body: candidate.body
    )
  }

  fileprivate init(
    identifier: String,
    triggerDate: Date?,
    title: String,
    body: String,
    playsSound: Bool
  ) {
    self.identifier = identifier
    self.triggerDate = triggerDate
    self.title = title
    self.body = body
    self.playsSound = playsSound
  }
}

public protocol NotificationCenterClient: Sendable {
  func authorization() async -> NotificationAuthorization
  func pendingRequests() async -> [NotificationRequestSnapshot]
  func remove(identifiers: [String]) async
  func add(_ request: NotificationRequestSnapshot) async throws
}

public protocol NotificationScheduling: Sendable {
  func apply(_ plan: ReminderPlan) async throws -> NotificationHealth
  func removeAllBirthdayNotifications() async -> NotificationHealth
}

extension NotificationScheduling {
  public func removeAllBirthdayNotifications() async -> NotificationHealth {
    NotificationHealth(
      state: .failed,
      scheduledCount: 0,
      coverageEnd: nil,
      errorCategory: "notification_removal_unsupported"
    )
  }
}

public enum OneShotNotificationResult: Equatable, Sendable {
  case scheduled
  case notAuthorized
  case failed
}

public protocol OneShotNotificationScheduling: Sendable {
  func schedule(birthdayID: UUID, name: String, now: Date) async -> OneShotNotificationResult
}

private actor NotificationSchedulingGate {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
    await lock()
    defer { unlock() }
    return try await operation()
  }

  private func lock() async {
    guard !isLocked else {
      await withCheckedContinuation { continuation in waiters.append(continuation) }
      return
    }
    isLocked = true
  }

  private func unlock() {
    guard let next = waiters.first else {
      isLocked = false
      return
    }
    waiters.removeFirst()
    next.resume()
  }
}

public struct UserNotificationScheduler: NotificationScheduling {
  private static let rollingNamespace = "birthday."
  private static let immediateNamespace = "birthday.immediate."
  private static let conservativeCapacity = 64

  private let center: any NotificationCenterClient
  private let gate = NotificationSchedulingGate()

  public init(center: any NotificationCenterClient) {
    self.center = center
  }

  public func apply(_ plan: ReminderPlan) async throws -> NotificationHealth {
    try await gate.withLock { [center] in
      try await Self.apply(plan, using: center)
    }
  }

  public func removeAllBirthdayNotifications() async -> NotificationHealth {
    await gate.withLock { [center] in
      let identifiers = await center.pendingRequests()
        .map(\.identifier)
        .filter { $0.hasPrefix(Self.rollingNamespace) }
        .sorted()
      await center.remove(identifiers: identifiers)

      let remainingOwnedCount = await center.pendingRequests()
        .lazy
        .map(\.identifier)
        .filter { $0.hasPrefix(Self.rollingNamespace) }
        .count
      guard remainingOwnedCount == 0 else {
        return Self.failedHealth(category: "notification_removal_failed")
      }
      return NotificationHealth(
        state: .scheduled,
        scheduledCount: 0,
        coverageEnd: nil,
        errorCategory: nil
      )
    }
  }

  private static func apply(
    _ plan: ReminderPlan,
    using center: any NotificationCenterClient
  ) async throws -> NotificationHealth {
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
    guard candidates.allSatisfy({ isRollingIdentifier($0.identifier) }) else {
      return failedHealth(category: "invalid_identifier")
    }
    guard Set(candidates.map(\.identifier)).count == candidates.count else {
      return failedHealth(category: "duplicate_identifier")
    }

    let desired = candidates.map(NotificationRequestSnapshot.init(candidate:)).sorted(by: requestOrder)
    let initialAll = await center.pendingRequests()
    let initialOwned = initialAll.filter { isRollingIdentifier($0.identifier) }.sorted(by: requestOrder)
    let nonOwnedCount = initialAll.count - initialOwned.count
    guard nonOwnedCount + desired.count <= conservativeCapacity else {
      return failedHealth(category: "capacity_exceeded")
    }
    guard initialOwned.allSatisfy({ $0.triggerDate != nil }) else {
      return failedHealth(category: "snapshot_unavailable")
    }

    let initialByIdentifier = Dictionary(uniqueKeysWithValues: initialOwned.map { ($0.identifier, $0) })
    let desiredByIdentifier = Dictionary(uniqueKeysWithValues: desired.map { ($0.identifier, $0) })
    let identifiersToRemove = initialOwned.compactMap { request -> String? in
      desiredByIdentifier[request.identifier] == request ? nil : request.identifier
    }.sorted()
    let requestsToAdd = desired.filter { initialByIdentifier[$0.identifier] != $0 }

    await center.remove(identifiers: identifiersToRemove)
    do {
      for request in requestsToAdd { try await center.add(request) }
    } catch {
      let restored = await restore(initialOwned, using: center)
      return failedHealth(category: restored ? "schedule_failed" : "schedule_restore_failed")
    }

    let finalOwned = await center.pendingRequests()
      .filter { isRollingIdentifier($0.identifier) }
      .sorted(by: requestOrder)
    guard finalOwned == desired else {
      let restored = await restore(initialOwned, using: center)
      return failedHealth(
        category: restored ? "schedule_verification_failed" : "schedule_restore_failed"
      )
    }

    return NotificationHealth(
      state: .scheduled,
      scheduledCount: desired.count,
      coverageEnd: plan.coverageEnd,
      errorCategory: nil
    )
  }

  private static func restore(
    _ snapshot: [NotificationRequestSnapshot],
    using center: any NotificationCenterClient
  ) async -> Bool {
    let currentOwned = await center.pendingRequests()
      .filter { isRollingIdentifier($0.identifier) }
      .map(\.identifier)
      .sorted()
    await center.remove(identifiers: currentOwned)

    var addSucceeded = true
    for request in snapshot {
      do {
        try await center.add(request)
      } catch {
        addSucceeded = false
      }
    }
    let restored = await center.pendingRequests()
      .filter { isRollingIdentifier($0.identifier) }
      .sorted(by: requestOrder)
    return addSucceeded && restored == snapshot.sorted(by: requestOrder)
  }

  private static func isRollingIdentifier(_ identifier: String) -> Bool {
    identifier.hasPrefix(rollingNamespace) && !identifier.hasPrefix(immediateNamespace)
  }

  private static func requestOrder(
    _ lhs: NotificationRequestSnapshot,
    _ rhs: NotificationRequestSnapshot
  ) -> Bool {
    lhs.identifier < rhs.identifier
  }

  private static func failedHealth(category: String) -> NotificationHealth {
    NotificationHealth(state: .failed, scheduledCount: 0, coverageEnd: nil, errorCategory: category)
  }
}

public struct OneShotNotificationScheduler: OneShotNotificationScheduling {
  private let center: any NotificationCenterClient

  public init(center: any NotificationCenterClient) {
    self.center = center
  }

  public func schedule(
    birthdayID: UUID,
    name: String,
    now: Date
  ) async -> OneShotNotificationResult {
    guard await center.authorization().isAllowedToSchedule else { return .notAuthorized }
    let timestamp = Int(now.timeIntervalSince1970 * 1_000)
    let request = NotificationRequestSnapshot(
      identifier: "birthday.immediate.\(birthdayID.uuidString).\(timestamp)",
      triggerDate: now.addingTimeInterval(1),
      title: "今天是\(name)的生日",
      body: "别忘了送上生日祝福。"
    )
    do {
      try await center.add(request)
      return .scheduled
    } catch {
      return .failed
    }
  }
}

public enum SystemNotificationCenterClientError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidTrigger
}

public final class SystemNotificationCenterClient: @unchecked Sendable, NotificationCenterClient {
  private let center: UNUserNotificationCenter

  public init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  public func authorization() async -> NotificationAuthorization {
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined: return .notDetermined
    case .authorized: return .authorized
    case .denied: return .denied
    case .provisional: return .provisional
    case .ephemeral: return .ephemeral
    @unknown default: return .unknown
    }
  }

  public func pendingRequests() async -> [NotificationRequestSnapshot] {
    await center.pendingNotificationRequests().map(Self.snapshot(for:))
  }

  public func remove(identifiers: [String]) async {
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  public func add(_ request: NotificationRequestSnapshot) async throws {
    guard request.identifier.hasPrefix("birthday.") else {
      throw SystemNotificationCenterClientError.invalidIdentifier
    }
    guard request.triggerDate != nil else {
      throw SystemNotificationCenterClientError.invalidTrigger
    }
    try await center.add(Self.request(for: request))
  }

  static func request(for snapshot: NotificationRequestSnapshot) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = snapshot.title
    content.body = snapshot.body
    if snapshot.playsSound { content.sound = .default }

    let triggerDate = snapshot.triggerDate ?? .distantFuture
    let components = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: triggerDate
    )
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    return UNNotificationRequest(identifier: snapshot.identifier, content: content, trigger: trigger)
  }

  private static func snapshot(for request: UNNotificationRequest) -> NotificationRequestSnapshot {
    let triggerDate = (request.trigger as? UNCalendarNotificationTrigger)
      .flatMap { Calendar.current.date(from: $0.dateComponents) }
    return NotificationRequestSnapshot(
      identifier: request.identifier,
      triggerDate: triggerDate,
      title: request.content.title,
      body: request.content.body,
      playsSound: request.content.sound != nil
    )
  }
}

private extension NotificationAuthorization {
  var isAllowedToSchedule: Bool {
    switch self {
    case .authorized, .provisional, .ephemeral: true
    case .notDetermined, .denied, .unknown: false
    }
  }
}
