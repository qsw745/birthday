import Foundation
import Testing

@testable import BirthdayCore

private let birthdayID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let operationID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let secondOperationID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

private let activeBirthdayJSON =
  #"{"id":"11111111-1111-4111-8111-111111111111","name":"妈妈","lunarMonth":8,"lunarDay":15,"isLeapMonth":false,"reminderTimeMinutes":540,"notifyDayBefore":true,"notifySameDay":true,"emailEnabled":true,"emailAddress":"mom@example.com","emailMessage":"生日快乐","nextSolarDate":"2026-09-25T01:00:00.000Z","version":"3","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-08-22T04:00:00.000Z","deletedAt":null}"#

private let tombstoneBirthdayJSON =
  #"{"id":"11111111-1111-4111-8111-111111111111","name":"妈妈","lunarMonth":8,"lunarDay":15,"isLeapMonth":false,"reminderTimeMinutes":540,"notifyDayBefore":true,"notifySameDay":true,"emailEnabled":false,"emailAddress":"","emailMessage":"","nextSolarDate":"2026-09-25T01:00:00.000Z","version":"4","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-08-22T05:00:00.000Z","deletedAt":"2026-08-22T05:00:00.000Z"}"#

private struct DateBox: Codable, Equatable {
  let value: Date
}

@Suite struct MobileSyncDTOTests {
  @Test func decodesSnapshotWithStringCursorAndCompleteBirthday() throws {
    let json = #"{"cursor":"41","birthdays":["# + activeBirthdayJSON + "]}"

    let snapshot = try MobileJSON.decoder.decode(
      SnapshotResponse.self,
      from: Data(json.utf8)
    )

    #expect(snapshot.birthdays.count == 1)
    let birthday = try #require(snapshot.birthdays.first)
    #expect(snapshot.cursor == 41)
    #expect(birthday.id == birthdayID)
    #expect(birthday.name == "妈妈")
    #expect(birthday.lunarMonth == 8)
    #expect(birthday.lunarDay == 15)
    #expect(birthday.isLeapMonth == false)
    #expect(birthday.reminder.timeMinutes == 540)
    #expect(birthday.reminder.notifyDayBefore)
    #expect(birthday.reminder.notifySameDay)
    #expect(birthday.reminder.emailEnabled)
    #expect(birthday.reminder.emailAddress == "mom@example.com")
    #expect(birthday.reminder.emailMessage == "生日快乐")
    #expect(birthday.nextSolarDate != nil)
    #expect(birthday.version == 3)
    #expect(birthday.deletedAt == nil)
  }

  @Test func decimalInt64UsesCanonicalQuotedSignedRange() throws {
    let maximum = try MobileJSON.decoder.decode(
      DecimalInt64.self,
      from: Data(#""9223372036854775807""#.utf8)
    )
    #expect(maximum.value == Int64.max)

    let encoded = try MobileJSON.encoder.encode(DecimalInt64(Int64.max))
    #expect(String(decoding: encoded, as: UTF8.self) == #""9223372036854775807""#)

    for invalid in [
      #""9223372036854775808""#,
      #""-1""#,
      #""+1""#,
      #""01""#,
      #""""#,
      #"" 1""#,
      #""1 ""#,
      "1",
    ] {
      #expect(throws: DecodingError.self) {
        try MobileJSON.decoder.decode(DecimalInt64.self, from: Data(invalid.utf8))
      }
    }

    #expect(
      try MobileJSON.decoder.decode(
        DecimalInt64.self,
        from: Data(#""0""#.utf8)
      ).value == 0
    )
  }

