import Foundation
import SwiftData
import Testing

@testable import BirthdayCore

@Suite struct SyncEngineTests {
  @Test func retryPolicyCapsAtSixHoursWithoutOverflow() {
    #expect(RetryPolicy.delay(attempt: 0) == 30)
    #expect(RetryPolicy.delay(attempt: 1) == 60)
    #expect(RetryPolicy.delay(attempt: 20) == 21_600)
    #expect(RetryPolicy.delay(attempt: .max) == 21_600)
  }

  @Test func pushBatcherUsesCompleteEncodedCompactRequestForCountAndEscapes() throws {
    let operations = try (0..<51).map { index in
      try makeOperation(message: "quote=\" slash=\\ control=\n\u{0001} #\(index)")
    }

    let batches = try PushBatcher.makeBatches(operations)

    #expect(batches.map(\.count) == [50, 1])
    for batch in batches {
      #expect(try MobileJSON.encoder.encode(PushRequest(operations: batch)).count <= 61_440)
    }
  }

  @Test func pushBatcherHonorsExact61440ByteBoundaryAndLargestLegalPayload() throws {
    let exact = try makeOperationsForExactRequestSize(61_440)
    #expect(
      try MobileJSON.encoder.encode(PushRequest(operations: try exact.map(PushOperationDTO.init)))
        .count == 61_440)
    #expect(try PushBatcher.makeBatches(exact).count == 1)

