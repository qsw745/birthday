import Foundation

public enum DeviceManagementError: Error, Equatable, Sendable {
  case confirmationMismatch
  case currentDeviceRequiresUnlink
  case credentialsUnavailable
  case rebindRequired
  case operationInProgress
  case credentialClearFailed
  case credentialClearFailedAfterServerRevoke
  case revokedSessionRequiresLocalCleanup
}

public enum UnlinkOutcome: Equatable, Sendable {
  case unlinked
  case needsLocalConfirmation(message: String)
}

public enum PendingLocalCleanup: Equatable, Sendable {
  case transportUnknown
  case serverRevoked
}

public struct ManagedDevice: Equatable, Identifiable, Sendable {
  public let device: MobileDevice
  public let isCurrent: Bool
  public var id: UUID { device.deviceId }

  public init(device: MobileDevice, isCurrent: Bool) {
    self.device = device
    self.isCurrent = isCurrent
  }
}

/// Owns destructive device operations and keeps their network/Keychain boundary explicit.
public actor DeviceManagementService {
  public static let localUnlinkWarning = "服务器可能仍保留此设备，可在重新绑定后撤销"

  private let api: any MobileAPI
  private let credentials: DeviceCredentialStore
  private let remoteAccessGate: RemoteSyncAccessGate
  private var operationInProgress = false
  private enum UnlinkPauseState: Equatable {
    case idle
    case revoking(RemoteSyncPauseToken)
    case awaitingConfirmation(RemoteSyncPauseToken)
    case pendingCleanup(RemoteSyncPauseToken, PendingLocalCleanup)
    case rebindRequired(RemoteSyncPauseToken)
    case stopped(RemoteSyncPauseToken)

    var token: RemoteSyncPauseToken? {
      switch self {
      case .idle: nil
      case .revoking(let token), .awaitingConfirmation(let token),
        .pendingCleanup(let token, _), .rebindRequired(let token), .stopped(let token):
        token
      }
    }
  }

  private var unlinkPauseState: UnlinkPauseState = .idle
  private var lifecyclePauseToken: RemoteSyncPauseToken?

  public init(
    api: any MobileAPI,
    credentials: DeviceCredentialStore,
    remoteAccessGate: RemoteSyncAccessGate = RemoteSyncAccessGate()
  ) {
    self.api = api
    self.credentials = credentials
    self.remoteAccessGate = remoteAccessGate
  }

  public var isFailClosedAfterServerRevoke: Bool {
    pendingLocalCleanup == .serverRevoked
  }

  public var pendingLocalCleanup: PendingLocalCleanup? {
    guard case .pendingCleanup(_, let reason) = unlinkPauseState else { return nil }
    return reason
  }

  public func listDevices() async throws -> [ManagedDevice] {
    let current = try requireUsableCredentials()
    do {
      return try await remoteAccessGate.perform { _ in
        try await self.api.devices(accessToken: current.accessToken).map {
          ManagedDevice(device: $0, isCurrent: $0.deviceId == current.deviceId)
        }
      }
    } catch MobileAPIError.accessExpired {
      throw DeviceManagementError.rebindRequired
    } catch MobileAPIError.refreshInvalid {
      throw DeviceManagementError.rebindRequired
    }
  }

  public func revokeOther(_ device: MobileDevice, typedUsername: String) async throws {
    try beginOperation()
    defer { operationInProgress = false }

    let current = try requireUsableCredentials()
    guard device.deviceId != current.deviceId else {
      throw DeviceManagementError.currentDeviceRequiresUnlink
    }
    guard let expectedUsername = current.username, !expectedUsername.isEmpty else {
      throw DeviceManagementError.rebindRequired
    }
    guard typedUsername == expectedUsername else {
      throw DeviceManagementError.confirmationMismatch
    }
    try Task.checkCancellation()
    do {
      try await remoteAccessGate.perform { _ in
        try await self.api.revoke(deviceId: device.deviceId, accessToken: current.accessToken)
      }
    } catch MobileAPIError.accessExpired {
      throw DeviceManagementError.rebindRequired
    } catch MobileAPIError.refreshInvalid {
      throw DeviceManagementError.rebindRequired
    }
  }

  public func beginUnlinkCurrent() async throws -> UnlinkOutcome {
    try beginOperation()
    defer { operationInProgress = false }

    try Task.checkCancellation()
    let token = await remoteAccessGate.pauseAndDrain()
    unlinkPauseState = .revoking(token)

    do {
      try Task.checkCancellation()
    } catch {
      await releaseUnlinkPause(token)
      throw error
    }

    let current: DeviceCredentials
    do {
      current = try requireUsableCredentials()
    } catch {
      await releaseUnlinkPause(token)
      throw error
    }
    guard let username = current.username, !username.isEmpty else {
      unlinkPauseState = .rebindRequired(token)
      throw DeviceManagementError.rebindRequired
    }
    do {
      try Task.checkCancellation()
    } catch {
      await releaseUnlinkPause(token)
      throw error
    }

    do {
      try await api.revoke(deviceId: current.deviceId, accessToken: current.accessToken)
    } catch MobileAPIError.transport {
      unlinkPauseState = .awaitingConfirmation(token)
      return .needsLocalConfirmation(message: Self.localUnlinkWarning)
    } catch MobileAPIError.accessExpired {
      unlinkPauseState = .rebindRequired(token)
      throw DeviceManagementError.rebindRequired
    } catch MobileAPIError.refreshInvalid {
      unlinkPauseState = .rebindRequired(token)
      throw DeviceManagementError.rebindRequired
    } catch is CancellationError {
      await releaseUnlinkPause(token)
      throw CancellationError()
    } catch {
      await releaseUnlinkPause(token)
      throw error
    }

    do {
      try credentials.clearCredentials()
    } catch {
      unlinkPauseState = .pendingCleanup(token, .serverRevoked)
      throw DeviceManagementError.credentialClearFailedAfterServerRevoke
    }
    unlinkPauseState = .stopped(token)
    return .unlinked
  }

  public func confirmLocalUnlink() throws {
    guard !operationInProgress else { throw DeviceManagementError.operationInProgress }
    operationInProgress = true
    defer { operationInProgress = false }
    let token: RemoteSyncPauseToken
    let cleanupReason: PendingLocalCleanup
    switch unlinkPauseState {
    case .awaitingConfirmation(let ownedToken):
      token = ownedToken
      cleanupReason = .transportUnknown
    case .pendingCleanup(let ownedToken, let reason):
      token = ownedToken
      cleanupReason = reason
    default:
      throw DeviceManagementError.operationInProgress
    }

    do {
      try credentials.clearCredentials()
      unlinkPauseState = .stopped(token)
    } catch {
      unlinkPauseState = .pendingCleanup(token, cleanupReason)
      throw DeviceManagementError.credentialClearFailed
    }
  }

  public func cancelPendingLocalUnlink() async {
    guard case .awaitingConfirmation(let token) = unlinkPauseState else { return }
    await releaseUnlinkPause(token)
  }

  public func resumeSyncAfterPendingLocalCleanup() async throws {
    guard case .pendingCleanup(let token, let reason) = unlinkPauseState else {
      throw DeviceManagementError.operationInProgress
    }
    guard reason == .transportUnknown else {
      throw DeviceManagementError.revokedSessionRequiresLocalCleanup
    }
    await releaseUnlinkPause(token)
  }

  public func pauseForRebind() async {
    guard lifecyclePauseToken == nil else { return }
    lifecyclePauseToken = await remoteAccessGate.pauseAndDrain()
  }

  public func pauseForMissingCredentials() async {
    await pauseForRebind()
  }

  public func resumeAfterBinding() async {
    let lifecycleToken = lifecyclePauseToken
    lifecyclePauseToken = nil
    let unlinkToken = unlinkPauseState.token
    unlinkPauseState = .idle
    if let lifecycleToken {
      _ = await remoteAccessGate.resume(after: lifecycleToken)
    }
    if let unlinkToken {
      _ = await remoteAccessGate.resume(after: unlinkToken)
    }
  }

  private func beginOperation() throws {
    guard pendingLocalCleanup != .serverRevoked else {
      throw DeviceManagementError.revokedSessionRequiresLocalCleanup
    }
    guard !operationInProgress else { throw DeviceManagementError.operationInProgress }
    guard unlinkPauseState == .idle else { throw DeviceManagementError.operationInProgress }
    operationInProgress = true
  }

  private func requireUsableCredentials() throws -> DeviceCredentials {
    guard pendingLocalCleanup != .serverRevoked else {
      throw DeviceManagementError.revokedSessionRequiresLocalCleanup
    }
    guard let current = try credentials.load() else {
      throw DeviceManagementError.credentialsUnavailable
    }
    return current
  }

  private func releaseUnlinkPause(_ token: RemoteSyncPauseToken) async {
    guard unlinkPauseState.token == token else { return }
    unlinkPauseState = .idle
    _ = await remoteAccessGate.resume(after: token)
  }
}