  @Test func everyVersionAndCursorFieldUsesQuotedDecimalInt64() throws {
    let snapshot = SnapshotResponse(cursor: Int64.max, birthdays: [])
    let pull = PullResponse(
      changes: [
        PullChange(
          seq: Int64.max,
          operation: .delete,
          record: try makeDTOAPIBirthday(
            version: Int64.max, deletedAt: Date(timeIntervalSince1970: 100))
        )
      ],
      nextCursor: Int64.max,
      hasMore: false
    )
    let push = PushRequest(
      operations: [
        PushOperationDTO(
          operationId: operationID,
          entityId: birthdayID,
          type: .delete,
          baseVersion: Int64.max,
          payload: nil
        )
      ]
    )

    let snapshotObject = try jsonObject(snapshot)
    let pullObject = try jsonObject(pull)
    let pushObject = try jsonObject(push)

    #expect(snapshotObject["cursor"] as? String == "9223372036854775807")
    let changes = try #require(pullObject["changes"] as? [[String: Any]])
    #expect(changes.first?["seq"] as? String == "9223372036854775807")
    let pullRecord = try #require(changes.first?["record"] as? [String: Any])
    #expect(pullRecord["version"] as? String == "9223372036854775807")
    #expect(pullObject["nextCursor"] as? String == "9223372036854775807")
    let operations = try #require(pushObject["operations"] as? [[String: Any]])
    #expect(operations.first?["baseVersion"] as? String == "9223372036854775807")
  }

