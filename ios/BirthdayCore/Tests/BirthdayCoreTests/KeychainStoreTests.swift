import Foundation
import Security
import Testing

@testable import BirthdayCore

private final class RecordingKeychainClient: KeychainSystemClient, @unchecked Sendable {
  var updateStatus: OSStatus = errSecSuccess
  var updateStatuses: [OSStatus] = []
  var addStatus: OSStatus = errSecSuccess
  var readStatus: OSStatus = errSecItemNotFound
  var readResult: Any?
  var deleteStatus: OSStatus = errSecSuccess
  private(set) var updateQueries: [[String: Any]] = []
  private(set) var updateAttributes: [[String: Any]] = []
  private(set) var addQueries: [[String: Any]] = []
  private(set) var readQueries: [[String: Any]] = []
  private(set) var deleteQueries: [[String: Any]] = []

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    updateQueries.append(query)
    updateAttributes.append(attributes)
    if !updateStatuses.isEmpty {
      return updateStatuses.removeFirst()
    }
    return updateStatus
  }

  func add(_ query: [String: Any]) -> OSStatus {
    addQueries.append(query)
    return addStatus
  }

  func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
    readQueries.append(query)
    return (readStatus, readResult)
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    deleteQueries.append(query)
    return deleteStatus
  }
}

private func makeStore(_ client: RecordingKeychainClient) -> KeychainStore {
  KeychainStore(client: client)
}

@Test func inMemoryTokenStoreRoundTripsData() throws {
  let store = InMemorySecureTokenStore()

  try store.save(Data("secret".utf8), account: "refresh-token")
  #expect(try store.read(account: "refresh-token") == Data("secret".utf8))
  try store.delete(account: "refresh-token")
  #expect(try store.read(account: "refresh-token") == nil)
}

@Test func savingExistingTokenUpdatesMatchingItemWithThisDeviceAccessibility() throws {
  let client = RecordingKeychainClient()
  let data = Data("rotated".utf8)

  try makeStore(client).save(data, account: "refresh-token")

  #expect(client.updateQueries.count == 1)
  #expect(client.addQueries.isEmpty)
  #expect(
    client.updateQueries[0][kSecClass as String] as? String == kSecClassGenericPassword as String)
  #expect(client.updateQueries[0][kSecAttrService as String] as? String == "top.qisw.birthday")
  #expect(client.updateQueries[0][kSecAttrAccount as String] as? String == "refresh-token")
  #expect(client.updateAttributes[0][kSecValueData as String] as? Data == data)
  #expect(
    client.updateAttributes[0][kSecAttrAccessible as String] as? String
      == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
  )
}

@Test func savingMissingTokenAddsNewItemAfterUpdateReportsNotFound() throws {
  let client = RecordingKeychainClient()
  client.updateStatus = errSecItemNotFound
  let data = Data("fresh".utf8)

  try makeStore(client).save(data, account: "refresh-token")

  #expect(client.updateQueries.count == 1)
  #expect(client.addQueries.count == 1)
  #expect(client.addQueries[0][kSecAttrService as String] as? String == "top.qisw.birthday")
  #expect(client.addQueries[0][kSecAttrAccount as String] as? String == "refresh-token")
  #expect(client.addQueries[0][kSecValueData as String] as? Data == data)
  #expect(
    client.addQueries[0][kSecAttrAccessible as String] as? String
      == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
  )
}

@Test func savingTokenPreservesExistingItemWhenUpdateFails() {
  let client = RecordingKeychainClient()
  client.updateStatus = errSecAuthFailed

  #expect(throws: KeychainError.status(errSecAuthFailed)) {
    try makeStore(client).save(Data("replacement".utf8), account: "refresh-token")
  }
  #expect(client.addQueries.isEmpty)
}

@Test func savingTokenRetriesUpdateWhenConcurrentAddFindsExistingItem() throws {
  let client = RecordingKeychainClient()
  client.updateStatuses = [errSecItemNotFound, errSecSuccess]
  client.addStatus = errSecDuplicateItem

  try makeStore(client).save(Data("replacement".utf8), account: "refresh-token")

  #expect(client.updateQueries.count == 2)
  #expect(client.addQueries.count == 1)
}

@Test func readingMissingTokenReturnsNil() throws {
  let client = RecordingKeychainClient()

  #expect(try makeStore(client).read(account: "refresh-token") == nil)
  #expect(client.readQueries[0][kSecReturnData as String] as? Bool == true)
  #expect(client.readQueries[0][kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
}

@Test func readingUnexpectedKeychainResultThrowsStableError() {
  let client = RecordingKeychainClient()
  client.readStatus = errSecSuccess
  client.readResult = "not data"

  #expect(throws: KeychainError.unexpectedData) {
    try makeStore(client).read(account: "refresh-token")
  }
}

@Test func readingSystemFailureThrowsItsStatus() {
  let client = RecordingKeychainClient()
  client.readStatus = errSecAuthFailed

  #expect(throws: KeychainError.status(errSecAuthFailed)) {
    try makeStore(client).read(account: "refresh-token")
  }
}

@Test func deletingMissingTokenIsIdempotent() throws {
  let client = RecordingKeychainClient()
  client.deleteStatus = errSecItemNotFound

  try makeStore(client).delete(account: "refresh-token")

  #expect(client.deleteQueries.count == 1)
  #expect(client.deleteQueries[0][kSecAttrService as String] as? String == "top.qisw.birthday")
  #expect(client.deleteQueries[0][kSecAttrAccount as String] as? String == "refresh-token")
}

@Test func deletingSystemFailureThrowsItsStatus() {
  let client = RecordingKeychainClient()
  client.deleteStatus = errSecAuthFailed

  #expect(throws: KeychainError.status(errSecAuthFailed)) {
    try makeStore(client).delete(account: "refresh-token")
  }
}

@Test func emptyAccountIsRejectedBeforeCallingKeychain() {
  let client = RecordingKeychainClient()

  #expect(throws: KeychainError.invalidAccount) {
    try makeStore(client).save(Data("secret".utf8), account: "")
  }
  #expect(client.updateQueries.isEmpty)
  #expect(client.addQueries.isEmpty)
}
