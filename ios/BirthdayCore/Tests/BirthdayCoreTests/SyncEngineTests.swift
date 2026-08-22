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

  @Test func syncDrainsEvery401OperationBeforeItsFirstPull() async throws {
    let store = try makeSyncStore()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    for index in 0..<401 {
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

    #expect(summary.uploaded == 401)
    #expect(try await store.readyOperations(limit: 500, now: now).isEmpty)
    #expect(events.filter { $0 == .push }.count >= 3)
    #expect(try #require(events.lastIndex(of: .push)) < #require(events.firstIndex(of: .pull)))
  }

  @Test func proactiveRefreshBelowSixtySecondsPersistsTheRotatedBundle() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let deviceID = UUID()
    let credentials = DeviceCredentialStore(secure: InMemorySecureTokenStore())
    try credentials.save(
      DeviceCredentials(
        deviceId: deviceID,
        accessToken: "old-access",
        accessExpiresAt: now.addingTimeInterval(59),
        refreshToken: "old-refresh",
        refreshExpiresAt: now.addingTimeInterval(15_552_000)
      ))
    let api = RefreshingPullFakeAPI(deviceID: deviceID, expiresFirstPull: false)
    let engine = SyncEngine(
      api: api, store: try makeSyncStore(), credentials: credentials, now: { now })

    let summary = try await engine.syncNow()

    #expect(summary.cursor == 0)
    #expect(await api.refreshCount() == 1)
    #expect(await api.pullCount() == 1)
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
        reminder: ReminderConfig(
          timeMinutes: 601, notifyDayBefore: false, notifySameDay: true, emailEnabled: true,
          emailAddress: "latest@example.com", emailMessage: "最新提醒")
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
    let latestPayload = try #require(try PushOperationDTO(replacement).payload)
    #expect(latestPayload.reminderTimeMinutes == 601)
    #expect(latestPayload.emailAddress == "latest@example.com")
    #expect(latestPayload.emailMessage == "最新提醒")

    _ = try await store.save(
      BirthdayDraft(
        name: "响应后再编辑", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: original.id, now: now.addingTimeInterval(2), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    #expect(try await store.readyOperations(limit: 1, now: now).first?.baseVersion == 7)
  }

  @Test func appliedInFlightUpsertKeepsAConcurrentDeleteAsFreshDeleteWithReturnedBaseVersion()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let container = try makeSyncContainer()
    let existing = makeAPIBirthday(id: UUID(), name: "已同步", version: 3)
    try insertSyncedBirthday(existing, into: container)
    let store = BirthdayStore(modelContainer: container)
    let record = try await store.save(
      BirthdayDraft(
        name: "先上传", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: existing.id, now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let sent = try #require(try await store.readyOperations(limit: 1, now: now).first)
    let sentDTO = try PushOperationDTO(sent)
    try await store.softDelete(id: record.id, now: now.addingTimeInterval(1))

    try await store.applyPushResults(
      [
        PushResult(
          operationId: sent.operationId, status: .applied,
          record: makeAPIBirthday(id: record.id, name: "先上传", version: 12), remote: nil)
      ], expectedOperationIDs: [sent.operationId], expectedOperations: [sentDTO], now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    let replacement = try #require(try await store.readyOperations(limit: 1, now: now).first)
    #expect(replacement.operationId != sent.operationId)
    #expect(replacement.operationType == "delete")
    #expect(replacement.baseVersion == 12)
    #expect(try PushOperationDTO(replacement).payload == nil)
    #expect(try await store.activeBirthdays().isEmpty)
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

  @Test func disabledEmailPersistedPoisonIsTerminalWhileTheNextGoodOperationStillUploads()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let container = try makeSyncContainer()
    let context = ModelContext(container)
    let poisonID = UUID()
    let poisonOperationID = UUID()
    let noncanonicalPayloadJSON = Data(
      """
      {"id":"\(poisonID.uuidString.lowercased())","name":"遗留坏数据","lunarMonth":8,"lunarDay":15,"isLeapMonth":false,"reminderTimeMinutes":540,"notifyDayBefore":true,"notifySameDay":true,"emailEnabled":false,"emailAddress":"left@example.com","emailMessage":"不应在线上传"}
      """.utf8)
    context.insert(
      SyncOperationEntity(
        operationId: poisonOperationID, entityId: poisonID, operationType: "upsert", baseVersion: 0,
        payloadJSON: noncanonicalPayloadJSON,
        createdAt: now.addingTimeInterval(-1), attemptCount: 0, nextRetryAt: nil,
        lastErrorCategory: nil
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
    ).syncNow()

    let poison = try #require(
      try await store.pendingOperations().first { $0.operationId == poisonOperationID })
    #expect(poison.lastErrorCategory == "local_contract")
    #expect(summary.uploaded == 1)
    #expect(await api.events().last == .pull)
  }

  @Test func noncanonicalPushRecordsRejectTheWholeBatchBeforeAnyMutation() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let badReminders = [
      ReminderConfig(
        timeMinutes: 540, notifyDayBefore: true, notifySameDay: true, emailEnabled: false,
        emailAddress: "disabled@example.com", emailMessage: "遗留正文"),
      ReminderConfig(
        timeMinutes: 540, notifyDayBefore: true, notifySameDay: true, emailEnabled: false,
        emailAddress: "", emailMessage: "墓碑正文"),
    ]

    for (index, reminder) in badReminders.enumerated() {
      let store = try makeSyncStore()
      let first = try await store.save(
        BirthdayDraft(
          name: "第一项", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
          reminder: .defaults
        ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
      )
      let second = try await store.save(
        BirthdayDraft(
          name: "第二项", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
          reminder: .defaults
        ), id: UUID(), now: now.addingTimeInterval(1), timeZone: TimeZone(secondsFromGMT: 0)!
      )
      let operations = try await store.readyOperations(limit: 2, now: now.addingTimeInterval(1))
      let firstOperation = try #require(operations.first { $0.entityId == first.id })
      let secondOperation = try #require(operations.first { $0.entityId == second.id })
      let invalidResult: PushResult
      if index == 0 {
        invalidResult = PushResult(
          operationId: secondOperation.operationId, status: .applied,
          record: makeAPIBirthday(
            id: second.id, name: "服务端坏 active", reminder: reminder, version: 2), remote: nil)
      } else {
        invalidResult = PushResult(
          operationId: secondOperation.operationId, status: .conflict, record: nil,
          remote: makeAPIBirthday(
            id: second.id, name: "服务端坏 tombstone", reminder: reminder, version: 2,
            deletedAt: now.addingTimeInterval(2)))
      }

      await #expect(throws: BirthdayStoreError.pushResultEntityMismatch) {
        try await store.applyPushResults(
          [
            PushResult(
              operationId: firstOperation.operationId, status: .applied,
              record: makeAPIBirthday(id: first.id, name: "本应不写", version: 2), remote: nil),
            invalidResult,
          ], expectedOperationIDs: [firstOperation.operationId, secondOperation.operationId],
          expectedOperations: [
            try PushOperationDTO(firstOperation), try PushOperationDTO(secondOperation),
          ],
          now: now, timeZone: TimeZone(secondsFromGMT: 0)!
        )
      }
      #expect(try await store.activeBirthdays().first { $0.id == first.id }?.name == "第一项")
      #expect(try await store.readyOperations(limit: 2, now: now).count == 2)
      #expect(try await store.syncConflicts().isEmpty)
    }
  }

  @Test func noncanonicalPullRecordsRejectTheWholePageBeforeCursorOrRowsMutate() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let badChanges = [
      PullChange(
        seq: 2, operation: .upsert,
        record: makeAPIBirthday(
          id: UUID(), name: "坏 active",
          reminder: ReminderConfig(
            timeMinutes: 540, notifyDayBefore: true, notifySameDay: true, emailEnabled: false,
            emailAddress: "disabled@example.com", emailMessage: "遗留正文"), version: 1)),
      PullChange(
        seq: 2, operation: .delete,
        record: makeAPIBirthday(
          id: UUID(), name: "坏 tombstone",
          reminder: ReminderConfig(
            timeMinutes: 540, notifyDayBefore: true, notifySameDay: true, emailEnabled: false,
            emailAddress: "", emailMessage: "墓碑正文"), version: 1,
          deletedAt: now.addingTimeInterval(1))),
    ]

    for badChange in badChanges {
      let store = try makeSyncStore()
      let valid = makeAPIBirthday(id: UUID(), name: "本应不写", version: 1)
      await #expect(throws: BirthdayStoreError.invalidPullPage) {
        try await store.applyPull(
          PullResponse(
            changes: [PullChange(seq: 1, operation: .upsert, record: valid), badChange],
            nextCursor: 2, hasMore: false), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
        )
      }
      #expect(try await store.syncCursor() == 0)
      #expect(try await store.activeBirthdays().isEmpty)
      #expect(try await store.syncConflicts().isEmpty)
    }
  }

  @Test func firstCreateDeletedInFlightAppliedAckRestoresAFreshDeleteOperation() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try makeSyncStore()
    let record = try await store.save(
      BirthdayDraft(
        name: "首次创建", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let sent = try #require(try await store.readyOperations(limit: 1, now: now).first)
    let sentDTO = try PushOperationDTO(sent)
    try await store.softDelete(id: record.id, now: now.addingTimeInterval(1))
    #expect(try await store.pendingOperations().isEmpty)

    try await store.applyPushResults(
      [
        PushResult(
          operationId: sent.operationId, status: .applied,
          record: makeAPIBirthday(id: record.id, name: "首次创建", version: 6), remote: nil)
      ], expectedOperationIDs: [sent.operationId], expectedOperations: [sentDTO], now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    let replacement = try #require(try await store.readyOperations(limit: 1, now: now).first)
    #expect(replacement.operationId != sent.operationId)
    #expect(replacement.operationType == "delete")
    #expect(replacement.baseVersion == 6)
    #expect(try PushOperationDTO(replacement).payload == nil)
    #expect(try await store.activeBirthdays().isEmpty)
  }

  @Test func firstCreateDeletedInFlightConflictPersistsSnapshotsAndBlocksFreshDelete() async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try makeSyncStore()
    let record = try await store.save(
      BirthdayDraft(
        name: "首次冲突", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let sent = try #require(try await store.readyOperations(limit: 1, now: now).first)
    let sentDTO = try PushOperationDTO(sent)
    try await store.softDelete(id: record.id, now: now.addingTimeInterval(1))
    let remote = makeAPIBirthday(id: record.id, name: "远端冲突", version: 6)

    try await store.applyPushResults(
      [PushResult(operationId: sent.operationId, status: .conflict, record: nil, remote: remote)],
      expectedOperationIDs: [sent.operationId], expectedOperations: [sentDTO], now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )

    let conflict = try #require(try await store.syncConflicts().first)
    let local = try MobileJSON.decoder.decode(APIBirthday.self, from: conflict.localSnapshotJSON)
    #expect(local.deletedAt != nil)
    #expect(
      try MobileJSON.decoder.decode(APIBirthday.self, from: conflict.remoteSnapshotJSON) == remote)
    let blocked = try #require(try await store.pendingOperations().first)
    #expect(blocked.operationId == conflict.operationId)
    #expect(blocked.operationType == "delete")
    #expect(blocked.baseVersion == 0)
    #expect(try await store.readyOperations(limit: 1, now: now).isEmpty)
  }

  @Test func missingPushOperationWithoutAMatchingDeletedFirstCreateStillFailsWithoutWrites()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try makeSyncStore()
    let sent = PushOperationDTO(
      operationId: UUID(), entityId: UUID(), type: .upsert, baseVersion: 0,
      payload: BirthdayPayloadDTO(
        id: UUID(), name: "错 ID", lunarMonth: 8, lunarDay: 15, isLeapMonth: false,
        reminderTimeMinutes: 540, notifyDayBefore: true, notifySameDay: true, emailEnabled: false,
        emailAddress: "", emailMessage: ""))

    await #expect(throws: BirthdayStoreError.pushResultsDoNotMatchBatch) {
      try await store.applyPushResults(
        [
          PushResult(
            operationId: sent.operationId, status: .applied,
            record: makeAPIBirthday(id: sent.entityId, name: "错误 ACK", version: 1), remote: nil)
        ], expectedOperationIDs: [sent.operationId], expectedOperations: [sent], now: now,
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    #expect(try await store.activeBirthdays().isEmpty)
    #expect(try await store.pendingOperations().isEmpty)
    #expect(try await store.syncConflicts().isEmpty)
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

  @Test func pushResultProtocolFailuresLeaveTheWholeBatchUntouched() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    for failure in PushResultFailure.allCases {
      let store = try makeSyncStore()
      let record = try await store.save(
        BirthdayDraft(
          name: "原始", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
          reminder: .defaults
        ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
      )
      let operation = try #require(try await store.readyOperations(limit: 1, now: now).first)
      let badResults = failure.results(for: operation, now: now)
      do {
        try await store.applyPushResults(
          badResults, expectedOperationIDs: [operation.operationId],
          expectedOperations: [try PushOperationDTO(operation)], now: now,
          timeZone: TimeZone(secondsFromGMT: 0)!
        )
        Issue.record("expected \(failure) to reject")
      } catch {}
      #expect(try await store.activeBirthdays().first?.id == record.id)
      #expect(
        try await store.readyOperations(limit: 1, now: now).first?.operationId
          == operation.operationId)
      #expect(try await store.syncConflicts().isEmpty)
    }
  }

  @Test func pushResultValidationRejectsSentTypeMismatchAndLateBadResultBeforeAnyBatchWrite()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try makeSyncStore()
    let first = try await store.save(
      BirthdayDraft(
        name: "第一项", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let second = try await store.save(
      BirthdayDraft(
        name: "第二项", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: UUID(), now: now.addingTimeInterval(1), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let operations = try await store.readyOperations(limit: 2, now: now.addingTimeInterval(1))
    let firstOperation = try #require(operations.first { $0.entityId == first.id })
    let secondOperation = try #require(operations.first { $0.entityId == second.id })
    let firstSent = try PushOperationDTO(firstOperation)
    let secondSent = try PushOperationDTO(secondOperation)

    await #expect(throws: BirthdayStoreError.pushResultEntityMismatch) {
      try await store.applyPushResults(
        [
          PushResult(
            operationId: firstOperation.operationId, status: .applied,
            record: makeAPIBirthday(id: first.id, name: "服务器第一项", version: 3), remote: nil),
          PushResult(
            operationId: secondOperation.operationId, status: .applied,
            record: makeAPIBirthday(id: UUID(), name: "错误第二项", version: 3), remote: nil),
        ], expectedOperationIDs: [firstOperation.operationId, secondOperation.operationId],
        expectedOperations: [firstSent, secondSent], now: now,
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    #expect(try await store.activeBirthdays().first { $0.id == first.id }?.name == "第一项")
    #expect(
      try await store.readyOperations(limit: 2, now: now).map(\.operationId).sorted {
        $0.uuidString < $1.uuidString
      }
        == [firstOperation.operationId, secondOperation.operationId].sorted {
          $0.uuidString < $1.uuidString
        })

    let mismatchedSent = PushOperationDTO(
      operationId: firstOperation.operationId, entityId: first.id, type: .delete,
      baseVersion: firstOperation.baseVersion, payload: nil)
    await #expect(throws: BirthdayStoreError.pushResultEntityMismatch) {
      try await store.applyPushResults(
        [
          PushResult(
            operationId: firstOperation.operationId, status: .applied,
            record: makeAPIBirthday(id: first.id, name: "服务器类型错", version: 4), remote: nil)
        ], expectedOperationIDs: [firstOperation.operationId], expectedOperations: [mismatchedSent],
        now: now, timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    #expect(try await store.activeBirthdays().first { $0.id == first.id }?.name == "第一项")
  }

  @Test func appliedDeleteTombstoneRemovesOutboxAndHidesBirthday() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let container = try makeSyncContainer()
    let remote = makeAPIBirthday(id: UUID(), name: "将删除", version: 3)
    try insertSyncedBirthday(remote, into: container)
    let store = BirthdayStore(modelContainer: container)
    try await store.softDelete(id: remote.id, now: now)
    let operation = try #require(try await store.readyOperations(limit: 1, now: now).first)
    let tombstone = makeAPIBirthday(
      id: remote.id, name: "将删除", version: 4, deletedAt: now.addingTimeInterval(1))
    try await store.applyPushResults(
      [
        PushResult(
          operationId: operation.operationId, status: .applied, record: tombstone, remote: nil)
      ],
      expectedOperationIDs: [operation.operationId],
      expectedOperations: [try PushOperationDTO(operation)],
      now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    #expect(try await store.activeBirthdays().isEmpty)
    #expect(try await store.pendingOperations().isEmpty)
  }

  @Test func pullDeleteTombstoneCommitsCursorAndHidesTheRemoteBirthday() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let container = try makeSyncContainer()
    let remote = makeAPIBirthday(id: UUID(), name: "远端删除", version: 3)
    try insertSyncedBirthday(remote, into: container)
    let store = BirthdayStore(modelContainer: container)
    let tombstone = makeAPIBirthday(
      id: remote.id, name: "远端删除", version: 4, deletedAt: now.addingTimeInterval(1))

    try await store.applyPull(
      PullResponse(
        changes: [PullChange(seq: 1, operation: .delete, record: tombstone)], nextCursor: 1,
        hasMore: false), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(try await store.activeBirthdays().isEmpty)
    #expect(try await store.syncCursor() == 1)
  }

  @Test func inFlightConflictPersistsSnapshotsAndBlocksWithoutRebase() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try makeSyncStore()
    let record = try await store.save(
      BirthdayDraft(
        name: "旧本地", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let sent = try #require(try await store.readyOperations(limit: 1, now: now).first)
    let sentDTO = try PushOperationDTO(sent)
    _ = try await store.save(
      BirthdayDraft(
        name: "新本地", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: record.id, now: now.addingTimeInterval(1), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let remote = makeAPIBirthday(id: record.id, name: "远端冲突", version: 9)
    try await store.applyPushResults(
      [PushResult(operationId: sent.operationId, status: .conflict, record: nil, remote: remote)],
      expectedOperationIDs: [sent.operationId], expectedOperations: [sentDTO], now: now,
      timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let conflict = try #require(try await store.syncConflicts().first)
    #expect(
      try MobileJSON.decoder.decode(APIBirthday.self, from: conflict.remoteSnapshotJSON) == remote)
    #expect(
      try MobileJSON.decoder.decode(APIBirthday.self, from: conflict.localSnapshotJSON).name
        == "新本地")
    #expect(try await store.readyOperations(limit: 1, now: now).isEmpty)
    #expect(try await store.pendingOperations().first?.baseVersion == 0)
  }

  @Test func malformedPullVariantsMakeZeroWrites() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let active = makeAPIBirthday(id: UUID(), name: "活动", version: 1)
    let deleted = makeAPIBirthday(id: UUID(), name: "墓碑", version: 1, deletedAt: now)
    let pages: [(name: String, page: PullResponse)] = [
      (
        "nonpositive sequence",
        PullResponse(
          changes: [PullChange(seq: 0, operation: .upsert, record: active)], nextCursor: 0,
          hasMore: false)
      ),
      (
        "reverse sequence",
        PullResponse(
          changes: [
            PullChange(seq: 2, operation: .upsert, record: active),
            PullChange(seq: 1, operation: .upsert, record: active),
          ], nextCursor: 1, hasMore: false)
      ),
      (
        "duplicate sequence",
        PullResponse(
          changes: [
            PullChange(seq: 1, operation: .upsert, record: active),
            PullChange(seq: 1, operation: .upsert, record: active),
          ], nextCursor: 1, hasMore: false)
      ),
      (
        "cursor not final sequence",
        PullResponse(
          changes: [PullChange(seq: 1, operation: .upsert, record: active)], nextCursor: 2,
          hasMore: false)
      ),
      ("empty has more", PullResponse(changes: [], nextCursor: 0, hasMore: true)),
      (
        "upsert tombstone",
        PullResponse(
          changes: [PullChange(seq: 1, operation: .upsert, record: deleted)], nextCursor: 1,
          hasMore: false)
      ),
      (
        "delete active",
        PullResponse(
          changes: [PullChange(seq: 1, operation: .delete, record: active)], nextCursor: 1,
          hasMore: false)
      ),
    ]
    for (_, page) in pages {
      let store = try makeSyncStore()
      await #expect(throws: BirthdayStoreError.invalidPullPage) {
        try await store.applyPull(page, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
      }
      #expect(try await store.syncCursor() == 0)
      #expect(try await store.activeBirthdays().isEmpty)
      #expect(try await store.syncConflicts().isEmpty)
    }
  }

  @Test func pullRejectsASequenceAtThePersistedCursorWithoutChangingThatPage() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try makeSyncStore()
    let committed = makeAPIBirthday(id: UUID(), name: "已提交", version: 1)
    try await store.applyPull(
      PullResponse(
        changes: [PullChange(seq: 1, operation: .upsert, record: committed)], nextCursor: 1,
        hasMore: false), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let rejected = makeAPIBirthday(id: UUID(), name: "越界", version: 1)

    await #expect(throws: BirthdayStoreError.invalidPullPage) {
      try await store.applyPull(
        PullResponse(
          changes: [PullChange(seq: 1, operation: .upsert, record: rejected)], nextCursor: 1,
          hasMore: false), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    #expect(try await store.syncCursor() == 1)
    #expect(try await store.activeBirthdays().map(\.id) == [committed.id])
  }

  @Test func sameNewIDEventsInOnePageLeaveTheLastState() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let id = UUID()
    let first = makeAPIBirthday(id: id, name: "第一次", version: 1)
    let tombstone = makeAPIBirthday(id: id, name: "删除", version: 2, deletedAt: now)
    let restored = makeAPIBirthday(id: id, name: "恢复", version: 3)
    let store = try makeSyncStore()
    try await store.applyPull(
      PullResponse(
        changes: [
          PullChange(seq: 1, operation: .upsert, record: first),
          PullChange(seq: 2, operation: .delete, record: tombstone),
          PullChange(seq: 3, operation: .upsert, record: restored),
        ], nextCursor: 3, hasMore: false), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    #expect(try await store.activeBirthdays().first?.name == "恢复")
    #expect(try await store.activeBirthdays().first?.version == 3)
  }

  @Test func authorizationRebindAndRefreshFailuresFollowTheirSpecificCategories() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let missing = DeviceCredentialStore(secure: InMemorySecureTokenStore())
    let missingAPI = AuthMatrixAPI(mode: .success)
    await #expect(throws: SyncError.rebindRequired) {
      try await SyncEngine(
        api: missingAPI, store: try makeSyncStore(), credentials: missing, now: { now }
      )
      .syncNow()
    }
    #expect(await missingAPI.pullCount() == 0)

    let expired = try makeCredentials(now: now)
    try expired.replaceAfterRefresh(
      DeviceCredentials(
        deviceId: try #require(try expired.load()?.deviceId), accessToken: "expired",
        accessExpiresAt: now, refreshToken: "expired", refreshExpiresAt: now
      ), expectedDeviceID: try #require(try expired.load()?.deviceId)
    )
    let expiredAPI = AuthMatrixAPI(mode: .success)
    await #expect(throws: SyncError.rebindRequired) {
      try await SyncEngine(
        api: expiredAPI, store: try makeSyncStore(), credentials: expired, now: { now }
      )
      .syncNow()
    }
    #expect(await expiredAPI.pullCount() == 0)

    for mode in [AuthMatrixAPI.Mode.refreshInvalid, .secondAccessExpired, .deviceMismatch] {
      let credentials = try makeCredentials(now: now)
      let deviceID = try #require(try credentials.load()?.deviceId)
      let api = AuthMatrixAPI(
        mode: mode, deviceID: mode == .deviceMismatch ? nil : deviceID)
      await #expect(throws: SyncError.rebindRequired) {
        _ = try await SyncEngine(
          api: api, store: try makeSyncStore(), credentials: credentials, now: { now }
        )
        .syncNow()
      }
      #expect(await api.refreshCount() == 1)
      #expect(await api.pullCount() == (mode == .secondAccessExpired ? 2 : 1))
    }

    for mode in [AuthMatrixAPI.Mode.refreshTransport, .refreshServer] {
      let credentials = try makeCredentials(now: now)
      do {
        let deviceID = try #require(try credentials.load()?.deviceId)
        _ = try await SyncEngine(
          api: AuthMatrixAPI(mode: mode, deviceID: deviceID), store: try makeSyncStore(),
          credentials: credentials, now: { now }
        )
        .syncNow()
        Issue.record("expected refresh error")
      } catch let error as MobileAPIError {
        switch mode {
        case .refreshTransport: #expect(error == .transport("safe"))
        case .refreshServer: #expect(error == .server(code: "safe", status: 503))
        default: Issue.record("unexpected mode")
        }
      }
    }
  }

  @Test func rotatedCredentialSaveFailurePropagatesAsLocalStorageFailure() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let secure = FailingRefreshSecureTokenStore()
    let credentials = DeviceCredentialStore(secure: secure)
    let deviceID = UUID()
    try credentials.save(
      DeviceCredentials(
        deviceId: deviceID, accessToken: "access", accessExpiresAt: now.addingTimeInterval(600),
        refreshToken: "refresh", refreshExpiresAt: now.addingTimeInterval(15_552_000)
      ))
    secure.failNextCredentialWrite()
    let api = RefreshingPullFakeAPI(deviceID: deviceID, expiresFirstPull: true)

    await #expect(throws: CommitFailure.expected) {
      try await SyncEngine(
        api: api, store: try makeSyncStore(), credentials: credentials, now: { now }
      ).syncNow()
    }
    #expect(await api.refreshCount() == 1)
    #expect(try credentials.load()?.accessToken == "access")
  }

  @Test func pushCommitFailureLeavesFreshBirthdayOutboxAndConflictsUnchanged() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let container = try makeSyncContainer()
    let seed = BirthdayStore(modelContainer: container)
    let record = try await seed.save(
      BirthdayDraft(
        name: "本地", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let operation = try #require(try await seed.readyOperations(limit: 1, now: now).first)
    let failing = BirthdayStore(
      modelContainer: container, transactionCommitter: { _ in throw CommitFailure.expected })
    await #expect(throws: CommitFailure.expected) {
      try await failing.applyPushResults(
        [
          PushResult(
            operationId: operation.operationId, status: .applied,
            record: makeAPIBirthday(id: record.id, name: "服务器", version: 2), remote: nil)
        ],
        expectedOperationIDs: [operation.operationId],
        expectedOperations: [try PushOperationDTO(operation)],
        now: now, timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    let fresh = BirthdayStore(modelContainer: container)
    #expect(try await fresh.activeBirthdays().first?.name == "本地")
    #expect(
      try await fresh.readyOperations(limit: 1, now: now).first?.operationId
        == operation.operationId)
    #expect(try await fresh.syncConflicts().isEmpty)
  }

  @Test func retryPersistenceFailurePreservesOriginalErrorCategory() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let container = try makeSyncContainer()
    let seed = BirthdayStore(modelContainer: container)
    _ = try await seed.save(
      BirthdayDraft(
        name: "重试", lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
      ), id: UUID(), now: now, timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let failing = BirthdayStore(
      modelContainer: container, transactionCommitter: { _ in throw CommitFailure.expected })
    await #expect(throws: SyncError.retryPersistenceFailed(originalCategory: .transport)) {
      try await SyncEngine(
        api: TransportPushAPI(), store: failing, credentials: try makeCredentials(now: now),
        now: { now }
      ).syncNow()
    }
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

private final class FailingRefreshSecureTokenStore: SecureTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var shouldFailCredentialWrite = false

  func save(_ data: Data, account: String) throws {
    try lock.withLock {
      if shouldFailCredentialWrite, account == "mobile-device-credentials" {
        shouldFailCredentialWrite = false
        throw CommitFailure.expected
      }
      values[account] = data
    }
  }

  func read(account: String) throws -> Data? {
    lock.withLock { values[account] }
  }

  func delete(account: String) throws {
    _ = lock.withLock { values.removeValue(forKey: account) }
  }

  func failNextCredentialWrite() {
    lock.withLock { shouldFailCredentialWrite = true }
  }
}

private enum PushResultFailure: CaseIterable {
  case duplicate, unknown, missing, entityMismatch, conflictRemoteEntityMismatch, tombstoneMismatch

  func results(for operation: SyncOperation, now: Date) -> [PushResult] {
    let active = makeAPIBirthday(id: operation.entityId, name: "服务器", version: 1)
    switch self {
    case .duplicate:
      let result = PushResult(
        operationId: operation.operationId, status: .applied, record: active, remote: nil)
      return [result, result]
    case .unknown:
      return [PushResult(operationId: UUID(), status: .applied, record: active, remote: nil)]
    case .missing:
      return []
    case .entityMismatch:
      return [
        PushResult(
          operationId: operation.operationId, status: .applied,
          record: makeAPIBirthday(id: UUID(), name: "错实体", version: 1), remote: nil)
      ]
    case .conflictRemoteEntityMismatch:
      return [
        PushResult(
          operationId: operation.operationId, status: .conflict, record: nil,
          remote: makeAPIBirthday(id: UUID(), name: "错冲突实体", version: 1))
      ]
    case .tombstoneMismatch:
      return [
        PushResult(
          operationId: operation.operationId, status: .applied,
          record: makeAPIBirthday(id: operation.entityId, name: "错墓碑", version: 1, deletedAt: now),
          remote: nil)
      ]
    }
  }
}

private actor AuthMatrixAPI: MobileAPI {
  enum Mode {
    case success, refreshInvalid, secondAccessExpired, deviceMismatch, refreshTransport,
      refreshServer
  }
  private let mode: Mode
  private let responseDeviceID: UUID
  private var pullCalls = 0
  private var refreshCalls = 0

  init(mode: Mode, deviceID: UUID? = nil) {
    self.mode = mode
    responseDeviceID = deviceID ?? UUID()
  }
  func login(_ request: LoginRequest) async throws -> TokenResponse {
    throw MobileAPIError.invalidResponse
  }
  func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
    refreshCalls += 1
    switch mode {
    case .refreshInvalid: throw MobileAPIError.refreshInvalid
    case .refreshTransport: throw MobileAPIError.transport("safe")
    case .refreshServer: throw MobileAPIError.server(code: "safe", status: 503)
    case .deviceMismatch:
      return TokenResponse(
        deviceId: responseDeviceID, accessToken: "a", accessExpiresAt: .distantFuture,
        refreshToken: "r", refreshExpiresAt: .distantFuture)
    default:
      return TokenResponse(
        deviceId: responseDeviceID, accessToken: "a", accessExpiresAt: .distantFuture,
        refreshToken: "r", refreshExpiresAt: .distantFuture)
    }
  }
  func snapshot(accessToken: String) async throws -> SnapshotResponse {
    throw MobileAPIError.invalidResponse
  }
  func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse {
    PushResponse(results: [])
  }
  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    pullCalls += 1
    switch mode {
    case .success: return PullResponse(changes: [], nextCursor: cursor, hasMore: false)
    case .secondAccessExpired: throw MobileAPIError.accessExpired
    default:
      if pullCalls == 1 { throw MobileAPIError.accessExpired }
      return PullResponse(changes: [], nextCursor: cursor, hasMore: false)
    }
  }
  func revoke(deviceId: UUID, accessToken: String) async throws {}
  func devices(accessToken: String) async throws -> [MobileDevice] { [] }
  func refreshCount() -> Int { refreshCalls }
  func pullCount() -> Int { pullCalls }
}

private actor TransportPushAPI: MobileAPI {
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
    throw MobileAPIError.transport("safe")
  }
  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    PullResponse(changes: [], nextCursor: cursor, hasMore: false)
  }
  func revoke(deviceId: UUID, accessToken: String) async throws {}
  func devices(accessToken: String) async throws -> [MobileDevice] { [] }
}

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
  func pullCount() -> Int { pulls }
}