  @Test func decodesOnlyAnchoredRealRFC3339Instants() throws {
    let valid = [
      "2026-08-22T00:15:00Z",
      "2026-08-22T00:15:00.1Z",
      "2026-08-22T00:15:00.123456789Z",
      "2026-08-22T08:15:00+08:00",
      "2026-08-21T16:15:00-08:00",
      "2024-02-29T23:59:59.999+23:59",
    ]

    for value in valid {
      let decoded = try MobileJSON.decoder.decode(
        DateBox.self,
        from: Data(#"{"value":"\#(value)"}"#.utf8)
      )
      #expect(decoded.value.timeIntervalSinceReferenceDate.isFinite)
    }

    let offset = try MobileJSON.decoder.decode(
      DateBox.self,
      from: Data(#"{"value":"2026-08-22T08:15:00+08:00"}"#.utf8)
    )
    let utc = try MobileJSON.decoder.decode(
      DateBox.self,
      from: Data(#"{"value":"2026-08-22T00:15:00Z"}"#.utf8)
    )
    #expect(offset == utc)
  }

  @Test func rejectsMalformedOrImpossibleRFC3339Instants() {
    let invalid = [
      " 2026-08-22T00:15:00Z",
      "2026-08-22T00:15:00Z ",
      "2026-08-22 00:15:00Z",
      "20260822T001500Z",
      "2026-W34-6T00:15:00Z",
      "2026-234T00:15:00Z",
      "2026-08-22T00:15:00",
      "2026-08-22T00:15:00+0800",
      "2026-08-22T00:15:00z",
      "2026-08-22T00:15:00.Z",
      "2026-08-22T24:00:00Z",
      "2026-08-22T00:15:60Z",
      "2026-02-29T00:00:00Z",
      "2026-13-01T00:00:00Z",
      "2026-04-31T00:00:00Z",
      "2026-08-22T00:15:00+24:00",
      "2026-08-22T00:15:00+08:60",
    ]

    for value in invalid {
      #expect(throws: DecodingError.self) {
        try MobileJSON.decoder.decode(
          DateBox.self,
          from: Data(#"{"value":"\#(value)"}"#.utf8)
        )
      }
    }
  }

  @Test func dateEncoderProducesFractionalUTCServerShape() throws {
    let encoded = try MobileJSON.encoder.encode(
      DateBox(value: Date(timeIntervalSince1970: 1_777_000_000)))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
    let value = try #require(object["value"])

    #expect(value.hasSuffix("Z"))
    #expect(value.contains("."))
    #expect(!value.contains("+00:00"))
    _ = try MobileJSON.decoder.decode(DateBox.self, from: encoded)
  }

  @Test func decodesTokenAndMobileDeviceProductionFields() throws {
    let tokenJSON =
      #"{"deviceId":"11111111-1111-4111-8111-111111111111","accessToken":"opaque-access-token","accessExpiresAt":"2026-08-22T00:15:00.000Z","refreshToken":"opaque-refresh-token","refreshExpiresAt":"2027-02-18T00:00:00.000Z"}"#
    let deviceJSON =
      #"{"deviceId":"11111111-1111-4111-8111-111111111111","deviceName":"QSW 的 iPhone","createdAt":"2026-08-22T00:00:00.000Z","lastUsedAt":null,"revokedAt":null}"#

    let token = try MobileJSON.decoder.decode(TokenResponse.self, from: Data(tokenJSON.utf8))
    let device = try MobileJSON.decoder.decode(MobileDevice.self, from: Data(deviceJSON.utf8))

    #expect(token.deviceId == birthdayID)
    #expect(token.accessToken == "opaque-access-token")
    #expect(token.refreshToken == "opaque-refresh-token")
    #expect(token.accessExpiresAt < token.refreshExpiresAt)
    #expect(device.deviceId == birthdayID)
    #expect(device.deviceName == "QSW 的 iPhone")
    #expect(device.lastUsedAt == nil)
    #expect(device.revokedAt == nil)
  }

  @Test func apiBirthdayRequiresNullableKeysAndAlwaysEncodesExplicitNulls() throws {
    for missingKey in ["nextSolarDate", "deletedAt"] {
      #expect(throws: DecodingError.self) {
        try MobileJSON.decoder.decode(
          APIBirthday.self,
          from: try removingKey(missingKey, from: activeBirthdayJSON)
        )
      }
    }

    let decoded = try MobileJSON.decoder.decode(
      APIBirthday.self,
      from: Data(
        activeBirthdayJSON.replacingOccurrences(
          of: #""nextSolarDate":"2026-09-25T01:00:00.000Z""#,
          with: #""nextSolarDate":null"#
        ).utf8)
    )
    let encoded = try jsonObject(decoded)

    #expect(decoded.nextSolarDate == nil)
    #expect(decoded.deletedAt == nil)
    #expect(encoded["nextSolarDate"] is NSNull)
    #expect(encoded["deletedAt"] is NSNull)
  }

  @Test func mobileDeviceRequiresNullableKeysAndAlwaysEncodesExplicitNulls() throws {
    let json =
      #"{"deviceId":"11111111-1111-4111-8111-111111111111","deviceName":"QSW 的 iPhone","createdAt":"2026-08-22T00:00:00.000Z","lastUsedAt":null,"revokedAt":null}"#

    for missingKey in ["lastUsedAt", "revokedAt"] {
      #expect(throws: DecodingError.self) {
        try MobileJSON.decoder.decode(
          MobileDevice.self,
          from: try removingKey(missingKey, from: json)
        )
      }
    }

    let decoded = try MobileJSON.decoder.decode(MobileDevice.self, from: Data(json.utf8))
    let encoded = try jsonObject(decoded)

    #expect(decoded.lastUsedAt == nil)
    #expect(decoded.revokedAt == nil)
    #expect(encoded["lastUsedAt"] is NSNull)
    #expect(encoded["revokedAt"] is NSNull)
  }

  @Test func requestDTOsEncodeExactProductionFieldNames() throws {
    let login = LoginRequest(
      username: "admin",
      password: "secret",
      deviceId: birthdayID,
      deviceName: "QSW 的 iPhone"
    )
    let refresh = RefreshRequest(refreshToken: "opaque-refresh-token")

    let loginObject = try jsonObject(login)
    let refreshObject = try jsonObject(refresh)

    #expect(Set(loginObject.keys) == ["username", "password", "deviceId", "deviceName"])
    #expect(loginObject["deviceId"] as? String == birthdayID.uuidString.lowercased())
    #expect(Set(refreshObject.keys) == ["refreshToken"])
  }

  @Test func decodesAppliedAndConflictPushResults() throws {
    let json =
      #"{"results":[{"operationId":"33333333-3333-4333-8333-333333333333","status":"applied","record":"#
      + activeBirthdayJSON
      + #"},{"operationId":"44444444-4444-4444-8444-444444444444","status":"conflict","remote":"#
      + tombstoneBirthdayJSON
      + "}]}"

    let response = try MobileJSON.decoder.decode(PushResponse.self, from: Data(json.utf8))

    #expect(response.results.count == 2)
    #expect(response.results[0].operationId == operationID)
    #expect(response.results[0].status == .applied)
    #expect(response.results[0].record?.version == 3)
    #expect(response.results[0].remote == nil)
    #expect(response.results[1].operationId == secondOperationID)
    #expect(response.results[1].status == .conflict)
    #expect(response.results[1].record == nil)
    #expect(response.results[1].remote?.deletedAt != nil)
  }

  @Test func pushResultRoundTripsOnlyItsActivePayloadAndAcceptsUnknownOuterFields() throws {
    let appliedJSON =
      #"{"operationId":"33333333-3333-4333-8333-333333333333","status":"applied","record":"#
      + activeBirthdayJSON
      + #", "futureField":true}"#
    let conflictJSON =
      #"{"operationId":"44444444-4444-4444-8444-444444444444","status":"conflict","remote":"#
      + tombstoneBirthdayJSON
      + "}"

    let applied = try MobileJSON.decoder.decode(PushResult.self, from: Data(appliedJSON.utf8))
    let conflict = try MobileJSON.decoder.decode(PushResult.self, from: Data(conflictJSON.utf8))
    let appliedObject = try jsonObject(applied)
    let conflictObject = try jsonObject(conflict)

    #expect(applied.status == .applied)
    #expect(applied.record != nil)
    #expect(applied.remote == nil)
    #expect(Set(appliedObject.keys) == ["operationId", "status", "record"])
    #expect(conflict.status == .conflict)
    #expect(conflict.record == nil)
    #expect(conflict.remote != nil)
    #expect(Set(conflictObject.keys) == ["operationId", "status", "remote"])
  }

  @Test func pushResultRejectsMissingNullBothAndWrongSidePayloads() throws {
    let active = try #require(
      JSONSerialization.jsonObject(with: Data(activeBirthdayJSON.utf8)) as? [String: Any]
    )
    let tombstone = try #require(
      JSONSerialization.jsonObject(with: Data(tombstoneBirthdayJSON.utf8)) as? [String: Any]
    )
    let base: [String: Any] = [
      "operationId": operationID.uuidString.lowercased()
    ]
    let invalid: [[String: Any]] = [
      base.merging(["status": "applied"]) { _, new in new },
      base.merging(["status": "applied", "record": NSNull()]) { _, new in new },
      base.merging(["status": "applied", "record": active, "remote": NSNull()]) { _, new in new },
      base.merging(["status": "applied", "record": active, "remote": tombstone]) { _, new in new },
      base.merging(["status": "applied", "remote": tombstone]) { _, new in new },
      base.merging(["status": "conflict"]) { _, new in new },
      base.merging(["status": "conflict", "remote": NSNull()]) { _, new in new },
      base.merging(["status": "conflict", "remote": tombstone, "record": NSNull()]) { _, new in new
      },
      base.merging(["status": "conflict", "remote": tombstone, "record": active]) { _, new in new },
      base.merging(["status": "conflict", "record": active]) { _, new in new },
    ]

