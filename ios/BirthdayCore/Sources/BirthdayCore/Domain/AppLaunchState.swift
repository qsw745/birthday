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
