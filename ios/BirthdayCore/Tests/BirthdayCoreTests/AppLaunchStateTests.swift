import Testing

@testable import BirthdayCore

@Test func firstLaunchShowsOnboardingBeforeLock() {
  #expect(
    AppLaunchState.resolve(hasCompletedOnboarding: false, lockEnabled: true) == .onboarding)
}

@Test func returningLockedUserShowsLock() {
  #expect(AppLaunchState.resolve(hasCompletedOnboarding: true, lockEnabled: true) == .locked)
}

@Test func unlockedUserShowsApplication() {
  #expect(AppLaunchState.resolve(hasCompletedOnboarding: true, lockEnabled: false) == .ready)
}
