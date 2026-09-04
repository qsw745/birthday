import CloudKit
import Foundation
import Testing

@testable import BirthdayCore

@Suite(.serialized) struct CloudSyncCoordinatorTests {
  @Test func systemAccountProviderReturnsOnlyTheOpaqueRecordNameForAnAvailableAccount() async throws {
    let client = FakeCloudAccountSystemClient(
      status: .available,
      recordID: CKRecord.ID(recordName: "opaque-account-record")
    )
    let provider = SystemCloudAccountProvider(client: client)

    #expect(
      try await provider.currentAccount() == .available(recordName: "opaque-account-record")
    )
  }

  @Test func firstLaunchDefaultsOnAndStartsSyncForTheAvailableAccount() async throws {
    let preference = try makeCloudPreferenceStore()
    let account = FakeCloudAccountProvider(.available(recordName: "account-a"))
    let repository = FakeCloudCoordinatorRepository()
    let client = FakeCloudSyncClient()
    let factory = FakeCloudSyncClientFactory(clients: [client])
    let coordinator = CloudSyncCoordinator(
      preference: preference.store,
      accountProvider: account,
      accountMarkerStore: CloudAccountMarkerStore(secure: InMemorySecureTokenStore()),
      repository: repository,
      engineFactory: { try await factory.makeClient() },
      now: { coordinatorNow }
    )
    defer { preference.cleanUp() }

    await coordinator.start()

    #expect(preference.store.isEnabled)
    #expect(await factory.creationCount == 1)
    #expect(await client.operations == [.start])
    #expect(await repository.successDates == [coordinatorNow])
    #expect(await coordinator.status == .synchronized(date: coordinatorNow))
  }

  @Test func disablingKeepsLocalPendingWorkAndReenablingResumesIncrementally() async throws {
    let preference = try makeCloudPreferenceStore()
    let repository = FakeCloudCoordinatorRepository()
    await repository.setPendingCount(2)
    let client = FakeCloudSyncClient()
    let coordinator = CloudSyncCoordinator(
      preference: preference.store,
      accountProvider: FakeCloudAccountProvider(.available(recordName: "account-a")),
      accountMarkerStore: CloudAccountMarkerStore(secure: InMemorySecureTokenStore()),
      repository: repository,
      engineFactory: { client },
      now: { coordinatorNow }
    )
    defer { preference.cleanUp() }

    await coordinator.start()
    await coordinator.setEnabled(false)
    await repository.setPendingCount(3)

    #expect(!preference.store.isEnabled)
    #expect(await coordinator.status == .disabled)
    #expect(await repository.pendingCount == 3)
    #expect(await repository.resetCount == 0)

    await coordinator.setEnabled(true)

    #expect(preference.store.isEnabled)
    #expect(await client.operations == [.start, .pause, .start])
    #expect(await coordinator.status == .pending(count: 3))
  }

  @Test func losingTheICloudAccountPausesUploadsAndFallsBackToLocalMode() async throws {
    let preference = try makeCloudPreferenceStore()
    let account = FakeCloudAccountProvider(.available(recordName: "account-a"))
    let client = FakeCloudSyncClient()
    let coordinator = CloudSyncCoordinator(
      preference: preference.store,
      accountProvider: account,
      accountMarkerStore: CloudAccountMarkerStore(secure: InMemorySecureTokenStore()),
      repository: FakeCloudCoordinatorRepository(),
      engineFactory: { client },
      now: { coordinatorNow }
    )
    defer { preference.cleanUp() }

    await coordinator.start()
    await account.setAccount(.noAccount)
    await coordinator.requestSync()

    #expect(await client.operations == [.start, .pause])
    #expect(await coordinator.status == .unavailable)
  }

  @Test func rateLimitingBlocksEarlyRetriesAndAllowsSyncAfterTheBackoff() async throws {
    let preference = try makeCloudPreferenceStore()
    let clock = MutableCoordinatorClock(coordinatorNow)
    let client = FakeCloudSyncClient()
    await client.setStartError(
      CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60.0])
    )
    let coordinator = CloudSyncCoordinator(
      preference: preference.store,
      accountProvider: FakeCloudAccountProvider(.available(recordName: "account-a")),
      accountMarkerStore: CloudAccountMarkerStore(secure: InMemorySecureTokenStore()),
      repository: FakeCloudCoordinatorRepository(),
      engineFactory: { client },
      now: { clock.now }
    )
    defer { preference.cleanUp() }

    await coordinator.start()
    await client.setStartError(nil)
    await coordinator.requestSync()

    #expect(await client.operations == [.start])
    #expect(await coordinator.status == .failed(category: .rateLimited))

    clock.advance(by: 61)
    await coordinator.requestSync()

    #expect(await client.operations == [.start, .fetch, .send])
    #expect(await coordinator.status == .synchronized(date: clock.now))
  }

  @Test func switchingAccountsPausesUploadsUntilTheUserConfirmsASafeInitialMerge() async throws {
    let preference = try makeCloudPreferenceStore()
    let account = FakeCloudAccountProvider(.available(recordName: "account-a"))
    let secure = InMemorySecureTokenStore()
    let markerStore = CloudAccountMarkerStore(secure: secure)
    let repository = FakeCloudCoordinatorRepository()
    let oldClient = FakeCloudSyncClient()
    let newClient = FakeCloudSyncClient()
    let factory = FakeCloudSyncClientFactory(clients: [oldClient, newClient])
    let coordinator = CloudSyncCoordinator(
      preference: preference.store,
      accountProvider: account,
      accountMarkerStore: markerStore,
      repository: repository,
      engineFactory: { try await factory.makeClient() },
      now: { coordinatorNow }
    )
    defer { preference.cleanUp() }

    await coordinator.start()
    await account.setAccount(.available(recordName: "account-b"))
    await coordinator.requestSync()

    #expect(await oldClient.operations == [.start, .pause])
    #expect(await factory.creationCount == 1)
    #expect(await repository.resetCount == 0)
    #expect(await coordinator.status == .accountChangeRequiresConfirmation)

    await coordinator.confirmAccountChange()

    #expect(await oldClient.operations == [.start, .pause, .close])
    #expect(await newClient.operations == [.start])
    #expect(await factory.creationCount == 2)
    #expect(await repository.resetCount == 1)
    #expect(try markerStore.compareAndEstablish(recordName: "account-b") == .matches)
    #expect(await coordinator.status == .synchronized(date: coordinatorNow))
  }

  @Test func cancellingAnAccountChangeKeepsTheAppInPersistentLocalMode() async throws {
    let preference = try makeCloudPreferenceStore()
    let account = FakeCloudAccountProvider(.available(recordName: "account-a"))
    let markerStore = CloudAccountMarkerStore(secure: InMemorySecureTokenStore())
    let repository = FakeCloudCoordinatorRepository()
    let client = FakeCloudSyncClient()
    let coordinator = CloudSyncCoordinator(
      preference: preference.store,
      accountProvider: account,
      accountMarkerStore: markerStore,
      repository: repository,
      engineFactory: { client },
      now: { coordinatorNow }
    )
    defer { preference.cleanUp() }

    await coordinator.start()
    await account.setAccount(.available(recordName: "account-b"))
    await coordinator.requestSync()
    await coordinator.cancelAccountChange()
    await coordinator.requestSync()

    #expect(!preference.store.isEnabled)
    #expect(await coordinator.status == .disabled)
    #expect(await client.operations == [.start, .pause, .close])
    #expect(await repository.resetCount == 0)
    #expect(try markerStore.compareAndEstablish(recordName: "account-b") == .changed)
  }
}