    for object in invalid {
      let data = try JSONSerialization.data(withJSONObject: object)
      #expect(throws: DecodingError.self) {
        try MobileJSON.decoder.decode(PushResult.self, from: data)
      }
    }
  }

  @Test func decodesPullPageWithCompleteTombstoneSnapshot() throws {
    let json =
      #"{"changes":[{"seq":"42","operation":"delete","record":"#
      + tombstoneBirthdayJSON
      + #"}],"nextCursor":"42","hasMore":false}"#

    let response = try MobileJSON.decoder.decode(PullResponse.self, from: Data(json.utf8))
    #expect(response.changes.count == 1)
    let change = try #require(response.changes.first)

    #expect(change.seq == 42)
    #expect(change.operation == .delete)
    #expect(change.record.id == birthdayID)
    #expect(change.record.version == 4)
    #expect(change.record.deletedAt != nil)
    #expect(response.nextCursor == 42)
    #expect(response.hasMore == false)
  }

  @Test func convertsLocalUpsertAndDeleteOperations() throws {
    let record = try makeRecord(emailEnabled: true)
    let outbox = BirthdayOutboxPayload(record: record)
    let upsert = SyncOperation(
      operationId: operationID,
      entityId: record.id,
      operationType: "upsert",
      baseVersion: 7,
      payloadJSON: try MobileJSON.encoder.encode(outbox),
      createdAt: record.updatedAt,
      attemptCount: 0,
      nextRetryAt: nil,
      lastErrorCategory: nil
    )
    let delete = SyncOperation(
      operationId: secondOperationID,
      entityId: record.id,
      operationType: "delete",
      baseVersion: 8,
      payloadJSON: Data("not-json".utf8),
      createdAt: record.updatedAt,
      attemptCount: 0,
      nextRetryAt: nil,
      lastErrorCategory: nil
    )

    let upsertDTO = try PushOperationDTO(upsert)
    let deleteDTO = try PushOperationDTO(delete)

    #expect(upsertDTO.operationId == operationID)
    #expect(upsertDTO.entityId == record.id)
    #expect(upsertDTO.type == .upsert)
    #expect(upsertDTO.baseVersion == 7)
    #expect(upsertDTO.payload == BirthdayPayloadDTO(record: record))
    #expect(deleteDTO.type == .delete)
    #expect(deleteDTO.baseVersion == 8)
    #expect(deleteDTO.payload == nil)
  }

  @Test func rejectsInvalidLocalUpsertPayloadAndOperationKind() throws {
    let record = try makeRecord(emailEnabled: true)
    let invalidPayload = SyncOperation(
      operationId: operationID,
      entityId: record.id,
      operationType: "upsert",
      baseVersion: 0,
      payloadJSON: Data(#"{"id":"not-a-uuid"}"#.utf8),
      createdAt: record.updatedAt,
      attemptCount: 0,
      nextRetryAt: nil,
      lastErrorCategory: nil
    )
    let invalidKind = SyncOperation(
      operationId: operationID,
      entityId: record.id,
      operationType: "merge",
      baseVersion: 0,
      payloadJSON: Data(),
      createdAt: record.updatedAt,
      attemptCount: 0,
      nextRetryAt: nil,
      lastErrorCategory: nil
    )

    #expect(throws: Error.self) { try PushOperationDTO(invalidPayload) }
    #expect(throws: Error.self) { try PushOperationDTO(invalidKind) }
  }

  @Test func payloadAndAPIBirthdayRecordMappingsCopyEveryField() throws {
    let record = try makeRecord(emailEnabled: true)

    let payload = BirthdayPayloadDTO(record: record)
    let api = try makeDTOAPIBirthday(
      id: record.id,
      name: record.name,
      lunarMonth: record.lunarBirthday.month,
      lunarDay: record.lunarBirthday.day,
      isLeapMonth: record.lunarBirthday.isLeapMonth,
      reminder: record.reminder,
      nextSolarDate: record.nextSolarDate,
      version: record.version,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      deletedAt: record.deletedAt
    )
    let roundTrip = api.asRecord(syncState: .conflict)

    #expect(payload.id == record.id)
    #expect(payload.name == record.name)
    #expect(payload.lunarMonth == record.lunarBirthday.month)
    #expect(payload.lunarDay == record.lunarBirthday.day)
    #expect(payload.isLeapMonth == record.lunarBirthday.isLeapMonth)
    #expect(payload.reminderTimeMinutes == record.reminder.timeMinutes)
    #expect(payload.notifyDayBefore == record.reminder.notifyDayBefore)
    #expect(payload.notifySameDay == record.reminder.notifySameDay)
    #expect(payload.emailEnabled == record.reminder.emailEnabled)
    #expect(payload.emailAddress == record.reminder.emailAddress)
    #expect(payload.emailMessage == record.reminder.emailMessage)
    #expect(
      roundTrip
        == BirthdayRecord(
          id: record.id,
          name: record.name,
          lunarBirthday: record.lunarBirthday,
          reminder: record.reminder,
          nextSolarDate: record.nextSolarDate,
          version: record.version,
          createdAt: record.createdAt,
          updatedAt: record.updatedAt,
          deletedAt: record.deletedAt,
          syncState: .conflict
        ))
  }

  @Test func rejectsMalformedUUIDAndJSONTypeMismatches() {
    let malformedUUID =
      #"{"deviceId":"00000000-0000-0000-0000-000000000000","accessToken":"a","accessExpiresAt":"2026-08-22T00:15:00Z","refreshToken":"r","refreshExpiresAt":"2027-02-18T00:00:00Z"}"#
    let wrongType =
      #"{"cursor":"1","birthdays":[{"id":"11111111-1111-4111-8111-111111111111","name":"妈妈","lunarMonth":"8","lunarDay":15,"isLeapMonth":false,"reminderTimeMinutes":540,"notifyDayBefore":true,"notifySameDay":true,"emailEnabled":false,"emailAddress":"","emailMessage":"","nextSolarDate":null,"version":"1","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-08-22T04:00:00Z","deletedAt":null}]}"#

    #expect(throws: DecodingError.self) {
      try MobileJSON.decoder.decode(TokenResponse.self, from: Data(malformedUUID.utf8))
    }
    #expect(throws: DecodingError.self) {
      try MobileJSON.decoder.decode(SnapshotResponse.self, from: Data(wrongType.utf8))
    }
  }

  @Test func encoderRemainsCompactForByteAccuratePushBatching() throws {
    let request = PushRequest(
      operations: [
        PushOperationDTO(
          operationId: operationID,
          entityId: birthdayID,
          type: .delete,
          baseVersion: 3,
          payload: nil
        )
      ]
    )

    let encoded = try MobileJSON.encoder.encode(request)
    let string = String(decoding: encoded, as: UTF8.self)

    #expect(!string.contains("\n"))
    #expect(!string.contains("  "))
  }
}

