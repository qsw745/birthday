import Foundation
import Testing

@testable import BirthdayCore

private enum CredentialStoreFixtureError: Error, Equatable {
  case save
  case read
  case delete
}

private final class FailingSecureTokenStore: SecureTokenStore, @unchecked Sendable {
  var saveError: (any Error)?
  var readError: (any Error)?
  var deleteError: (any Error)?

  func save(_ data: Data, account: String) throws {
    if let saveError { throw saveError }
  }

  func read(account: String) throws -> Data? {
    if let readError { throw readError }
    return nil
  }

  func delete(account: String) throws {
    if let deleteError { throw deleteError }
  }
}

private final class SelectiveFailingSecureTokenStore: SecureTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  func save(_ data: Data, account: String) throws {
    if account == "mobile-device-credentials" {
      throw CredentialStoreFixtureError.save
    }
    lock.withLock { values[account] = data }
  }

  func read(account: String) throws -> Data? {
    lock.withLock { values[account] }
  }

  func delete(account: String) throws {
    _ = lock.withLock { values.removeValue(forKey: account) }
  }
}

private actor BindingMobileAPI: MobileAPI {
  enum Reply: Sendable {
    case success(TokenResponse)
    case failure(MobileAPIError)
  }

  private var replies: [Reply]
  private(set) var loginRequests: [LoginRequest] = []
  private(set) var snapshotTokens: [String] = []
  private let snapshotResponse: SnapshotResponse?

  init(replies: [Reply], snapshotResponse: SnapshotResponse? = nil) {
    self.replies = replies
    self.snapshotResponse = snapshotResponse
  }

  func login(_ request: LoginRequest) async throws -> TokenResponse {
    loginRequests.append(request)
    guard !replies.isEmpty else { throw MobileAPIError.invalidResponse }
    switch replies.removeFirst() {
    case .success(let response):
      return response
    case .failure(let error):
      throw error
    }
  }

  func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
    throw MobileAPIError.invalidResponse
  }

  func snapshot(accessToken: String) async throws -> SnapshotResponse {
    snapshotTokens.append(accessToken)
    guard let snapshotResponse else { throw MobileAPIError.invalidResponse }
    return snapshotResponse
  }

  func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse {
    throw MobileAPIError.invalidResponse
  }

  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    throw MobileAPIError.invalidResponse
  }

  func revoke(deviceId: UUID, accessToken: String) async throws {
    throw MobileAPIError.invalidResponse
  }

  func devices(accessToken: String) async throws -> [MobileDevice] {
    throw MobileAPIError.invalidResponse
  }
}

@Suite struct DeviceCredentialStoreTests {
  private let firstDeviceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let secondDeviceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

  @Test func savesAndLoadsTheCompleteCredentialBundleAsOneItem() throws {
    let secure = InMemorySecureTokenStore()
    let store = DeviceCredentialStore(secure: secure)
    let credentials = makeCredentials(deviceID: firstDeviceID, tokenSuffix: "first")

    try store.save(credentials)

    #expect(try store.load() == credentials)
    #expect(secure.accounts == ["mobile-device-credentials", "mobile-device-id"])
    #expect(try store.readDeviceID() == firstDeviceID)
  }

  @Test func savingNewCredentialsForTheSameDeviceOverwritesTheWholeBundle() throws {
    let secure = InMemorySecureTokenStore()
    let store = DeviceCredentialStore(secure: secure)
    try store.save(makeCredentials(deviceID: firstDeviceID, tokenSuffix: "old"))
    let replacement = makeCredentials(deviceID: firstDeviceID, tokenSuffix: "new")

    try store.save(replacement)

    #expect(try store.load() == replacement)
    #expect(try store.readDeviceID() == firstDeviceID)
    #expect(secure.accounts == ["mobile-device-credentials", "mobile-device-id"])
  }

  @Test func savingCredentialsForAnotherDevicePreservesTheOriginalIdentityAndBundle() throws {
    let secure = InMemorySecureTokenStore()
    let store = DeviceCredentialStore(secure: secure)
    let original = makeCredentials(deviceID: firstDeviceID, tokenSuffix: "original")
    try store.save(original)

    #expect(throws: DeviceCredentialStoreError.deviceIdentityMismatch) {
      try store.save(makeCredentials(deviceID: secondDeviceID, tokenSuffix: "wrong-device"))
    }