    let over = try makeOperationsForExactRequestSize(61_441)
    let batches = try PushBatcher.makeBatches(over)
    #expect(batches.count == 2)
    #expect(
      try batches.allSatisfy {
        try MobileJSON.encoder.encode(PushRequest(operations: $0)).count <= 61_440
      })

    let largest = try makeOperation(message: String(repeating: "m", count: 8_191), name: "n")
    let largestBatch = try #require(try PushBatcher.makeBatches([largest]).first)
    #expect(try MobileJSON.encoder.encode(PushRequest(operations: largestBatch)).count <= 61_440)
  }

  @Test func readyOperationsExcludeRetriesUntilClockAndTerminalPoison() async throws {
    let store = try makeSyncStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let record = try await store.save(
      BirthdayDraft(
        name: "甲",
        lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ),
      id: nil,
      now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let operation = try #require(try await store.readyOperations(limit: 1, now: now).first)

    try await store.recordRetry(
      operationIDs: [operation.operationId],
      category: .transport,
      now: now
    )
    #expect(try await store.readyOperations(limit: 1, now: now).isEmpty)
    #expect(try await store.readyOperations(limit: 1, now: now.addingTimeInterval(30)).count == 1)

    try await store.markOperationTerminal(operationID: operation.operationId)
    #expect(try await store.readyOperations(limit: 1, now: now.addingTimeInterval(30)).isEmpty)
    #expect(try await store.activeBirthdays().first?.id == record.id)
  }

  @Test func pushResultsRequireExactlyTheBatchAndPersistFullConflictSnapshots() async throws {
    let store = try makeSyncStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let record = try await store.save(
      BirthdayDraft(
        name: "本地生日",
        lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ),
      id: UUID(),
      now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let operation = try #require(try await store.readyOperations(limit: 1, now: now).first)
    let remote = makeAPIBirthday(id: record.id, name: "远端生日", version: 2)

    try await store.applyPushResults(
      [
        PushResult(
          operationId: operation.operationId, status: .conflict, record: nil, remote: remote)
      ],
      expectedOperationIDs: [operation.operationId],
      now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(try await store.readyOperations(limit: 10, now: now).isEmpty)
    let conflict = try #require(try await store.syncConflicts().first)
    #expect(conflict.entityId == record.id)
    #expect(conflict.operationId == operation.operationId)
    #expect(
      try MobileJSON.decoder.decode(APIBirthday.self, from: conflict.remoteSnapshotJSON) == remote)
    #expect(
      try MobileJSON.decoder.decode(APIBirthday.self, from: conflict.localSnapshotJSON).name
        == "本地生日")

    let secondStore = try makeSyncStore()
    _ = try await secondStore.save(
      BirthdayDraft(
        name: "严格关联",
        lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ),
      id: UUID(),
      now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let second = try #require(try await secondStore.readyOperations(limit: 1, now: now).first)
    await #expect(throws: BirthdayStoreError.pushResultsDoNotMatchBatch) {
      try await secondStore.applyPushResults(
        [], expectedOperationIDs: [second.operationId], now: now,
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    #expect(try await secondStore.readyOperations(limit: 1, now: now).count == 1)
  }

  @Test func pullPreservesPendingLocalSnapshotAsConflictThenCommitsCursor() async throws {
    let store = try makeSyncStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let record = try await store.save(
      BirthdayDraft(
        name: "本地优先",
        lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ),
      id: UUID(),
      now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let remote = makeAPIBirthday(id: record.id, name: "远端覆盖", version: 3)

    try await store.applyPull(
      PullResponse(
        changes: [PullChange(seq: 4, operation: .upsert, record: remote)], nextCursor: 4,
        hasMore: false
      ),
      now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(try await store.activeBirthdays().first?.name == "本地优先")
    #expect(try await store.syncCursor() == 4)
    #expect(try await store.syncConflicts().map(\.entityId) == [record.id])
    #expect(try await store.readyOperations(limit: 10, now: now).isEmpty)
  }

  @Test func syncDrainsEveryPushBatchBeforeItsFirstPull() async throws {
    let store = try makeSyncStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    for index in 0..<121 {
      _ = try await store.save(
        BirthdayDraft(
          name: "生日\(index)",
          lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
          reminder: .defaults
        ),
        id: UUID(),
        now: now,
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    let deviceID = UUID()
    let credentials = DeviceCredentialStore(secure: InMemorySecureTokenStore())
    try credentials.save(
      DeviceCredentials(
        deviceId: deviceID,
        accessToken: "access",
        accessExpiresAt: now.addingTimeInterval(600),
        refreshToken: "refresh",
        refreshExpiresAt: now.addingTimeInterval(15_552_000)
      ))
    let api = DrainingFakeAPI(deviceID: deviceID)
    let engine = SyncEngine(api: api, store: store, credentials: credentials, now: { now })

    let summary = try await engine.syncNow()
    let events = await api.events()

    #expect(summary.uploaded == 121)
    #expect(try await store.readyOperations(limit: 500, now: now).isEmpty)
    #expect(events.filter { $0 == .push }.count >= 3)
    #expect(try #require(events.lastIndex(of: .push)) < #require(events.firstIndex(of: .pull)))
  }

  @Test func accessExpiryRefreshesOnceReplaysAndPersistsTheRotatedBundle() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let deviceID = UUID()
    let credentials = DeviceCredentialStore(secure: InMemorySecureTokenStore())
    try credentials.save(
      DeviceCredentials(
        deviceId: deviceID,
        accessToken: "old-access",
        accessExpiresAt: now.addingTimeInterval(600),
        refreshToken: "old-refresh",
        refreshExpiresAt: now.addingTimeInterval(15_552_000)
      ))
    let api = RefreshingPullFakeAPI(deviceID: deviceID, expiresFirstPull: true)
    let engine = SyncEngine(
      api: api, store: try makeSyncStore(), credentials: credentials, now: { now })

    let summary = try await engine.syncNow()

    #expect(summary.cursor == 0)
    #expect(await api.refreshCount() == 1)
    #expect(try credentials.load()?.accessToken == "fresh-access")
    #expect(try credentials.load()?.refreshToken == "fresh-refresh")
  }

  @Test func appliedOldInFlightOperationKeepsMidFlightEditAsFreshOutboxOperation() async throws {
    let store = try makeSyncStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let original = try await store.save(
      BirthdayDraft(
        name: "发送前", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let sent = try #require(try await store.readyOperations(limit: 1, now: now).first)
    let sentDTO = try PushOperationDTO(sent)
    _ = try await store.save(
      BirthdayDraft(
        name: "发送中编辑", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: original.id, now: now.addingTimeInterval(1), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let server = makeAPIBirthday(id: original.id, name: "服务器旧值", version: 7)

    try await store.applyPushResults(
      [PushResult(operationId: sent.operationId, status: .applied, record: server, remote: nil)],
      expectedOperationIDs: [sent.operationId], expectedOperations: [sentDTO], now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    let replacement = try #require(try await store.readyOperations(limit: 1, now: now).first)
    #expect(replacement.operationId != sent.operationId)
    #expect(replacement.baseVersion == 7)
    #expect(try await store.activeBirthdays().first?.name == "发送中编辑")

    _ = try await store.save(
      BirthdayDraft(
        name: "响应后再编辑", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: original.id, now: now.addingTimeInterval(2), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    #expect(try await store.readyOperations(limit: 1, now: now).first?.baseVersion == 7)
  }

  @Test func pullRejectsNoProgressPageBeforeCursorOrRecordsMutate() async throws {
    let store = try makeSyncStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    await #expect(throws: BirthdayStoreError.invalidPullPage) {
      try await store.applyPull(
        PullResponse(changes: [], nextCursor: 0, hasMore: true), now: now,
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }

    #expect(try await store.syncCursor() == 0)
    #expect(try await store.activeBirthdays().isEmpty)
  }

  @Test func enginePullsEveryPageAndStopsAfterTerminalPage() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let credentials = try makeCredentials(now: now)
    let first = makeAPIBirthday(id: UUID(), name: "第一页", version: 1)
    let second = makeAPIBirthday(id: UUID(), name: "第二页", version: 1)
    let api = PagedPullAPI(
      pages: [
        PullResponse(
          changes: [PullChange(seq: 1, operation: .upsert, record: first)], nextCursor: 1,
          hasMore: true),
        PullResponse(
          changes: [PullChange(seq: 2, operation: .upsert, record: second)], nextCursor: 2,
          hasMore: false),
      ])
    let store = try makeSyncStore()
    let summary = try await SyncEngine(
      api: api, store: store, credentials: credentials, now: { now }
    )
    .syncNow()
    #expect(summary.downloaded == 2)
    #expect(summary.cursor == 2)
    #expect(await api.pulledCursors() == [0, 1])
    #expect(try await store.activeBirthdays().map(\.name).sorted() == ["第一页", "第二页"])
  }

  @Test func engineNoProgressPullFailsAfterOneRequest() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let credentials = try makeCredentials(now: now)
    let api = PagedPullAPI(pages: [PullResponse(changes: [], nextCursor: 0, hasMore: true)])
    await #expect(throws: BirthdayStoreError.invalidPullPage) {
      try await SyncEngine(
        api: api, store: try makeSyncStore(), credentials: credentials, now: { now }
      )
      .syncNow()
    }
    #expect(await api.pulledCursors() == [0])
  }

  @Test func pullAndPushCommitFailuresLeaveFreshStoreUnchanged() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let container = try makeSyncContainer()
    let failing = BirthdayStore(
      modelContainer: container,
      transactionCommitter: { _ in throw CommitFailure.expected }
    )
    let fresh = BirthdayStore(modelContainer: container)
    let remote = makeAPIBirthday(id: UUID(), name: "不应保存", version: 1)
    await #expect(throws: CommitFailure.expected) {
      try await failing.applyPull(
        PullResponse(
          changes: [PullChange(seq: 1, operation: .upsert, record: remote)], nextCursor: 1,
          hasMore: false), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    #expect(try await fresh.activeBirthdays().isEmpty)
    #expect(try await fresh.syncCursor() == 0)
    #expect(try await fresh.syncConflicts().isEmpty)
  }

  @Test func semanticPoisonBeforeGoodOperationBecomesTerminalThenEnginePulls() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let container = try makeSyncContainer()
    let context = ModelContext(container)
    let poisonID = UUID()
    let payload = BirthdayPayloadDTO(
      id: poisonID, name: "", lunarMonth: 8, lunarDay: 15, isLeapMonth: false,
      reminderTimeMinutes: 540, notifyDayBefore: true, notifySameDay: true, emailEnabled: false,
      emailAddress: "", emailMessage: ""
    )
    let poisonOperationID = UUID()
    context.insert(
      SyncOperationEntity(
        operationId: poisonOperationID, entityId: poisonID, operationType: "upsert", baseVersion: 0,
        payloadJSON: try MobileJSON.encoder.encode(payload), createdAt: now.addingTimeInterval(-1),
        attemptCount: 0, nextRetryAt: nil, lastErrorCategory: nil
      ))
    try context.save()
    let store = BirthdayStore(modelContainer: container)
    _ = try await store.save(
      BirthdayDraft(
        name: "好操作", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let credentials = try makeCredentials(now: now)
    let api = DrainingFakeAPI(deviceID: try #require(try credentials.load()?.deviceId))
    let summary = try await SyncEngine(
      api: api, store: store, credentials: credentials, now: { now }
    )
    .syncNow()
    let poison = try #require(
      try await store.pendingOperations().first { $0.operationId == poisonOperationID })
    #expect(poison.lastErrorCategory == "local_contract")
    #expect(summary.uploaded == 1)
    #expect(await api.events().last == .pull)
  }

  @Test func readyReadFailureStopsBeforeAnyPull() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let api = PagedPullAPI(pages: [])
    let store = BirthdayStore(
      modelContainer: try makeSyncContainer(),
      transactionCommitter: { context in try context.save() },
      operationReader: { _ in throw CommitFailure.expected }
    )
    await #expect(throws: CommitFailure.expected) {
      try await SyncEngine(
        api: api, store: store, credentials: try makeCredentials(now: now), now: { now }
      ).syncNow()
    }
    #expect(await api.pulledCursors().isEmpty)
  }

  private func makeOperationsForExactRequestSize(_ target: Int) throws -> [SyncOperation] {
    let fixed = try (0..<7).map { _ in
      try makeOperation(message: String(repeating: "m", count: 8_000))
    }
    let base = fixed + [try makeOperation(message: "")]
    let baseSize = try MobileJSON.encoder.encode(
      PushRequest(operations: try base.map(PushOperationDTO.init))
    ).count
    let final = try makeOperation(message: String(repeating: "x", count: target - baseSize))
    return fixed + [final]
  }

  private func makeOperation(message: String, name: String = "名字") throws -> SyncOperation {
    let entityID = UUID()
    let payload = BirthdayPayloadDTO(
      id: entityID,
      name: name,
      lunarMonth: 8,
      lunarDay: 15,
      isLeapMonth: false,
      reminderTimeMinutes: 540,
      notifyDayBefore: true,
      notifySameDay: true,
      emailEnabled: true,
      emailAddress: "birthday@example.com",
      emailMessage: message
    )
    return SyncOperation(
      operationId: UUID(),
      entityId: entityID,
      operationType: "upsert",
      baseVersion: 0,
      payloadJSON: try MobileJSON.encoder.encode(payload),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      attemptCount: 0,
      nextRetryAt: nil,
      lastErrorCategory: nil
    )
  }

  private func makeCredentials(now: Date) throws -> DeviceCredentialStore {
    let credentials = DeviceCredentialStore(secure: InMemorySecureTokenStore())
    try credentials.save(
      DeviceCredentials(
        deviceId: UUID(), accessToken: "access", accessExpiresAt: now.addingTimeInterval(600),
        refreshToken: "refresh", refreshExpiresAt: now.addingTimeInterval(15_552_000)
      ))
    return credentials
  }
}

private enum CommitFailure: Error, Equatable { case expected }

private actor PagedPullAPI: MobileAPI {
  private var pages: [PullResponse]
  private var cursors: [Int64] = []
  init(pages: [PullResponse]) { self.pages = pages }
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
    PushResponse(results: [])
  }
  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    cursors.append(cursor)
    return pages.removeFirst()
  }
  func revoke(deviceId: UUID, accessToken: String) async throws {}
  func devices(accessToken: String) async throws -> [MobileDevice] { [] }
  func pulledCursors() -> [Int64] { cursors }
}

private actor DrainingFakeAPI: MobileAPI {
  enum Event: Equatable { case push, pull }

  private let deviceID: UUID
  private var recordedEvents: [Event] = []

  init(deviceID: UUID) {
    self.deviceID = deviceID
  }

  func login(_ request: LoginRequest) async throws -> TokenResponse {
    throw MobileAPIError.invalidResponse
  }

  func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
    TokenResponse(
      deviceId: deviceID,
      accessToken: "fresh",
      accessExpiresAt: Date(timeIntervalSince1970: 1_700_000_900),
      refreshToken: "rotated",
      refreshExpiresAt: Date(timeIntervalSince1970: 1_715_552_000)
    )
  }

  func snapshot(accessToken: String) async throws -> SnapshotResponse {
    throw MobileAPIError.invalidResponse
  }

  func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse {
    recordedEvents.append(.push)
    return PushResponse(results: request.operations.map(makeAppliedResult))
  }

  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    recordedEvents.append(.pull)
    return PullResponse(changes: [], nextCursor: cursor, hasMore: false)
  }

  func revoke(deviceId: UUID, accessToken: String) async throws {}
  func devices(accessToken: String) async throws -> [MobileDevice] { [] }
  func events() -> [Event] { recordedEvents }

  private func makeAppliedResult(_ operation: PushOperationDTO) -> PushResult {
    let payload = operation.payload!
    return PushResult(
      operationId: operation.operationId,
      status: .applied,
      record: APIBirthday(
        id: payload.id,
        name: payload.name,
        lunarMonth: payload.lunarMonth,
        lunarDay: payload.lunarDay,
        isLeapMonth: payload.isLeapMonth,
        reminder: ReminderConfig(
          timeMinutes: payload.reminderTimeMinutes,
          notifyDayBefore: payload.notifyDayBefore,
          notifySameDay: payload.notifySameDay,
          emailEnabled: payload.emailEnabled,
          emailAddress: payload.emailAddress,
          emailMessage: payload.emailMessage
        ),
        nextSolarDate: nil,
        version: 1,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        deletedAt: nil
      ),
      remote: nil
    )
  }
}

private actor RefreshingPullFakeAPI: MobileAPI {
  private let deviceID: UUID
  private let expiresFirstPull: Bool
  private var pulls = 0
  private var refreshes = 0

  init(deviceID: UUID, expiresFirstPull: Bool) {
    self.deviceID = deviceID
    self.expiresFirstPull = expiresFirstPull
  }

  func login(_ request: LoginRequest) async throws -> TokenResponse {
    throw MobileAPIError.invalidResponse
  }
  func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
    refreshes += 1
    return TokenResponse(
      deviceId: deviceID,
      accessToken: "fresh-access",
      accessExpiresAt: Date(timeIntervalSince1970: 1_700_000_900),
      refreshToken: "fresh-refresh",
      refreshExpiresAt: Date(timeIntervalSince1970: 1_715_552_000)
    )
  }
  func snapshot(accessToken: String) async throws -> SnapshotResponse {
    throw MobileAPIError.invalidResponse
  }
  func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse {
    PushResponse(results: [])
  }
  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    pulls += 1
    if expiresFirstPull, pulls == 1 { throw MobileAPIError.accessExpired }
    return PullResponse(changes: [], nextCursor: cursor, hasMore: false)
  }
  func revoke(deviceId: UUID, accessToken: String) async throws {}
  func devices(accessToken: String) async throws -> [MobileDevice] { [] }
  func refreshCount() -> Int { refreshes }
}
