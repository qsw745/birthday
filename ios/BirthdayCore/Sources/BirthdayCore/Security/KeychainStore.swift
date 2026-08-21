import Foundation
import Security

public protocol SecureTokenStore: Sendable {
  func save(_ data: Data, account: String) throws
  func read(account: String) throws -> Data?
  func delete(account: String) throws
}

public enum KeychainError: Error, Equatable, Sendable {
  case invalidAccount
  case status(OSStatus)
  case unexpectedData
}

internal protocol KeychainSystemClient: Sendable {
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
  func add(_ query: [String: Any]) -> OSStatus
  func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?)
  func delete(_ query: [String: Any]) -> OSStatus
}

internal struct SystemKeychainClient: KeychainSystemClient {
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }

  func add(_ query: [String: Any]) -> OSStatus {
    SecItemAdd(query as CFDictionary, nil)
  }

  func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result)
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    SecItemDelete(query as CFDictionary)
  }
}

public struct KeychainStore: SecureTokenStore {
  private static let service = "top.qisw.birthday"
  private let client: any KeychainSystemClient

  public init() {
    client = SystemKeychainClient()
  }

  internal init(client: any KeychainSystemClient) {
    self.client = client
  }

  public func save(_ data: Data, account: String) throws {
    try validate(account: account)
    let identity = itemIdentity(account: account)
    let attributes = updateAttributes(data: data)

    let updateStatus = client.update(identity, attributes: attributes)
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      let status = client.add(newItem(account: account, data: data))
      if status == errSecSuccess {
        return
      }
      if status == errSecDuplicateItem {
        try requireSuccess(client.update(identity, attributes: attributes))
        return
      }
      throw KeychainError.status(status)
    default:
      throw KeychainError.status(updateStatus)
    }
  }

  public func read(account: String) throws -> Data? {
    try validate(account: account)
    var query = itemIdentity(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    let (status, result) = client.copyMatching(query)
    if status == errSecItemNotFound {
      return nil
    }
    try requireSuccess(status)
    guard let data = result as? Data else {
      throw KeychainError.unexpectedData
    }
    return data
  }

  public func delete(account: String) throws {
    try validate(account: account)
    let status = client.delete(itemIdentity(account: account))
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }
  }

  private func validate(account: String) throws {
    guard !account.isEmpty else {
      throw KeychainError.invalidAccount
    }
  }

  private func itemIdentity(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account,
    ]
  }

  private func updateAttributes(data: Data) -> [String: Any] {
    [
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: data,
    ]
  }

  private func newItem(account: String, data: Data) -> [String: Any] {
    itemIdentity(account: account).merging(
      updateAttributes(data: data), uniquingKeysWith: { _, new in new })
  }

  private func requireSuccess(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw KeychainError.status(status)
    }
  }
}
