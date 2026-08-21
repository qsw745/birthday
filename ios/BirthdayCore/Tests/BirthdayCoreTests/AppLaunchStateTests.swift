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

@Test func enablingLockAfterDisabledBackgroundWaitsUntilNextBackground() {
  var session = AppLockSessionState(lockEnabled: true)

  session.setLockEnabled(false)
  session.enterBackground(lockEnabled: false)
  session.setLockEnabled(true)

  #expect(session.isUnlocked)

  session.enterBackground(lockEnabled: true)
  #expect(!session.isUnlocked)
}

@Test func backgroundInvalidatesAuthenticationAttempt() throws {
  var session = AppLockSessionState(lockEnabled: true)
  let pendingAttempt = session.beginAuthentication()
  let attempt = try #require(pendingAttempt)

  session.enterBackground(lockEnabled: true)
  let currentPendingAttempt = session.beginAuthentication()
  let currentAttempt = try #require(currentPendingAttempt)

  let accepted = session.completeAuthentication(attempt, succeeded: true)
  #expect(!accepted)
  #expect(!session.isUnlocked)

  let currentAccepted = session.completeAuthentication(currentAttempt, succeeded: true)
  #expect(currentAccepted)
  #expect(session.isUnlocked)
}

@Test func currentAuthenticationAttemptCanUnlockSession() throws {
  var session = AppLockSessionState(lockEnabled: true)
  let pendingAttempt = session.beginAuthentication()
  let attempt = try #require(pendingAttempt)

  let accepted = session.completeAuthentication(attempt, succeeded: true)
  #expect(accepted)
  #expect(session.isUnlocked)
}
