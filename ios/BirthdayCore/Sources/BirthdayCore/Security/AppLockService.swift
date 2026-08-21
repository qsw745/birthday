import Foundation
@preconcurrency import LocalAuthentication

public protocol AppLockAuthenticating: Sendable {
  func capability() -> AppLockCapability
  func unlock(reason: String) async throws -> Bool
}

public enum AppLockCapability: Equatable, Sendable {
  case faceID
  case devicePasscode
  case unavailable
}

internal enum AppLockBiometry: Equatable, Sendable {
  case faceID
  case other
  case none
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

internal func localAuthenticationSystemError(from error: NSError) -> LocalAuthenticationSystemError
{
  .laError(domain: error.domain, code: error.code)
}

internal protocol AppLockSystemContext: Sendable {
  func canEvaluateDeviceOwnerAuthentication() -> Result<Void, LocalAuthenticationSystemError>
  func availableBiometry() -> AppLockBiometry
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
        return .failure(localAuthenticationSystemError(from: error))
      }
      return .failure(.unavailable)
    }
    return .success(())
  }

  func availableBiometry() -> AppLockBiometry {
    var error: NSError?
    _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    switch context.biometryType {
    case .faceID:
      return .faceID
    case .touchID, .opticID:
      return .other
    case .none:
      return .none
    @unknown default:
      return .other
    }
  }

  func evaluateDeviceOwnerAuthentication(reason: String) async throws -> Bool {
    do {
      return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    } catch let error as NSError {
      throw localAuthenticationSystemError(from: error)
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

  public func capability() -> AppLockCapability {
    let context = contextFactory.makeContext()
    guard case .success = context.canEvaluateDeviceOwnerAuthentication() else {
      return .unavailable
    }
    return context.availableBiometry() == .faceID ? .faceID : .devicePasscode
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
