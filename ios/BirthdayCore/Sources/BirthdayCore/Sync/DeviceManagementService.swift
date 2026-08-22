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
  private var operationInProgress = false
  private var serverRevokedButCredentialClearFailed = false

  public init(api: any MobileAPI, credentials: DeviceCredentialStore) {
    self.api = api
    self.credentials = credentials
  }

  public var isFailClosedAfterServerRevoke: Bool {
    serverRevokedButCredentialClearFailed
  }

  public func listDevices() async throws -> [ManagedDevice] {
    let current = try requireUsableCredentials()
    do {
      return try await api.devices(accessToken: current.accessToken).map {
        ManagedDevice(device: $0, isCurrent: $0.deviceId == current.deviceId)
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
      try await api.revoke(deviceId: device.deviceId, accessToken: current.accessToken)
    } catch MobileAPIError.accessExpired {
      throw DeviceManagementError.rebindRequired
    } catch MobileAPIError.refreshInvalid {
      throw DeviceManagementError.rebindRequired
    }
  }

  public func beginUnlinkCurrent() async throws -> UnlinkOutcome {
    try beginOperation()
    defer { operationInProgress = false }

    let current = try requireUsableCredentials()
    guard let username = current.username, !username.isEmpty else {
      throw DeviceManagementError.rebindRequired
    }
    try Task.checkCancellation()

    do {
      try await api.revoke(deviceId: current.deviceId, accessToken: current.accessToken)
    } catch MobileAPIError.transport {
      return .needsLocalConfirmation(message: Self.localUnlinkWarning)
    } catch MobileAPIError.accessExpired {
      throw DeviceManagementError.rebindRequired
    } catch MobileAPIError.refreshInvalid {
      throw DeviceManagementError.rebindRequired
    }

    do {
      try credentials.clearCredentials()
    } catch {
      serverRevokedButCredentialClearFailed = true
      throw DeviceManagementError.credentialClearFailedAfterServerRevoke
    }
    return .unlinked
  }

  public func confirmLocalUnlink() throws {
    guard !operationInProgress else { throw DeviceManagementError.operationInProgress }
    operationInProgress = true
    defer { operationInProgress = false }
    do {
      try credentials.clearCredentials()
      serverRevokedButCredentialClearFailed = false
    } catch {
      throw DeviceManagementError.credentialClearFailed
    }
  }

  private func beginOperation() throws {
    guard !serverRevokedButCredentialClearFailed else {
      throw DeviceManagementError.revokedSessionRequiresLocalCleanup
    }
    guard !operationInProgress else { throw DeviceManagementError.operationInProgress }
    operationInProgress = true
  }

  private func requireUsableCredentials() throws -> DeviceCredentials {
    guard !serverRevokedButCredentialClearFailed else {
      throw DeviceManagementError.revokedSessionRequiresLocalCleanup
    }
    guard let current = try credentials.load() else {
      throw DeviceManagementError.credentialsUnavailable
    }
    return current
  }
}
