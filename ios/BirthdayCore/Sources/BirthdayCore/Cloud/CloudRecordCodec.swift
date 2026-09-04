import CloudKit
import CoreFoundation
import Foundation

public enum CloudRecordCodecError: Error, Equatable, Sendable {
  case invalidRecordType
  case invalidRecordZone
  case invalidRecordName
  case missingField(String)
  case invalidFieldType(String)
  case unexpectedField(String)
  case unsupportedSchemaVersion(Int64)
  case invalidBirthday
  case invalidSystemFields
  case systemFieldsRecordMismatch
}

public enum CloudRecordCodec {
  public static let recordType = "Birthday"
  public static let zoneName = "BirthdayZone"
  public static let zoneID = CKRecordZone.ID(
    zoneName: zoneName,
    ownerName: CKCurrentUserDefaultName
  )

  private enum Field {
    static let schemaVersion = "schemaVersion"
    static let name = "name"
    static let lunarMonth = "lunarMonth"
    static let lunarDay = "lunarDay"
    static let isLeapMonth = "isLeapMonth"
    static let reminderTimeMinutes = "reminderTimeMinutes"
    static let notifyDayBefore = "notifyDayBefore"
    static let notifySameDay = "notifySameDay"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"
    static let deletedAt = "deletedAt"

    static let all: Set<String> = [
      schemaVersion,
      name,
      lunarMonth,
      lunarDay,
      isLeapMonth,
      reminderTimeMinutes,
      notifyDayBefore,
      notifySameDay,
      createdAt,
      updatedAt,
      deletedAt,
    ]
  }

  public static func encode(
    snapshot: CloudBirthdaySnapshot,
    systemFields: Data?
  ) throws -> CKRecord {
    let expectedRecordID = CKRecord.ID(
      recordName: snapshot.id.uuidString.lowercased(),
      zoneID: zoneID
    )
    let record: CKRecord
    if let systemFields {
      record = try decodeSystemFields(systemFields)
      guard record.recordType == recordType, record.recordID == expectedRecordID else {
        throw CloudRecordCodecError.systemFieldsRecordMismatch
      }
    } else {
      record = CKRecord(recordType: recordType, recordID: expectedRecordID)
    }

    for key in record.allKeys() {
      record[key] = nil
    }
    record[Field.schemaVersion] = NSNumber(value: snapshot.schemaVersion)
    record[Field.name] = snapshot.name as CKRecordValue
    record[Field.lunarMonth] = NSNumber(value: snapshot.lunarMonth)
    record[Field.lunarDay] = NSNumber(value: snapshot.lunarDay)
    record[Field.isLeapMonth] = NSNumber(value: snapshot.isLeapMonth)
    record[Field.reminderTimeMinutes] = NSNumber(value: snapshot.reminderTimeMinutes)
    record[Field.notifyDayBefore] = NSNumber(value: snapshot.notifyDayBefore)
    record[Field.notifySameDay] = NSNumber(value: snapshot.notifySameDay)
    record[Field.createdAt] = snapshot.createdAt as CKRecordValue
    record[Field.updatedAt] = snapshot.updatedAt as CKRecordValue
    if let deletedAt = snapshot.deletedAt {
      record[Field.deletedAt] = deletedAt as CKRecordValue
    }
    return record
  }

  public static func decode(record: CKRecord) throws -> CloudBirthdaySnapshot {
    guard record.recordType == recordType else {
      throw CloudRecordCodecError.invalidRecordType
    }
    guard record.recordID.zoneID == zoneID else {
      throw CloudRecordCodecError.invalidRecordZone
    }
    guard
      let id = UUID(uuidString: record.recordID.recordName),
      record.recordID.recordName == id.uuidString.lowercased()
    else {
      throw CloudRecordCodecError.invalidRecordName
    }
    if let unexpected = Set(record.allKeys()).subtracting(Field.all).sorted().first {
      throw CloudRecordCodecError.unexpectedField(unexpected)
    }

    let schemaVersion = try integer(record, Field.schemaVersion)
    guard schemaVersion == CloudBirthdaySnapshot.currentSchemaVersion else {
      throw CloudRecordCodecError.unsupportedSchemaVersion(schemaVersion)
    }

    do {
      return try CloudBirthdaySnapshot(
        schemaVersion: schemaVersion,
        id: id,
        name: string(record, Field.name),
        lunarMonth: Int(integer(record, Field.lunarMonth)),
        lunarDay: Int(integer(record, Field.lunarDay)),
        isLeapMonth: boolean(record, Field.isLeapMonth),
        reminderTimeMinutes: Int(integer(record, Field.reminderTimeMinutes)),
        notifyDayBefore: boolean(record, Field.notifyDayBefore),
        notifySameDay: boolean(record, Field.notifySameDay),
        createdAt: date(record, Field.createdAt),
        updatedAt: date(record, Field.updatedAt),
        deletedAt: optionalDate(record, Field.deletedAt)
      )
    } catch let error as CloudRecordCodecError {
      throw error
    } catch {
      throw CloudRecordCodecError.invalidBirthday
    }
  }

  public static func encodeSystemFields(of record: CKRecord) throws -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  private static func decodeSystemFields(_ data: Data) throws -> CKRecord {
    do {
      let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
      unarchiver.requiresSecureCoding = true
      defer { unarchiver.finishDecoding() }
      guard let record = CKRecord(coder: unarchiver) else {
        throw CloudRecordCodecError.invalidSystemFields
      }
      return record
    } catch {
      throw CloudRecordCodecError.invalidSystemFields
    }
  }

  private static func string(_ record: CKRecord, _ field: String) throws -> String {
    guard let value = record[field] else {
      throw CloudRecordCodecError.missingField(field)
    }
    guard let value = value as? String else {
      throw CloudRecordCodecError.invalidFieldType(field)
    }
    return value
  }

  private static func integer(_ record: CKRecord, _ field: String) throws -> Int64 {
    guard let value = record[field] else {
      throw CloudRecordCodecError.missingField(field)
    }
    guard
      let number = value as? NSNumber,
      CFGetTypeID(number) == CFNumberGetTypeID(),
      !CFNumberIsFloatType(number)
    else {
      throw CloudRecordCodecError.invalidFieldType(field)
    }
    return number.int64Value
  }

  private static func boolean(_ record: CKRecord, _ field: String) throws -> Bool {
    guard let value = record[field] else {
      throw CloudRecordCodecError.missingField(field)
    }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      throw CloudRecordCodecError.invalidFieldType(field)
    }
    return number.boolValue
  }

  private static func date(_ record: CKRecord, _ field: String) throws -> Date {
    guard let value = record[field] else {
      throw CloudRecordCodecError.missingField(field)
    }
    guard let value = value as? Date else {
      throw CloudRecordCodecError.invalidFieldType(field)
    }
    return value
  }

  private static func optionalDate(_ record: CKRecord, _ field: String) throws -> Date? {
    guard let value = record[field] else { return nil }
    guard let value = value as? Date else {
      throw CloudRecordCodecError.invalidFieldType(field)
    }
    return value
  }
}