private func makeRecord(emailEnabled: Bool) throws -> BirthdayRecord {
  BirthdayRecord(
    id: birthdayID,
    name: "妈妈",
    lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: true),
    reminder: ReminderConfig(
      timeMinutes: 615,
      notifyDayBefore: false,
      notifySameDay: true,
      emailEnabled: emailEnabled,
      emailAddress: emailEnabled ? "mom@example.com" : "",
      emailMessage: emailEnabled ? "记得打电话" : ""
    ),
    nextSolarDate: try date("2026-09-25T02:15:00Z"),
    version: 7,
    createdAt: try date("2026-01-01T00:00:00Z"),
    updatedAt: try date("2026-08-22T04:00:00Z"),
    deletedAt: try date("2026-08-22T05:00:00Z"),
    syncState: .pending
  )
}

private func makeDTOAPIBirthday(
  id: UUID = birthdayID,
  name: String = "妈妈",
  lunarMonth: Int = 8,
  lunarDay: Int = 15,
  isLeapMonth: Bool = false,
  reminder: ReminderConfig = .defaults,
  nextSolarDate: Date? = nil,
  version: Int64 = 3,
  createdAt: Date = Date(timeIntervalSince1970: 10),
  updatedAt: Date = Date(timeIntervalSince1970: 20),
  deletedAt: Date? = nil
) throws -> APIBirthday {
  APIBirthday(
    id: id,
    name: name,
    lunarMonth: lunarMonth,
    lunarDay: lunarDay,
    isLeapMonth: isLeapMonth,
    reminder: reminder,
    nextSolarDate: nextSolarDate,
    version: version,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt
  )
}

private func date(_ value: String) throws -> Date {
  try MobileJSON.decoder.decode(DateBox.self, from: Data(#"{"value":"\#(value)"}"#.utf8)).value
}

private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(with: MobileJSON.encoder.encode(value)) as? [String: Any]
  )
}

private func removingKey(_ key: String, from json: String) throws -> Data {
  var object = try #require(
    JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
  )
  object.removeValue(forKey: key)
  return try JSONSerialization.data(withJSONObject: object)
}