    #expect(try store.readDeviceID() == firstDeviceID)
    #expect(try store.load() == original)
  }

  @Test func corruptCredentialBundleFailsClosed() throws {
    let secure = InMemorySecureTokenStore()
    try secure.save(Data("not-json".utf8), account: "mobile-device-credentials")
    try secure.save(
      Data(firstDeviceID.uuidString.lowercased().utf8),
      account: "mobile-device-id"
    )
    let store = DeviceCredentialStore(secure: secure)

    #expect(throws: DecodingError.self) {
      try store.load()
    }
  }

  @Test func credentialBundleWithoutDeviceIdentityFailsClosed() throws {
    let secure = InMemorySecureTokenStore()
    let encoded = try MobileJSON.encoder.encode(
      makeCredentials(deviceID: firstDeviceID, tokenSuffix: "orphaned")
    )
    try secure.save(encoded, account: "mobile-device-credentials")
    let store = DeviceCredentialStore(secure: secure)

    #expect(throws: DeviceCredentialStoreError.invalidDeviceID) {
      try store.load()
    }
  }

  @Test func credentialBundleWithCorruptDeviceIdentityFailsClosed() throws {
    let secure = InMemorySecureTokenStore()
    let encoded = try MobileJSON.encoder.encode(
      makeCredentials(deviceID: firstDeviceID, tokenSuffix: "corrupt-identity")
    )
    try secure.save(encoded, account: "mobile-device-credentials")
    try secure.save(Data("not-a-canonical-uuid".utf8), account: "mobile-device-id")
    let store = DeviceCredentialStore(secure: secure)

    #expect(throws: DeviceCredentialStoreError.invalidDeviceID) {
      try store.load()
    }
  }

  @Test func credentialBundleForDifferentPersistedIdentityFailsClosed() throws {
    let secure = InMemorySecureTokenStore()
    let encoded = try MobileJSON.encoder.encode(
      makeCredentials(deviceID: secondDeviceID, tokenSuffix: "mismatched")
    )
    try secure.save(encoded, account: "mobile-device-credentials")
    try secure.save(
      Data(firstDeviceID.uuidString.lowercased().utf8),
      account: "mobile-device-id"
    )
    let store = DeviceCredentialStore(secure: secure)

    #expect(throws: DeviceCredentialStoreError.deviceIdentityMismatch) {
      try store.load()
    }
  }

  @Test func clearingCredentialsDoesNotDeleteTheStableDeviceIdentity() throws {
    let secure = InMemorySecureTokenStore()
    let store = DeviceCredentialStore(secure: secure, makeDeviceID: { self.firstDeviceID })
    let stableID = try store.loadOrCreateDeviceID()
    try store.save(makeCredentials(deviceID: stableID, tokenSuffix: "bound"))

    try store.clearCredentials()

    #expect(try store.load() == nil)
    #expect(try store.readDeviceID() == firstDeviceID)
    #expect(secure.accounts == ["mobile-device-id"])
  }

  @Test func secureStoreFailuresArePropagatedForCredentialOperations() {
    let failingSave = FailingSecureTokenStore()
    failingSave.saveError = CredentialStoreFixtureError.save
    #expect(throws: CredentialStoreFixtureError.save) {
      try DeviceCredentialStore(secure: failingSave).save(
        makeCredentials(deviceID: firstDeviceID, tokenSuffix: "save")
      )
    }

    let failingRead = FailingSecureTokenStore()
    failingRead.readError = CredentialStoreFixtureError.read
    #expect(throws: CredentialStoreFixtureError.read) {
      try DeviceCredentialStore(secure: failingRead).load()
    }

    let failingDelete = FailingSecureTokenStore()
    failingDelete.deleteError = CredentialStoreFixtureError.delete
    #expect(throws: CredentialStoreFixtureError.delete) {
      try DeviceCredentialStore(secure: failingDelete).clearCredentials()
    }
  }

  @Test func missingDeviceIdentityIsGeneratedOnceAndReusedAcrossStoreInstances() throws {
    let secure = InMemorySecureTokenStore()
    let first = DeviceCredentialStore(secure: secure, makeDeviceID: { self.firstDeviceID })
    let second = DeviceCredentialStore(secure: secure, makeDeviceID: { self.secondDeviceID })

    #expect(try first.readDeviceID() == nil)
    #expect(try first.loadOrCreateDeviceID() == firstDeviceID)
    #expect(try second.loadOrCreateDeviceID() == firstDeviceID)
    #expect(try second.readDeviceID() == firstDeviceID)
    #expect(secure.accounts == ["mobile-device-id"])
  }

  @Test func corruptDeviceIdentityFailsClosedInsteadOfCreatingAGhostSession() throws {
    let secure = InMemorySecureTokenStore()
    try secure.save(Data("not-a-canonical-uuid".utf8), account: "mobile-device-id")
    let store = DeviceCredentialStore(secure: secure, makeDeviceID: { self.secondDeviceID })

    #expect(throws: DeviceCredentialStoreError.invalidDeviceID) {
      try store.loadOrCreateDeviceID()
    }
  }

  @Test func deviceIdentitySaveFailureReturnsNoEphemeralIdentity() {
    let secure = FailingSecureTokenStore()
    secure.saveError = CredentialStoreFixtureError.save
    let store = DeviceCredentialStore(secure: secure, makeDeviceID: { self.firstDeviceID })

    #expect(throws: CredentialStoreFixtureError.save) {
      try store.loadOrCreateDeviceID()
    }
    #expect((try? store.readDeviceID()) == nil)
  }

  @Test func concurrentIdentityLoadsAcrossStoreInstancesReturnTheSameID() async throws {
    let secure = InMemorySecureTokenStore()
    let stores = (0..<24).map { _ in DeviceCredentialStore(secure: secure) }

    let identities = try await withThrowingTaskGroup(of: UUID.self) { group in
      for store in stores {
        group.addTask { try store.loadOrCreateDeviceID() }
      }
      var result: [UUID] = []
      for try await identity in group {
        result.append(identity)
      }
      return result
    }

    #expect(identities.count == 24)
    #expect(Set(identities).count == 1)
    #expect(try stores[0].readDeviceID() == identities.first)
  }

  @Test func binderUsesThePersistedIdentityAndSavesTheCompleteResponse() async throws {
    let secure = InMemorySecureTokenStore()
    let credentials = DeviceCredentialStore(
      secure: secure,
      makeDeviceID: { self.firstDeviceID }
    )
    let response = makeTokenResponse(deviceID: firstDeviceID, tokenSuffix: "bound")
    let api = BindingMobileAPI(replies: [.success(response)])
    let binder = ServerDeviceBinder(api: api, credentials: credentials)

    try await binder.bind(username: " admin ", password: "secret", deviceName: " iPhone ")

    let requests = await api.loginRequests
    #expect(requests.count == 1)
    #expect(requests[0].deviceId == firstDeviceID)
    #expect(requests[0].username == "admin")
    #expect(requests[0].deviceName == "iPhone")
    #expect(try credentials.load() == DeviceCredentials(response))
  }

  @Test func snapshotAfterBindingReloadsSavedCredentialsWithoutSubmittingPasswordAgain()
    async throws
  {
    let secure = InMemorySecureTokenStore()
    let credentials = DeviceCredentialStore(
      secure: secure,
      makeDeviceID: { self.firstDeviceID }
    )
    let response = makeTokenResponse(deviceID: firstDeviceID, tokenSuffix: "bound")
    let snapshot = SnapshotResponse(cursor: 41, birthdays: [makeAPIBirthday()])
    let api = BindingMobileAPI(replies: [.success(response)], snapshotResponse: snapshot)
    let binder = ServerDeviceBinder(api: api, credentials: credentials)

    try await binder.bind(username: "admin", password: "secret", deviceName: "iPhone")
    let loaded = try await binder.loadSnapshot()

    #expect(loaded == snapshot)
    #expect(await api.loginRequests.count == 1)
    #expect(await api.snapshotTokens == ["access-bound"])
  }

  @Test func snapshotWithoutSavedCredentialsFailsBeforeNetwork() async throws {
    let credentials = DeviceCredentialStore(secure: InMemorySecureTokenStore())
    let api = BindingMobileAPI(replies: [])
    let binder = ServerDeviceBinder(api: api, credentials: credentials)

    await #expect(throws: ServerDeviceBindingError.credentialsUnavailable) {
      try await binder.loadSnapshot()
    }

    #expect(await api.snapshotTokens.isEmpty)
  }

  @Test func retryAfterALostResponseReusesTheSameStableIdentity() async throws {
    let secure = InMemorySecureTokenStore()
    let credentials = DeviceCredentialStore(
      secure: secure,
      makeDeviceID: { self.firstDeviceID }
    )
    let response = makeTokenResponse(deviceID: firstDeviceID, tokenSuffix: "retry")
    let api = BindingMobileAPI(
      replies: [.failure(.transport("url_error_-1005")), .success(response)]
    )
    let binder = ServerDeviceBinder(api: api, credentials: credentials)

    await #expect(throws: MobileAPIError.transport("url_error_-1005")) {
      try await binder.bind(username: "admin", password: "secret", deviceName: "iPhone")
    }
    try await binder.bind(username: "admin", password: "secret", deviceName: "iPhone")

    let requests = await api.loginRequests
    #expect(requests.map(\.deviceId) == [firstDeviceID, firstDeviceID])
    #expect(try credentials.load() == DeviceCredentials(response))
  }

  @Test func binderRejectsAMismatchedResponseWithoutSavingTokens() async throws {
    let secure = InMemorySecureTokenStore()
    let credentials = DeviceCredentialStore(
      secure: secure,
      makeDeviceID: { self.firstDeviceID }
    )
    let api = BindingMobileAPI(
      replies: [.success(makeTokenResponse(deviceID: secondDeviceID, tokenSuffix: "wrong"))]
    )
    let binder = ServerDeviceBinder(api: api, credentials: credentials)

    await #expect(throws: ServerDeviceBindingError.responseDeviceIDMismatch) {
      try await binder.bind(username: "admin", password: "secret", deviceName: "iPhone")
    }

    #expect(try credentials.load() == nil)
    #expect(try credentials.readDeviceID() == firstDeviceID)
  }

  @Test func tokenSaveFailureStillLeavesTheStableIdentityForSafeRebind() async throws {
    let secure = SelectiveFailingSecureTokenStore()
    let credentials = DeviceCredentialStore(
      secure: secure,
      makeDeviceID: { self.firstDeviceID }
    )
    let api = BindingMobileAPI(
      replies: [.success(makeTokenResponse(deviceID: firstDeviceID, tokenSuffix: "unsaved"))]
    )
    let binder = ServerDeviceBinder(api: api, credentials: credentials)

    await #expect(throws: CredentialStoreFixtureError.save) {
      try await binder.bind(username: "admin", password: "secret", deviceName: "iPhone")
    }

    #expect(try credentials.load() == nil)
    #expect(try credentials.readDeviceID() == firstDeviceID)
  }

  @Test func directCredentialSaveFailureStillEstablishesTheStableIdentity() throws {
    let secure = SelectiveFailingSecureTokenStore()
    let store = DeviceCredentialStore(secure: secure)

    #expect(throws: CredentialStoreFixtureError.save) {
      try store.save(makeCredentials(deviceID: firstDeviceID, tokenSuffix: "unsaved-direct"))
    }

    #expect(try store.readDeviceID() == firstDeviceID)
    #expect(try store.load() == nil)
  }

  private func makeCredentials(deviceID: UUID, tokenSuffix: String) -> DeviceCredentials {
    DeviceCredentials(
      deviceId: deviceID,
      accessToken: "access-\(tokenSuffix)",
      accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
      refreshToken: "refresh-\(tokenSuffix)",
      refreshExpiresAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
  }

  private func makeTokenResponse(deviceID: UUID, tokenSuffix: String) -> TokenResponse {
    TokenResponse(
      deviceId: deviceID,
      accessToken: "access-\(tokenSuffix)",
      accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
      refreshToken: "refresh-\(tokenSuffix)",
      refreshExpiresAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
  }
}
