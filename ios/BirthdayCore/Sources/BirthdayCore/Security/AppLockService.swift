import Foundation
@preconcurrency import LocalAuthentication

public protocol AppLockAuthenticating: Sendable {
  func unlock(reason: String) async throws -> Bool
}

public enum AppLockError: Error, Equatable, Sendable {
  case unavailable
  case cancelled
  case evaluationFailed
}

internal enum LocalAuthenticationSystemError: Error, Sendable {
  case unavailable
  case laError(domain: String, code: Int)
  case other
}

internal protocol AppLockSystemContext: Sendable {
  func canEvaluateDeviceOwnerAuthentication() -> Result<Void, LocalAuthenticationSystemError>
  func evaluateDeviceOwnerAuthentication(reason: String) async throws -> Bool
}

internal protocol AppLockSystemContextFactory: Sendable {
  func makeContext() -> any AppLockSystemContext
}

internal struct SystemAppLockSystemContextFactory: AppLockSystemContextFactory {
  func makeContext() -> any AppLockSystemContext {
    SystemAppLockSystemContext()
  }
}

internal final class SystemAppLockSystemContext: AppLockSystemContext, @unchecked Sendable {
  private let context: LAContext

  init() {
    context = LAContext()
    context.localizedFallbackTitle = "使用设备密码"
  }

  func canEvaluateDeviceOwnerAuthentication() -> Result<Void, LocalAuthenticationSystemError> {
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      if let error {
        return .failure(.laError(domain: error.domain, code: error.code))
      }
      return .failure(.unavailable)
    }
    return .success(())
  }

  func evaluateDeviceOwnerAuthentication(reason: String) async throws -> Bool {
    do {
      return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    } catch let error as NSError {
      throw LocalAuthenticationSystemError.laError(domain: error.domain, code: error.code)
    } catch {
      throw LocalAuthenticationSystemError.other
    }
  }
}

public struct LocalAuthenticationService: AppLockAuthenticating {
  private let contextFactory: any AppLockSystemContextFactory

  public init() {
    contextFactory = SystemAppLockSystemContextFactory()
  }

  internal init(contextFactory: any AppLockSystemContextFactory) {
    self.contextFactory = contextFactory
  }

  public func unlock(reason: String) async throws -> Bool {
    let context = contextFactory.makeContext()
    guard case .success = context.canEvaluateDeviceOwnerAuthentication() else {
      throw AppLockError.unavailable
    }

    do {
      return try await context.evaluateDeviceOwnerAuthentication(reason: reason)
    } catch let error as LocalAuthenticationSystemError {
      throw mapEvaluationError(error)
    } catch {
      throw AppLockError.evaluationFailed
    }
  }

  private func mapEvaluationError(_ error: LocalAuthenticationSystemError) -> AppLockError {
    guard case .laError(let domain, let rawCode) = error,
      domain == LAError.errorDomain,
      let code = LAError.Code(rawValue: rawCode)
    else {
      return .evaluationFailed
    }

    switch code {
    case .userCancel, .appCancel, .systemCancel:
      return .cancelled
    default:
      return .evaluationFailed
    }
  }
}
