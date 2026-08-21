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

@Test func firstLaunchWithoutOwnerAuthenticationKeepsLockDisabled() {
  let decision = AppLockPreferenceDecision.resolve(
    storedPreference: nil,
    capability: .unavailable
  )

  #expect(!decision.isEnabled)
  #expect(decision.preferenceToPersist == false)
}

@Test func returningUserIsNotLockedOutWhenAuthenticationCapabilityDisappears() {
  let decision = AppLockPreferenceDecision.resolve(
    storedPreference: true,
    capability: .unavailable
  )

  #expect(!decision.isEnabled)
  #expect(decision.preferenceToPersist == false)
  #expect(AppLaunchState.resolve(hasCompletedOnboarding: true, lockEnabled: decision.isEnabled) == .ready)
}

@Test(arguments: [AppLockCapability.faceID, .devicePasscode])
func availableOwnerAuthenticationKeepsDefaultLockEnabled(_ capability: AppLockCapability) {
  let decision = AppLockPreferenceDecision.resolve(
    storedPreference: nil,
    capability: capability
  )

  #expect(decision.isEnabled)
  #expect(decision.preferenceToPersist == true)
}
