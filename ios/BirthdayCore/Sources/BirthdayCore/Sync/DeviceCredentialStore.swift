import Foundation

public struct DeviceCredentials: Codable, Equatable, Sendable {
  public let deviceId: UUID
  public let accessToken: String
  public let accessExpiresAt: Date
  public let refreshToken: String
  public let refreshExpiresAt: Date

  public init(
    deviceId: UUID,
    accessToken: String,
    accessExpiresAt: Date,
    refreshToken: String,
    refreshExpiresAt: Date
  ) {
    self.deviceId = deviceId
    self.accessToken = accessToken
    self.accessExpiresAt = accessExpiresAt
    self.refreshToken = refreshToken
    self.refreshExpiresAt = refreshExpiresAt
  }

  public init(_ response: TokenResponse) {
    self.init(
      deviceId: response.deviceId,
      accessToken: response.accessToken,
      accessExpiresAt: response.accessExpiresAt,
      refreshToken: response.refreshToken,
      refreshExpiresAt: response.refreshExpiresAt
    )
  }
}

public enum DeviceCredentialStoreError: Error, Equatable, Sendable {
  case invalidDeviceID
  case deviceIdentityMismatch
}

public enum ServerDeviceBindingError: Error, Equatable, Sendable {
  case responseDeviceIDMismatch
  case credentialsUnavailable
}

public protocol ServerDeviceBinding: Sendable {
  func bind(username: String, password: String, deviceName: String) async throws
  func loadSnapshot() async throws -> SnapshotResponse
}

public struct ServerDeviceBinder: ServerDeviceBinding {
  private let api: any MobileAPI
  private let credentials: DeviceCredentialStore

  public init(api: any MobileAPI, credentials: DeviceCredentialStore) {
    self.api = api
    self.credentials = credentials
  }

  public func bind(username: String, password: String, deviceName: String) async throws {
    let deviceID = try credentials.loadOrCreateDeviceID()
    let response = try await api.login(
      LoginRequest(
        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
        password: password,
        deviceId: deviceID,
        deviceName: deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    )
    guard response.deviceId == deviceID else {
      throw ServerDeviceBindingError.responseDeviceIDMismatch
    }
    try credentials.save(DeviceCredentials(response))
  }

  public func loadSnapshot() async throws -> SnapshotResponse {
    guard let saved = try credentials.load() else {
      throw ServerDeviceBindingError.credentialsUnavailable
    }
    return try await api.snapshot(accessToken: saved.accessToken)
  }
}

/// Serializes the two Keychain items across all store instances in this process.
///
/// Credentials can be cleared independently, while the stable device identity remains available
/// for a transaction-safe same-device rebind after token loss, revocation, or a lost response.
public final class DeviceCredentialStore: @unchecked Sendable {
  private static let credentialsAccount = "mobile-device-credentials"
  private static let deviceIDAccount = "mobile-device-id"
  private static let lock = NSLock()

  private let secure: any SecureTokenStore
  private let makeDeviceID: @Sendable () -> UUID

  public init(secure: any SecureTokenStore) {
    self.secure = secure
    makeDeviceID = UUID.init
  }

  internal init(
    secure: any SecureTokenStore,
    makeDeviceID: @escaping @Sendable () -> UUID
  ) {
    self.secure = secure
    self.makeDeviceID = makeDeviceID
  }

  public func save(_ value: DeviceCredentials) throws {
    try withLock {
      if let deviceID = try readDeviceIDLocked() {
        guard deviceID == value.deviceId else {
          throw DeviceCredentialStoreError.deviceIdentityMismatch
        }
      } else {
        try saveDeviceIDLocked(value.deviceId)
      }

      let encoded = try MobileJSON.encoder.encode(value)
      try secure.save(encoded, account: Self.credentialsAccount)
    }
  }

  public func load() throws -> DeviceCredentials? {
    try withLock {
      guard let data = try secure.read(account: Self.credentialsAccount) else { return nil }
      guard let deviceID = try readDeviceIDLocked() else {
        throw DeviceCredentialStoreError.invalidDeviceID
      }
      let value = try MobileJSON.decoder.decode(DeviceCredentials.self, from: data)
      guard deviceID == value.deviceId else {
        throw DeviceCredentialStoreError.deviceIdentityMismatch
      }
      return value
    }
  }

  public func clearCredentials() throws {
    try withLock {
      try secure.delete(account: Self.credentialsAccount)
    }
  }

  public func clear() throws {
    try clearCredentials()
  }

  public func readDeviceID() throws -> UUID? {
    try withLock {
      try readDeviceIDLocked()
    }
  }

  public func loadOrCreateDeviceID() throws -> UUID {
    try withLock {
      if let existing = try readDeviceIDLocked() {
        return existing
      }

      let deviceID = makeDeviceID()
      try saveDeviceIDLocked(deviceID)
      return deviceID
    }
  }

  private func saveDeviceIDLocked(_ deviceID: UUID) throws {
    guard Self.isServerUUID(deviceID.uuidString) else {
      throw DeviceCredentialStoreError.invalidDeviceID
    }
    let canonical = deviceID.uuidString.lowercased()
    try secure.save(Data(canonical.utf8), account: Self.deviceIDAccount)
  }

  private func readDeviceIDLocked() throws -> UUID? {
    guard let data = try secure.read(account: Self.deviceIDAccount) else { return nil }
    guard
      let value = String(data: data, encoding: .utf8),
      value == value.lowercased(),
      Self.isServerUUID(value),
      let deviceID = UUID(uuidString: value)
    else {
      throw DeviceCredentialStoreError.invalidDeviceID
    }
    return deviceID
  }

  private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    return try operation()
  }

  private static func isServerUUID(_ string: String) -> Bool {
    let bytes = Array(string.utf8)
    guard bytes.count == 36 else { return false }

    for index in bytes.indices {
      if [8, 13, 18, 23].contains(index) {
        guard bytes[index] == Character("-").asciiValue! else { return false }
      } else {
        guard isHex(bytes[index]) else { return false }
      }
    }

    guard bytes[14] >= Character("1").asciiValue!, bytes[14] <= Character("8").asciiValue!
    else { return false }
    return ["8", "9", "a", "b", "A", "B"].compactMap(\.first?.asciiValue).contains(bytes[19])
  }

  private static func isHex(_ byte: UInt8) -> Bool {
    (byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!)
      || (byte >= Character("a").asciiValue! && byte <= Character("f").asciiValue!)
      || (byte >= Character("A").asciiValue! && byte <= Character("F").asciiValue!)
  }
}
