import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

private actor DeviceManagementAPI: MobileAPI {
  enum Mode: Sendable {
    case success
    case failure(MobileAPIError)
    case suspended
  }

  private let listedDevices: [MobileDevice]
  private let revokeMode: Mode
  private(set) var deviceTokens: [String] = []
  private(set) var revokeRequests: [(UUID, String)] = []
  private var continuation: CheckedContinuation<Void, Never>?

  init(listedDevices: [MobileDevice] = [], revokeMode: Mode = .success) {
    self.listedDevices = listedDevices
    self.revokeMode = revokeMode
  }

  func login(_ request: LoginRequest) async throws -> TokenResponse {
    throw MobileAPIError.invalidResponse
  }

  func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
    throw MobileAPIError.invalidResponse
  }

  func snapshot(accessToken: String) async throws -> SnapshotResponse {
    throw MobileAPIError.invalidResponse
  }

  func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse {
    throw MobileAPIError.invalidResponse
  }

  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    throw MobileAPIError.invalidResponse
  }

  func revoke(deviceId: UUID, accessToken: String) async throws {
    revokeRequests.append((deviceId, accessToken))
    switch revokeMode {
    case .success:
      return
    case .failure(let error):
      throw error
    case .suspended:
      await withCheckedContinuation { continuation = $0 }
    }
  }

  func devices(accessToken: String) async throws -> [MobileDevice] {
    deviceTokens.append(accessToken)
    return listedDevices
  }

  func resumeRevoke() {
    continuation?.resume()
    continuation = nil
  }
}

private actor RefreshUnlinkRaceAPI: MobileAPI {
  private let deviceID: UUID
  private var refreshStarted = false
  private var refreshContinuation: CheckedContinuation<Void, Never>?
  private var revokeCount = 0

  init(deviceID: UUID) {
    self.deviceID = deviceID
  }

  func login(_ request: LoginRequest) async throws -> TokenResponse {
    throw MobileAPIError.invalidResponse
  }

  func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
    refreshStarted = true
    await withCheckedContinuation { refreshContinuation = $0 }
    return TokenResponse(
      deviceId: deviceID,
      accessToken: "stale-refreshed-access",
      accessExpiresAt: Date(timeIntervalSince1970: 1_800_003_600),
      refreshToken: "stale-refreshed-refresh",
      refreshExpiresAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
  }

  func snapshot(accessToken: String) async throws -> SnapshotResponse {
    throw MobileAPIError.invalidResponse
  }

  func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse {
    PushResponse(results: [])
  }

  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    PullResponse(changes: [], nextCursor: cursor, hasMore: false)
  }

  func revoke(deviceId: UUID, accessToken: String) async throws {
    revokeCount += 1
  }

  func devices(accessToken: String) async throws -> [MobileDevice] { [] }

  func waitForRefresh() async {
    while !refreshStarted { await Task.yield() }
  }

  func resumeRefresh() {
    refreshContinuation?.resume()
    refreshContinuation = nil
  }

  func recordedRevokeCount() -> Int { revokeCount }
}

private enum DeleteFailure: Error, Equatable { case denied }

private enum ReadFailure: Error, Equatable { case denied }

private final class DeleteFailingSecureTokenStore: SecureTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var shouldFailDelete = true

  func save(_ data: Data, account: String) throws {
    lock.withLock { values[account] = data }
  }

  func read(account: String) throws -> Data? {
    lock.withLock { values[account] }
  }

  func delete(account: String) throws {
    try lock.withLock {
      if shouldFailDelete { throw DeleteFailure.denied }
      values.removeValue(forKey: account)
    }
  }

  func allowDelete() {
    lock.withLock { shouldFailDelete = false }
  }
}

private final class ReadFailingSecureTokenStore: SecureTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var shouldFailRead = false

  func save(_ data: Data, account: String) throws {
    lock.withLock { values[account] = data }
  }

  func read(account: String) throws -> Data? {
    try lock.withLock {
      if shouldFailRead { throw ReadFailure.denied }
      return values[account]
    }
  }

  func delete(account: String) throws {
    _ = lock.withLock { values.removeValue(forKey: account) }
  }

  func failReads() {
    lock.withLock { shouldFailRead = true }
  }
}

