public enum AppLaunchState: Equatable, Sendable {
  case onboarding
  case locked
  case ready

  public static func resolve(hasCompletedOnboarding: Bool, lockEnabled: Bool) -> Self {
    if !hasCompletedOnboarding {
      return .onboarding
    }
    return lockEnabled ? .locked : .ready
  }
}

public struct AppLockSessionState: Equatable, Sendable {
  public struct AuthenticationAttempt: Equatable, Sendable {
    fileprivate let generation: UInt64
  }

  public private(set) var isUnlocked: Bool

  private var generation: UInt64 = 0
  private var activeAttempt: AuthenticationAttempt?

  public init(lockEnabled: Bool) {
    isUnlocked = !lockEnabled
  }

  public mutating func setLockEnabled(_ isEnabled: Bool) {
    if !isEnabled {
      invalidateAuthentication()
      isUnlocked = true
    }
  }

  public mutating func enterBackground(lockEnabled: Bool) {
    invalidateAuthentication()
    if lockEnabled {
      isUnlocked = false
    }
  }

  public mutating func beginAuthentication() -> AuthenticationAttempt? {
    guard !isUnlocked, activeAttempt == nil else { return nil }
    generation &+= 1
    let attempt = AuthenticationAttempt(generation: generation)
    activeAttempt = attempt
    return attempt
  }

  @discardableResult
  public mutating func completeAuthentication(
    _ attempt: AuthenticationAttempt,
    succeeded: Bool
  ) -> Bool {
    guard activeAttempt == attempt, attempt.generation == generation, !isUnlocked else {
      return false
    }

    activeAttempt = nil
    if succeeded {
      isUnlocked = true
    }
    return true
  }

  private mutating func invalidateAuthentication() {
    generation &+= 1
    activeAttempt = nil
  }
}
