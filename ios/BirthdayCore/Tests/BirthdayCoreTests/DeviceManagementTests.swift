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

private enum DeleteFailure: Error, Equatable { case denied }

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
    let service = DeviceManagementService(api: api, credentials: credentials)

    let outcome = try await service.beginUnlinkCurrent()

    #expect(
      outcome
        == .needsLocalConfirmation(message: "服务器可能仍保留此设备，可在重新绑定后撤销")
    )
    #expect(try credentials.load() != nil)

    try await service.confirmLocalUnlink()

    #expect(try credentials.load() == nil)
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