private actor RemoteLeaseSuspension {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?

  func suspend() async {
    started = true
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilStarted() async {
    while !started { await Task.yield() }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private actor DeviceBindingStub: ServerDeviceBinding {
  enum Mode: Sendable {
    case success
    case suspended
  }

  private let mode: Mode
  private let credentials: DeviceCredentialStore
  private let savedCredentials: DeviceCredentials
  private var requests: [(String, String)] = []
  private var continuation: CheckedContinuation<Void, Never>?

  init(
    mode: Mode = .success,
    credentials: DeviceCredentialStore,
    savedCredentials: DeviceCredentials
  ) {
    self.mode = mode
    self.credentials = credentials
    self.savedCredentials = savedCredentials
  }

  func bind(username: String, password: String, deviceName: String) async throws {
    requests.append((username, deviceName))
    if mode == .suspended {
      await withCheckedContinuation { continuation = $0 }
    }
    try credentials.save(savedCredentials)
  }

  func loadSnapshot() async throws -> SnapshotResponse {
    throw MobileAPIError.invalidResponse
  }

  func waitUntilBinding() async {
    while requests.isEmpty { await Task.yield() }
  }

  func resumeBinding() {
    continuation?.resume()
    continuation = nil
  }

  func requestCount() -> Int { requests.count }
}

@Suite struct DeviceManagementTests {
  private let currentID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let otherID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

  @Test func deviceListingMarksOnlyThePersistedCurrentDevice() async throws {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI(
      listedDevices: [
        makeDevice(id: otherID, name: "iPad"), makeDevice(id: currentID, name: "iPhone"),
      ]
    )
    let service = DeviceManagementService(api: api, credentials: credentials)

    let devices = try await service.listDevices()

    #expect(devices.map(\.device.deviceName) == ["iPad", "iPhone"])
    #expect(devices.map(\.isCurrent) == [false, true])
    #expect(await api.deviceTokens == ["access-current"])
  }

  @Test func typedUsernameMismatchMakesNoNetworkRequest() async throws {
    let credentials = try makeCredentialStore(username: "Adminé")
    let api = DeviceManagementAPI()
    let service = DeviceManagementService(api: api, credentials: credentials)

    await #expect(throws: DeviceManagementError.confirmationMismatch) {
      try await service.revokeOther(makeDevice(id: otherID), typedUsername: "adminé")
    }

    #expect(await api.revokeRequests.isEmpty)
  }

  @Test func legacyCredentialsRequireRebindBeforeAnyDestructiveDeviceAction() async throws {
    let credentials = try makeCredentialStore(username: nil)
    let api = DeviceManagementAPI()
    let service = DeviceManagementService(api: api, credentials: credentials)

    await #expect(throws: DeviceManagementError.rebindRequired) {
      try await service.revokeOther(makeDevice(id: otherID), typedUsername: "admin")
    }

    #expect(await api.revokeRequests.isEmpty)
  }

  @Test func revokesAnotherDeviceWithTheExactUsernameAndCurrentAccessToken() async throws {
    let credentials = try makeCredentialStore(username: "Adminé")
    let api = DeviceManagementAPI()
    let service = DeviceManagementService(api: api, credentials: credentials)

    try await service.revokeOther(makeDevice(id: otherID), typedUsername: "Adminé")

    #expect(await api.revokeRequests.map(\.0) == [otherID])
    #expect(await api.revokeRequests.map(\.1) == ["access-current"])
    #expect(try credentials.load() != nil)
  }

  @Test func anotherDevicePathCannotRevokeTheCurrentDevice() async throws {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI()
    let service = DeviceManagementService(api: api, credentials: credentials)

    await #expect(throws: DeviceManagementError.currentDeviceRequiresUnlink) {
      try await service.revokeOther(makeDevice(id: currentID), typedUsername: "admin")
    }

    #expect(await api.revokeRequests.isEmpty)
  }

  @Test func successfulCurrentUnlinkClearsOnlyCredentialsAndPreservesLocalStoreBytes() async throws
  {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI()
    let service = DeviceManagementService(api: api, credentials: credentials)
    let container = try makeSyncContainer()
    let store = BirthdayStore(modelContainer: container)
    _ = try await store.save(
      BirthdayDraft(
        name: "妈妈",
        lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ),
      id: currentID,
      now: Date(timeIntervalSince1970: 1_700_000_000),
      timeZone: TimeZone(secondsFromGMT: 28_800)!
    )
    let context = ModelContext(container)
    context.insert(SyncMetadataEntity(key: "primary", cursor: 47))
    context.insert(
      SyncConflictEntity(
        entityId: otherID,
        operationId: nil,
        localSnapshotJSON: Data([0x01, 0x02]),
        remoteSnapshotJSON: Data([0x03, 0x04]),
        createdAt: Date(timeIntervalSince1970: 1_700_000_100),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
      )
    )
    try context.save()
    let before = try localStoreBytes(container)

    let outcome = try await service.beginUnlinkCurrent()

    #expect(outcome == .unlinked)
    #expect(try credentials.load() == nil)
    #expect(try credentials.readDeviceID() == currentID)
    #expect(try localStoreBytes(container) == before)
  }

  @Test func transportFailurePreservesCredentialsUntilExplicitLocalConfirmation() async throws {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI(revokeMode: .failure(.transport("url_error_-1009")))
    let remoteAccessGate = RemoteSyncAccessGate()
    let service = DeviceManagementService(
      api: api,
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )

    let outcome = try await service.beginUnlinkCurrent()

    #expect(
      outcome
        == .needsLocalConfirmation(message: "服务器可能仍保留此设备，可在重新绑定后撤销")
    )
    #expect(try credentials.load() != nil)
    #expect(await remoteAccessGate.paused())

    try await service.confirmLocalUnlink()

    #expect(try credentials.load() == nil)
    #expect(await remoteAccessGate.paused())
  }

  @Test func cancellingTransportFallbackResumesOnlyWithANewRemoteGeneration() async throws {
    let credentials = try makeCredentialStore()
    let remoteAccessGate = RemoteSyncAccessGate()
    let service = DeviceManagementService(
      api: DeviceManagementAPI(revokeMode: .failure(.transport("offline"))),
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )
    let initialGeneration = await remoteAccessGate.currentGeneration()

    #expect(
      try await service.beginUnlinkCurrent()
        == .needsLocalConfirmation(message: DeviceManagementService.localUnlinkWarning)
    )
    await #expect(throws: RemoteSyncAccessError.paused) {
      try await remoteAccessGate.perform { _ in true }
    }

    #expect(await service.cancelPendingLocalUnlink())

    #expect(await remoteAccessGate.paused() == false)
    #expect(await remoteAccessGate.currentGeneration() > initialGeneration)
    #expect(try await remoteAccessGate.perform { _ in true })
    #expect(try credentials.load() != nil)
  }

  @Test func rebindPauseRejectsFutureRemoteWorkUntilBindingStartsANewGeneration() async throws {
    let credentials = try makeCredentialStore()
    let remoteAccessGate = RemoteSyncAccessGate()
    let service = DeviceManagementService(
      api: DeviceManagementAPI(),
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )

    await service.pauseForRebind()
    let pausedGeneration = await remoteAccessGate.currentGeneration()
    await #expect(throws: RemoteSyncAccessError.paused) {
      try await remoteAccessGate.perform { _ in true }
    }

    let binding = try await service.reserveBinding()
    try await service.resumeAfterBinding(binding)

    #expect(await remoteAccessGate.currentGeneration() > pausedGeneration)
    #expect(try await remoteAccessGate.perform { _ in true })
  }

  @Test(arguments: [MobileAPIError.accessExpired, MobileAPIError.refreshInvalid])
  func authFailureRequiresRebindAndNeverClearsLocally(error: MobileAPIError) async throws {
    let credentials = try makeCredentialStore()
    let service = DeviceManagementService(
      api: DeviceManagementAPI(revokeMode: .failure(error)),
      credentials: credentials
    )

    await #expect(throws: DeviceManagementError.rebindRequired) {
      try await service.beginUnlinkCurrent()
    }

    #expect(try credentials.load() != nil)
  }

  @Test func serverFailureRemainsDiagnosableAndNeverClearsLocally() async throws {
    let credentials = try makeCredentialStore()
    let error = MobileAPIError.server(code: "temporarily_unavailable", status: 503)
    let service = DeviceManagementService(
      api: DeviceManagementAPI(revokeMode: .failure(error)),
      credentials: credentials
    )

    await #expect(throws: error) {
      try await service.beginUnlinkCurrent()
    }

    #expect(try credentials.load() != nil)
  }

  @Test func serverRevokeSuccessWithKeychainFailureReportsTheExactLocalFailure() async throws {
    let secure = DeleteFailingSecureTokenStore()
    let credentials = DeviceCredentialStore(secure: secure, makeDeviceID: { self.currentID })
    try credentials.save(makeCredentials())
    let api = DeviceManagementAPI()
    let service = DeviceManagementService(api: api, credentials: credentials)

    await #expect(
      throws: DeviceManagementError.credentialClearFailedAfterServerRevoke
    ) {
      try await service.beginUnlinkCurrent()
    }

    #expect(await api.revokeRequests.count == 1)
    #expect(try credentials.load() != nil)
    #expect(await service.isFailClosedAfterServerRevoke)

    secure.allowDelete()
    try await service.confirmLocalUnlink()

    #expect(try credentials.load() == nil)
    #expect(await service.isFailClosedAfterServerRevoke == false)
  }

  @Test func overlappingUnlinkRequestsIssueOnlyOneRevoke() async throws {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI(revokeMode: .suspended)
    let service = DeviceManagementService(api: api, credentials: credentials)
    let first = Task { try await service.beginUnlinkCurrent() }
    while await api.revokeRequests.isEmpty { await Task.yield() }

    await #expect(throws: DeviceManagementError.operationInProgress) {
      try await service.beginUnlinkCurrent()
    }
    await api.resumeRevoke()

    #expect(try await first.value == .unlinked)
    #expect(await api.revokeRequests.count == 1)
  }

  @Test func suspendedRevokeRejectsBindingBeforeSaveAndCannotClearALaterBinding() async throws {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI(revokeMode: .suspended)
    let remoteAccessGate = RemoteSyncAccessGate()
    let service = DeviceManagementService(
      api: api,
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )
    let binder = DeviceBindingStub(
      credentials: credentials,
      savedCredentials: reboundCredentials()
    )
    let unlink = Task { try await service.beginUnlinkCurrent() }
    while await api.revokeRequests.isEmpty { await Task.yield() }

    await #expect(throws: DeviceManagementError.operationInProgress) {
      try await service.performBinding(
        using: binder,
        username: "admin",
        password: "new-password",
        deviceName: "Rebound iPhone"
      )
    }
    #expect(await binder.requestCount() == 0)
    #expect(try credentials.load()?.accessToken == "access-current")
    #expect(await remoteAccessGate.paused())

    await api.resumeRevoke()
    #expect(try await unlink.value == .unlinked)
    #expect(try credentials.load() == nil)

    try await service.performBinding(
      using: binder,
      username: "admin",
      password: "new-password",
      deviceName: "Rebound iPhone"
    )
    #expect(try credentials.load()?.accessToken == "access-rebound")
    #expect(await remoteAccessGate.paused() == false)
  }

  @Test func suspendedBindingRejectsUnlinkUntilBindingCompletes() async throws {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI()
    let service = DeviceManagementService(api: api, credentials: credentials)
    let binder = DeviceBindingStub(
      mode: .suspended,
      credentials: credentials,
      savedCredentials: reboundCredentials()
    )
    let binding = Task {
      try await service.performBinding(
        using: binder,
        username: "admin",
        password: "new-password",
        deviceName: "Rebound iPhone"
      )
    }
    await binder.waitUntilBinding()

    await #expect(throws: DeviceManagementError.operationInProgress) {
      try await service.beginUnlinkCurrent()
    }
    #expect(await api.revokeRequests.isEmpty)

    await binder.resumeBinding()
    try await binding.value
    #expect(try credentials.load()?.accessToken == "access-rebound")

    #expect(try await service.beginUnlinkCurrent() == .unlinked)
    #expect(await api.revokeRequests.map(\.1) == ["access-rebound"])
  }

  @Test func suspendedBindingRejectsASecondBindingBeforeSave() async throws {
    let credentials = try makeCredentialStore()
    let service = DeviceManagementService(api: DeviceManagementAPI(), credentials: credentials)
    let firstBinder = DeviceBindingStub(
      mode: .suspended,
      credentials: credentials,
      savedCredentials: reboundCredentials()
    )
    let secondBinder = DeviceBindingStub(
      credentials: credentials,
      savedCredentials: DeviceCredentials(
        deviceId: currentID,
        accessToken: "access-second",
        accessExpiresAt: Date(timeIntervalSince1970: 1_820_000_000),
        refreshToken: "refresh-second",
        refreshExpiresAt: Date(timeIntervalSince1970: 1_920_000_000),
        username: "admin"
      )
    )
    let firstBinding = Task {
      try await service.performBinding(
        using: firstBinder,
        username: "admin",
        password: "first-password",
        deviceName: "First iPhone"
      )
    }
    await firstBinder.waitUntilBinding()

    await #expect(throws: DeviceManagementError.operationInProgress) {
      try await service.performBinding(
        using: secondBinder,
        username: "admin",
        password: "second-password",
        deviceName: "Second iPhone"
      )
    }
    #expect(await secondBinder.requestCount() == 0)

    await firstBinder.resumeBinding()
    try await firstBinding.value
    #expect(try credentials.load()?.accessToken == "access-rebound")
  }

  @Test func pendingTransportConfirmationRejectsBindingBeforeSave() async throws {
    let credentials = try makeCredentialStore()
    let service = DeviceManagementService(
      api: DeviceManagementAPI(revokeMode: .failure(.transport("offline"))),
      credentials: credentials
    )
    let binder = DeviceBindingStub(
      credentials: credentials,
      savedCredentials: reboundCredentials()
    )
    _ = try await service.beginUnlinkCurrent()

    await #expect(throws: DeviceManagementError.operationInProgress) {
      try await service.performBinding(
        using: binder,
        username: "admin",
        password: "new-password",
        deviceName: "Rebound iPhone"
      )
    }
    #expect(await binder.requestCount() == 0)
    #expect(try credentials.load()?.accessToken == "access-current")
  }

  @Test func pendingTransportCleanupRejectsBindingBeforeSave() async throws {
    let secure = DeleteFailingSecureTokenStore()
    let credentials = DeviceCredentialStore(secure: secure, makeDeviceID: { self.currentID })
    try credentials.save(makeCredentials())
    let service = DeviceManagementService(
      api: DeviceManagementAPI(revokeMode: .failure(.transport("offline"))),
      credentials: credentials
    )
    let binder = DeviceBindingStub(
      credentials: credentials,
      savedCredentials: reboundCredentials()
    )
    _ = try await service.beginUnlinkCurrent()
    await #expect(throws: DeviceManagementError.credentialClearFailed) {
      try await service.confirmLocalUnlink()
    }

    await #expect(throws: DeviceManagementError.operationInProgress) {
      try await service.performBinding(
        using: binder,
        username: "admin",
        password: "new-password",
        deviceName: "Rebound iPhone"
      )
    }
    #expect(await binder.requestCount() == 0)
    #expect(try credentials.load()?.accessToken == "access-current")
  }

  @Test func preCancelledUnlinkMakesNoRevokeAndLeavesCredentialsIntact() async throws {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI()
    let service = DeviceManagementService(api: api, credentials: credentials)
    let task = Task {
      try await Task.sleep(for: .seconds(30))
      return try await service.beginUnlinkCurrent()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }

    #expect(await api.revokeRequests.isEmpty)
    #expect(try credentials.load() != nil)
  }

  @Test func unlinkCannotBeUndoneByAnOlderInFlightCredentialRefresh() async throws {
    let secure = InMemorySecureTokenStore()
    let credentials = DeviceCredentialStore(secure: secure, makeDeviceID: { self.currentID })
    try credentials.save(
      DeviceCredentials(
        deviceId: currentID,
        accessToken: "expiring-access",
        accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_030),
        refreshToken: "refresh-current",
        refreshExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
        username: "admin"
      ))
    let api = RefreshUnlinkRaceAPI(deviceID: currentID)
    let remoteAccessGate = RemoteSyncAccessGate()
    let engine = SyncEngine(
      api: api,
      store: try makeSyncStore(),
      credentials: credentials,
      remoteAccessGate: remoteAccessGate,
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
    let service = DeviceManagementService(
      api: api,
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )
    let sync = Task { try await engine.syncNow() }
    await api.waitForRefresh()

    let unlink = Task { try await service.beginUnlinkCurrent() }
    for _ in 0..<100 { await Task.yield() }
    #expect(await api.recordedRevokeCount() == 0)
    #expect(try credentials.load() != nil)

    await api.resumeRefresh()
    do {
      _ = try await sync.value
    } catch RemoteSyncAccessError.staleGeneration {
      // The pause generation fences the old refresh before its Keychain write.
    } catch is CancellationError {
      // Cooperative APIs may observe the gate's cancellation before returning a response.
    }
    #expect(try await unlink.value == .unlinked)

    #expect(try credentials.load() == nil)
    let restartedStore = DeviceCredentialStore(secure: secure)
    #expect(try restartedStore.load() == nil)
  }

  @Test func cancellationWhileDrainingResumesOnlyTheUnlinkPauseOwner() async throws {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI()
    let remoteAccessGate = RemoteSyncAccessGate()
    let suspension = RemoteLeaseSuspension()
    let existing = Task {
      try await remoteAccessGate.perform { _ in
        await suspension.suspend()
        return true
      }
    }
    await suspension.waitUntilStarted()
    let service = DeviceManagementService(
      api: api,
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )
    let unlink = Task { try await service.beginUnlinkCurrent() }
    for _ in 0..<100 { await Task.yield() }

    unlink.cancel()
    await suspension.resume()
    _ = try? await existing.value

    await #expect(throws: CancellationError.self) {
      try await unlink.value
    }
    #expect(await api.revokeRequests.isEmpty)
    #expect(try credentials.load() != nil)
    #expect(await remoteAccessGate.paused() == false)
  }

  @Test func credentialReadFailureAfterDrainDoesNotLeakTheUnlinkPause() async throws {
    let secure = ReadFailingSecureTokenStore()
    let credentials = DeviceCredentialStore(secure: secure, makeDeviceID: { self.currentID })
    try credentials.save(makeCredentials())
    secure.failReads()
    let remoteAccessGate = RemoteSyncAccessGate()
    let service = DeviceManagementService(
      api: DeviceManagementAPI(),
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )

    await #expect(throws: ReadFailure.denied) {
      try await service.beginUnlinkCurrent()
    }

    #expect(await remoteAccessGate.paused() == false)
    #expect(try await remoteAccessGate.perform { _ in true })
  }

  @Test func failedTransportCleanupRemainsVisibleAndCanExplicitlyResumeOldCredentials() async throws
  {
    let secure = DeleteFailingSecureTokenStore()
    let credentials = DeviceCredentialStore(secure: secure, makeDeviceID: { self.currentID })
    try credentials.save(makeCredentials())
    let remoteAccessGate = RemoteSyncAccessGate()
    let service = DeviceManagementService(
      api: DeviceManagementAPI(revokeMode: .failure(.transport("offline"))),
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )

    #expect(
      try await service.beginUnlinkCurrent()
        == .needsLocalConfirmation(message: DeviceManagementService.localUnlinkWarning)
    )
    await #expect(throws: DeviceManagementError.credentialClearFailed) {
      try await service.confirmLocalUnlink()
    }
    #expect(await service.pendingLocalCleanup == .transportUnknown)
    #expect(await remoteAccessGate.paused())

    try await service.resumeSyncAfterPendingLocalCleanup()

    #expect(await service.pendingLocalCleanup == nil)
    #expect(await remoteAccessGate.paused() == false)
    #expect(try credentials.load() != nil)
  }

  @Test func pendingTransportCleanupRejectsAnotherUnlinkWithoutASecondRevoke() async throws {
    let credentials = try makeCredentialStore()
    let api = DeviceManagementAPI(revokeMode: .failure(.transport("offline")))
    let service = DeviceManagementService(api: api, credentials: credentials)

    #expect(
      try await service.beginUnlinkCurrent()
        == .needsLocalConfirmation(message: DeviceManagementService.localUnlinkWarning)
    )
    await #expect(throws: DeviceManagementError.operationInProgress) {
      try await service.beginUnlinkCurrent()
    }
    #expect(await api.revokeRequests.count == 1)
  }

  @Test func serverRevokedCleanupFailureCannotResumeTheOldCredentials() async throws {
    let secure = DeleteFailingSecureTokenStore()
    let credentials = DeviceCredentialStore(secure: secure, makeDeviceID: { self.currentID })
    try credentials.save(makeCredentials())
    let remoteAccessGate = RemoteSyncAccessGate()
    let service = DeviceManagementService(
      api: DeviceManagementAPI(),
      credentials: credentials,
      remoteAccessGate: remoteAccessGate
    )

    await #expect(throws: DeviceManagementError.credentialClearFailedAfterServerRevoke) {
      try await service.beginUnlinkCurrent()
    }
    #expect(await service.pendingLocalCleanup == .serverRevoked)

    await #expect(throws: DeviceManagementError.revokedSessionRequiresLocalCleanup) {
      try await service.resumeSyncAfterPendingLocalCleanup()
    }
    #expect(await remoteAccessGate.paused())
    #expect(try credentials.load() != nil)
  }

  private func makeCredentialStore(username: String? = "admin") throws -> DeviceCredentialStore {
    let store = DeviceCredentialStore(
      secure: InMemorySecureTokenStore(),
      makeDeviceID: { self.currentID }
    )
    try store.save(makeCredentials(username: username))
    return store
  }

  private func makeCredentials(username: String? = "admin") -> DeviceCredentials {
    DeviceCredentials(
      deviceId: currentID,
      accessToken: "access-current",
      accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
      refreshToken: "refresh-current",
      refreshExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      username: username
    )
  }

  private func reboundCredentials() -> DeviceCredentials {
    DeviceCredentials(
      deviceId: currentID,
      accessToken: "access-rebound",
      accessExpiresAt: Date(timeIntervalSince1970: 1_810_000_000),
      refreshToken: "refresh-rebound",
      refreshExpiresAt: Date(timeIntervalSince1970: 1_910_000_000),
      username: "admin"
    )
  }

  private func makeDevice(id: UUID, name: String = "iPad") -> MobileDevice {
    MobileDevice(
      deviceId: id,
      deviceName: name,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastUsedAt: nil,
      revokedAt: nil
    )
  }
}

