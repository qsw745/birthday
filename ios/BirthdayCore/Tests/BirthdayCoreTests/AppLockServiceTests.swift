import LocalAuthentication
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

private struct FakeAppLockSystemContext: AppLockSystemContext {
  let availability: Result<Void, LocalAuthenticationSystemError>
  let evaluation: Result<Bool, LocalAuthenticationSystemError>

  func canEvaluateDeviceOwnerAuthentication() -> Result<Void, LocalAuthenticationSystemError> {
    availability
  }

  func evaluateDeviceOwnerAuthentication(reason: String) async throws -> Bool {
    try evaluation.get()
  }
}

private struct FakeAppLockSystemContextFactory: AppLockSystemContextFactory {
  let context: FakeAppLockSystemContext

  func makeContext() -> any AppLockSystemContext {
    context
  }
}

private func makeLocalAuthenticationService(
  availability: Result<Void, LocalAuthenticationSystemError> = .success(()),
  evaluation: Result<Bool, LocalAuthenticationSystemError>
) -> LocalAuthenticationService {
  LocalAuthenticationService(
    contextFactory: FakeAppLockSystemContextFactory(
      context: FakeAppLockSystemContext(availability: availability, evaluation: evaluation)
    )
  )
}

@Test func localAuthenticationReportsUnavailableCapability() async {
  let service = makeLocalAuthenticationService(
    availability: .failure(.unavailable),
    evaluation: .success(true)
  )

  await #expect(throws: AppLockError.unavailable) {
    try await service.unlock(reason: "解锁生日资料")
  }
}

@Test func localAuthenticationReturnsSystemSuccessAndFalseResult() async throws {
  let success = makeLocalAuthenticationService(evaluation: .success(true))
  let falseResult = makeLocalAuthenticationService(evaluation: .success(false))

  #expect(try await success.unlock(reason: "解锁生日资料"))
  #expect(!(try await falseResult.unlock(reason: "解锁生日资料")))
}

@Test(arguments: [LAError.Code.userCancel, .appCancel, .systemCancel])
func localAuthenticationMapsCancellationErrors(_ code: LAError.Code) async {
  let service = makeLocalAuthenticationService(evaluation: .failure(.laError(code.rawValue)))

  await #expect(throws: AppLockError.cancelled) {
    try await service.unlock(reason: "解锁生日资料")
  }
}

@Test(arguments: [LAError.Code.authenticationFailed, .invalidContext])
func localAuthenticationMapsNonCancellationErrors(_ code: LAError.Code) async {
  let service = makeLocalAuthenticationService(evaluation: .failure(.laError(code.rawValue)))

  await #expect(throws: AppLockError.evaluationFailed) {
    try await service.unlock(reason: "解锁生日资料")
  }
}

@Test func localAuthenticationMapsUnknownSystemFailure() async {
  let service = makeLocalAuthenticationService(evaluation: .failure(.other))

  await #expect(throws: AppLockError.evaluationFailed) {
    try await service.unlock(reason: "解锁生日资料")
  }
}
