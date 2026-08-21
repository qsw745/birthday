import Testing

@testable import BirthdayCore

private struct FakeAppLockAuthenticator: AppLockAuthenticating {
  let result: Bool

  func unlock(reason: String) async throws -> Bool {
    result
  }
}

@Test func appLockContractReturnsConfiguredResult() async throws {
  let lock = FakeAppLockAuthenticator(result: true)

  #expect(try await lock.unlock(reason: "解锁生日资料"))
}
