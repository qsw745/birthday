import Foundation
@preconcurrency import LocalAuthentication

public protocol AppLockAuthenticating: Sendable {
  func unlock(reason: String) async throws -> Bool
}

public enum AppLockError: Error, Equatable, Sendable {
  case unavailable
  case evaluationFailed
}

public struct LocalAuthenticationService: AppLockAuthenticating {
  public init() {}

  public func unlock(reason: String) async throws -> Bool {
    let context = LAContext()
    context.localizedFallbackTitle = "使用设备密码"

    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      throw AppLockError.unavailable
    }

    do {
      return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    } catch {
      throw AppLockError.evaluationFailed
    }
  }
}