private actor FakeCloudAccountSystemClient: CloudAccountSystemClient {
  let status: CKAccountStatus
  let recordID: CKRecord.ID

  init(status: CKAccountStatus, recordID: CKRecord.ID) {
    self.status = status
    self.recordID = recordID
  }

  func accountStatus() -> CKAccountStatus { status }
  func userRecordID() -> CKRecord.ID { recordID }
}

private actor FakeCloudAccountProvider: CloudAccountProviding {
  var account: CloudAccountAvailability

  init(_ account: CloudAccountAvailability) {
    self.account = account
  }

  func currentAccount() -> CloudAccountAvailability {
    account
  }

  func setAccount(_ account: CloudAccountAvailability) {
    self.account = account
  }
}

private actor FakeCloudCoordinatorRepository: CloudSyncCoordinatorRepository {
  var pendingCount = 0
  var conflictCount = 0
  var resetCount = 0
  var successDates: [Date] = []

  func pendingCloudChangeCount() -> Int { pendingCount }
  func cloudConflictCount() -> Int { conflictCount }
  func resetCloudStateForAccountChange() { resetCount += 1 }
  func markCloudSyncSucceeded(at date: Date) { successDates.append(date) }

  func setPendingCount(_ count: Int) {
    pendingCount = count
  }
}

private actor FakeCloudSyncClient: CloudSyncEngineClient {
  enum Operation: Equatable, Sendable {
    case start
    case pause
    case fetch
    case send
    case close
  }

  var operations: [Operation] = []
  var startError: Error?
  var fetchError: Error?
  var sendError: Error?

  func start() throws {
    operations.append(.start)
    if let startError { throw startError }
  }

  func pause() {
    operations.append(.pause)
  }

  func fetch() throws {
    operations.append(.fetch)
    if let fetchError { throw fetchError }
  }

  func send() throws {
    operations.append(.send)
    if let sendError { throw sendError }
  }

  func close() {
    operations.append(.close)
  }

  func setStartError(_ error: Error?) {
    startError = error
  }
}

private actor FakeCloudSyncClientFactory {
  var clients: [FakeCloudSyncClient]
  var creationCount = 0

  init(clients: [FakeCloudSyncClient]) {
    self.clients = clients
  }

  func makeClient() throws -> any CloudSyncEngineClient {
    guard !clients.isEmpty else { throw FakeCoordinatorError.noClient }
    creationCount += 1
    return clients.removeFirst()
  }
}

private struct CloudPreferenceFixture {
  let suiteName: String
  let preferences: UserDefaults
  let store: CloudSyncPreferenceStore

  func cleanUp() {
    preferences.removePersistentDomain(forName: suiteName)
  }
}

private enum FakeCoordinatorError: Error {
  case noClient
}

private final class MutableCoordinatorClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) {
    self.date = date
  }

  var now: Date {
    lock.withLock { date }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock { date = date.addingTimeInterval(interval) }
  }
}

private let coordinatorNow = Date(timeIntervalSince1970: 1_788_000_000)

private func makeCloudPreferenceStore() throws -> CloudPreferenceFixture {
  let suiteName = "cloud-sync-coordinator-\(UUID().uuidString)"
  let preferences = try #require(UserDefaults(suiteName: suiteName))
  return CloudPreferenceFixture(
    suiteName: suiteName,
    preferences: preferences,
    store: CloudSyncPreferenceStore(preferences: preferences)
  )
}