private func localStoreBytes(_ container: ModelContainer) throws -> Data {
  let context = ModelContext(container)
  let birthdays: [[String: Any]] = try context.fetch(FetchDescriptor<BirthdayEntity>()).map {
    [
      "id": $0.id.uuidString,
      "name": $0.name,
      "lunarMonth": $0.lunarMonth,
      "lunarDay": $0.lunarDay,
      "isLeapMonth": $0.isLeapMonth,
      "reminderTimeMinutes": $0.reminderTimeMinutes,
      "notifyDayBefore": $0.notifyDayBefore,
      "notifySameDay": $0.notifySameDay,
      "emailEnabled": $0.emailEnabled,
      "emailAddress": $0.emailAddress,
      "emailMessage": $0.emailMessage,
      "nextSolarDate": $0.nextSolarDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
      "version": $0.version,
      "createdAt": $0.createdAt.timeIntervalSince1970,
      "updatedAt": $0.updatedAt.timeIntervalSince1970,
      "deletedAt": $0.deletedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
      "syncStateRaw": $0.syncStateRaw,
    ]
  }
  let operations: [[String: Any]] = try context.fetch(FetchDescriptor<SyncOperationEntity>()).map {
    [
      "operationId": $0.operationId.uuidString,
      "entityId": $0.entityId.uuidString,
      "operationType": $0.operationType,
      "baseVersion": $0.baseVersion,
      "payloadJSON": $0.payloadJSON.base64EncodedString(),
      "createdAt": $0.createdAt.timeIntervalSince1970,
      "attemptCount": $0.attemptCount,
      "nextRetryAt": $0.nextRetryAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
      "lastErrorCategory": $0.lastErrorCategory.map { $0 as Any } ?? NSNull(),
    ]
  }
  let conflicts: [[String: Any]] = try context.fetch(FetchDescriptor<SyncConflictEntity>()).map {
    [
      "entityId": $0.entityId.uuidString,
      "operationId": $0.operationId.map { $0.uuidString as Any } ?? NSNull(),
      "localSnapshotJSON": $0.localSnapshotJSON.base64EncodedString(),
      "remoteSnapshotJSON": $0.remoteSnapshotJSON.base64EncodedString(),
      "createdAt": $0.createdAt.timeIntervalSince1970,
      "updatedAt": $0.updatedAt.timeIntervalSince1970,
      "kindRaw": $0.kindRaw,
    ]
  }
  let metadata: [[String: Any]] = try context.fetch(FetchDescriptor<SyncMetadataEntity>()).map {
    ["key": $0.key, "cursor": $0.cursor]
  }
  return try JSONSerialization.data(
    withJSONObject: [
      "birthdays": birthdays,
      "operations": operations,
      "conflicts": conflicts,
      "metadata": metadata,
    ],
    options: [.sortedKeys]
  )
}
