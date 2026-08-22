import Foundation

public struct SyncLastSuccessStore: @unchecked Sendable {
  private static let key = "top.qisw.birthday.sync.lastSuccess"

  private let preferences: UserDefaults

  public init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
  }

  public func load() -> Date? {
    preferences.object(forKey: Self.key) as? Date
  }

  public func save(_ date: Date) {
    preferences.set(date, forKey: Self.key)
  }

  public func clear() {
    preferences.removeObject(forKey: Self.key)
  }
}
