import CloudKit
import Foundation
import Testing

@testable import BirthdayCore

@Test func cloudRecordCodecRoundTripsOnlyTheApprovedBirthdayFields() throws {
  let record = makeLocalBirthdayRecord()
  let snapshot = try CloudBirthdaySnapshot(record: record)
  let encoded = try CloudRecordCodec.encode(snapshot: snapshot, systemFields: nil)

  #expect(encoded.recordType == "Birthday")
  #expect(encoded.recordID.zoneID.zoneName == "BirthdayZone")
  #expect(encoded.recordID.zoneID.ownerName == CKCurrentUserDefaultName)
  #expect(encoded.recordID.recordName == record.id.uuidString.lowercased())
  #expect(Set(encoded.allKeys()) == [
    "schemaVersion",
    "name",
    "lunarMonth",
    "lunarDay",
    "isLeapMonth",
    "reminderTimeMinutes",
    "notifyDayBefore",
    "notifySameDay",
    "createdAt",
    "updatedAt",
  ])
  #expect(encoded["nextSolarDate"] == nil)
  #expect(encoded["version"] == nil)
  #expect(encoded["emailEnabled"] == nil)
  #expect(encoded["emailAddress"] == nil)
  #expect(encoded["emailMessage"] == nil)
  #expect(encoded["syncState"] == nil)
  #expect(encoded["notificationAuthorization"] == nil)
  #expect(encoded["cloudSyncState"] == nil)
  #expect(try CloudRecordCodec.decode(record: encoded) == snapshot)
}

@Test func cloudRecordCodecRoundTripsTombstoneAndSafeSystemFields() throws {
  var local = makeLocalBirthdayRecord()
  local.deletedAt = Date(timeIntervalSince1970: 1_700_000_900)
  let snapshot = try CloudBirthdaySnapshot(record: local)
  let encoded = try CloudRecordCodec.encode(snapshot: snapshot, systemFields: nil)

  #expect(encoded["deletedAt"] as? Date == local.deletedAt)
  encoded["unapprovedField"] = "must not survive" as CKRecordValue
  let systemFields = try CloudRecordCodec.encodeSystemFields(of: encoded)
  let restored = try CloudRecordCodec.encode(snapshot: snapshot, systemFields: systemFields)

  #expect(restored.recordID == encoded.recordID)
  #expect(restored["unapprovedField"] == nil)
  #expect(try CloudRecordCodec.decode(record: restored) == snapshot)
}

@Test func cloudRecordCodecRejectsWrongRecordIdentity() throws {
  let valid = try CloudRecordCodec.encode(
    snapshot: CloudBirthdaySnapshot(record: makeLocalBirthdayRecord()),
    systemFields: nil
  )
  let wrongType = copyFields(
    from: valid,
    to: CKRecord(recordType: "Other", recordID: valid.recordID)
  )
  let wrongZone = copyFields(
    from: valid,
    to: CKRecord(
      recordType: "Birthday",
      recordID: CKRecord.ID(
        recordName: valid.recordID.recordName,
        zoneID: CKRecordZone.ID(zoneName: "OtherZone", ownerName: CKCurrentUserDefaultName)
      )
    )
  )
  let badUUID = copyFields(
    from: valid,
    to: CKRecord(
      recordType: "Birthday",
      recordID: CKRecord.ID(
        recordName: "not-a-uuid",
        zoneID: valid.recordID.zoneID
      )
    )
  )

  #expect(throws: CloudRecordCodecError.invalidRecordType) {
    try CloudRecordCodec.decode(record: wrongType)
  }
  #expect(throws: CloudRecordCodecError.invalidRecordZone) {
    try CloudRecordCodec.decode(record: wrongZone)
  }
  #expect(throws: CloudRecordCodecError.invalidRecordName) {
    try CloudRecordCodec.decode(record: badUUID)
  }
}

@Test func cloudRecordCodecRejectsMissingWrongVersionAndInvalidLunarFields() throws {
  let snapshot = try CloudBirthdaySnapshot(record: makeLocalBirthdayRecord())

  let missingName = try CloudRecordCodec.encode(snapshot: snapshot, systemFields: nil)
  missingName["name"] = nil
  #expect(throws: CloudRecordCodecError.missingField("name")) {
    try CloudRecordCodec.decode(record: missingName)
  }

  let unknownVersion = try CloudRecordCodec.encode(snapshot: snapshot, systemFields: nil)
  unknownVersion["schemaVersion"] = NSNumber(value: 2)
  #expect(throws: CloudRecordCodecError.unsupportedSchemaVersion(2)) {
    try CloudRecordCodec.decode(record: unknownVersion)
  }

  let invalidLunarMonth = try CloudRecordCodec.encode(snapshot: snapshot, systemFields: nil)
  invalidLunarMonth["lunarMonth"] = NSNumber(value: 13)
  #expect(throws: CloudRecordCodecError.invalidBirthday) {
    try CloudRecordCodec.decode(record: invalidLunarMonth)
  }

  let integerBackedBooleans = try CloudRecordCodec.encode(snapshot: snapshot, systemFields: nil)
  integerBackedBooleans["isLeapMonth"] = NSNumber(value: Int64(1))
  integerBackedBooleans["notifyDayBefore"] = NSNumber(value: Int64(0))
  integerBackedBooleans["notifySameDay"] = NSNumber(value: Int64(1))
  let decoded = try CloudRecordCodec.decode(record: integerBackedBooleans)
  #expect(decoded.isLeapMonth)
  #expect(!decoded.notifyDayBefore)
  #expect(decoded.notifySameDay)

  let invalidBoolean = try CloudRecordCodec.encode(snapshot: snapshot, systemFields: nil)
  invalidBoolean["notifySameDay"] = NSNumber(value: Int64(2))
  #expect(throws: CloudRecordCodecError.invalidFieldType("notifySameDay")) {
    try CloudRecordCodec.decode(record: invalidBoolean)
  }
}

@Test func cloudRecordCodecRejectsUnsafeOrMismatchedSystemFields() throws {
  let first = try CloudBirthdaySnapshot(record: makeLocalBirthdayRecord())
  let firstRecord = try CloudRecordCodec.encode(snapshot: first, systemFields: nil)
  let systemFields = try CloudRecordCodec.encodeSystemFields(of: firstRecord)

  #expect(throws: CloudRecordCodecError.invalidSystemFields) {
    try CloudRecordCodec.encode(snapshot: first, systemFields: Data("not-an-archive".utf8))
  }

  var secondLocal = makeLocalBirthdayRecord()
  secondLocal.id = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
  let second = try CloudBirthdaySnapshot(record: secondLocal)
  #expect(throws: CloudRecordCodecError.systemFieldsRecordMismatch) {
    try CloudRecordCodec.encode(snapshot: second, systemFields: systemFields)
  }
}

private func makeLocalBirthdayRecord() -> BirthdayRecord {
  BirthdayRecord(
    id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
    name: "妈妈",
    lunarBirthday: LunarBirthday(month: 8, day: 15, isLeapMonth: false),
    reminder: ReminderConfig(
      timeMinutes: 510,
      notifyDayBefore: true,
      notifySameDay: true,
      emailEnabled: true,
      emailAddress: "private@example.com",
      emailMessage: "这段内容只留在本机"
    ),
    nextSolarDate: Date(timeIntervalSince1970: 1_800_000_000),
    version: 88,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_600),
    deletedAt: nil,
    syncState: .conflict
  )
}

@discardableResult
private func copyFields(from source: CKRecord, to destination: CKRecord) -> CKRecord {
  for key in source.allKeys() {
    destination[key] = source[key]
  }
  return destination
}
