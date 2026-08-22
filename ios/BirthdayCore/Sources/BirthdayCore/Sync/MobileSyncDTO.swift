import Foundation

public enum MobileJSON {
  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      return try StrictRFC3339.date(from: value, codingPath: decoder.codingPath)
    }
    return decoder
  }

  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(StrictRFC3339.string(from: date))
    }
    return encoder
  }
}

public struct DecimalInt64: Codable, Equatable, Sendable {
  public let value: Int64

  public init(_ value: Int64) {
    precondition(value >= 0, "mobile sync integers must be nonnegative")
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let string = try decoder.singleValueContainer().decode(String.self)
    guard Self.isCanonical(string), let value = Int64(string) else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "expected a canonical nonnegative signed Int64 decimal string"
        )
      )
    }
    self.value = value
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(String(value))
  }

  private static func isCanonical(_ string: String) -> Bool {
    let bytes = Array(string.utf8)
    guard !bytes.isEmpty else { return false }
    if bytes == [Character("0").asciiValue!] { return true }
    guard bytes[0] >= Character("1").asciiValue!, bytes[0] <= Character("9").asciiValue! else {
      return false
    }
    return bytes.dropFirst().allSatisfy {
      $0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!
    }
  }
}

private struct MobileUUID: Codable, Equatable, Sendable {
  let value: UUID

  init(_ value: UUID) {
    precondition(
      Self.isContractUUID(value.uuidString), "mobile sync UUID must be version 1 through 8")
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let string = try decoder.singleValueContainer().decode(String.self)
    guard Self.isContractUUID(string), let value = UUID(uuidString: string) else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "expected a UUID version 1 through 8"
        )
      )
    }
    self.value = value
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value.uuidString.lowercased())
  }

  private static func isContractUUID(_ string: String) -> Bool {
    let bytes = Array(string.utf8)
    guard bytes.count == 36 else { return false }
    for index in bytes.indices {
      if index == 8 || index == 13 || index == 18 || index == 23 {
        guard bytes[index] == Character("-").asciiValue! else { return false }
      } else {
        guard isHex(bytes[index]) else { return false }
      }
    }
    guard bytes[14] >= Character("1").asciiValue!, bytes[14] <= Character("8").asciiValue! else {
      return false
    }
    return ["8", "9", "a", "b", "A", "B"].compactMap(\.first?.asciiValue).contains(bytes[19])
  }

  private static func isHex(_ byte: UInt8) -> Bool {
    (byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!)
      || (byte >= Character("a").asciiValue! && byte <= Character("f").asciiValue!)
      || (byte >= Character("A").asciiValue! && byte <= Character("F").asciiValue!)
  }
}

private enum StrictRFC3339 {
  static func date(from string: String, codingPath: [any CodingKey]) throws -> Date {
    guard let components = parse(string) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: codingPath, debugDescription: "invalid strict RFC 3339 instant")
      )
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var dateComponents = DateComponents()
    dateComponents.calendar = calendar
    dateComponents.timeZone = calendar.timeZone
    dateComponents.year = components.year
    dateComponents.month = components.month
    dateComponents.day = components.day
    dateComponents.hour = components.hour
    dateComponents.minute = components.minute
    dateComponents.second = components.second

    guard let localSecond = calendar.date(from: dateComponents) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: codingPath, debugDescription: "invalid strict RFC 3339 instant")
      )
    }

    let fraction =
      components.fraction.map { fractionDigits -> TimeInterval in
        let nanosecondDigits = String(fractionDigits.prefix(9)).padding(
          toLength: 9,
          withPad: "0",
          startingAt: 0
        )
        return TimeInterval(Int(nanosecondDigits)!) / 1_000_000_000
      } ?? 0
    let signedOffset =
      components.offsetSign * (components.offsetHour * 3_600 + components.offsetMinute * 60)
    return localSecond.addingTimeInterval(fraction - TimeInterval(signedOffset))
  }

  static func string(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.string(from: date)
  }

  private struct Parsed {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int
    let fraction: Substring?
    let offsetSign: Int
    let offsetHour: Int
    let offsetMinute: Int
  }

  private static func parse(_ string: String) -> Parsed? {
    let bytes = Array(string.utf8)
    guard bytes.count >= 20 else { return nil }
    guard bytes[4] == ascii("-"), bytes[7] == ascii("-"), bytes[10] == ascii("T"),
      bytes[13] == ascii(":"), bytes[16] == ascii(":")
    else { return nil }

    guard
      let year = integer(bytes[0...3]),
      let month = integer(bytes[5...6]),
      let day = integer(bytes[8...9]),
      let hour = integer(bytes[11...12]),
      let minute = integer(bytes[14...15]),
      let second = integer(bytes[17...18])
    else { return nil }

    var cursor = 19
    var fraction: Substring?
    if bytes[cursor] == ascii(".") {
      let start = cursor + 1
      cursor = start
      while cursor < bytes.count, isDigit(bytes[cursor]) { cursor += 1 }
      guard cursor > start else { return nil }
      let startIndex = string.index(string.startIndex, offsetBy: start)
      let endIndex = string.index(string.startIndex, offsetBy: cursor)
      fraction = string[startIndex..<endIndex]
    }

    let offsetSign: Int
    let offsetHour: Int
    let offsetMinute: Int
    if cursor == bytes.count - 1, bytes[cursor] == ascii("Z") {
      offsetSign = 0
      offsetHour = 0
      offsetMinute = 0
    } else {
      guard cursor + 6 == bytes.count,
        bytes[cursor] == ascii("+") || bytes[cursor] == ascii("-"),
        bytes[cursor + 3] == ascii(":"),
        let parsedOffsetHour = integer(bytes[(cursor + 1)...(cursor + 2)]),
        let parsedOffsetMinute = integer(bytes[(cursor + 4)...(cursor + 5)])
      else { return nil }
      offsetSign = bytes[cursor] == ascii("+") ? 1 : -1
      offsetHour = parsedOffsetHour
      offsetMinute = parsedOffsetMinute
    }

    let leapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard month >= 1, month <= 12,
      day >= 1, day <= daysInMonth[month - 1],
      hour <= 23, minute <= 59, second <= 59,
      offsetHour <= 23, offsetMinute <= 59
    else { return nil }

    return Parsed(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      fraction: fraction,
      offsetSign: offsetSign,
      offsetHour: offsetHour,
      offsetMinute: offsetMinute
    )
  }

  private static func integer(_ bytes: ArraySlice<UInt8>) -> Int? {
    guard bytes.allSatisfy(isDigit) else { return nil }
    return bytes.reduce(0) { $0 * 10 + Int($1 - ascii("0")) }
  }

  private static func isDigit(_ byte: UInt8) -> Bool {
    byte >= ascii("0") && byte <= ascii("9")
  }

  private static func ascii(_ character: Character) -> UInt8 {
    character.asciiValue!
  }
}

public struct APIBirthday: Codable, Equatable, Sendable {
  private let idValue: MobileUUID
  public let name: String
  public let lunarMonth: Int
  public let lunarDay: Int
  public let isLeapMonth: Bool
  public let reminderTimeMinutes: Int
  public let notifyDayBefore: Bool
  public let notifySameDay: Bool
  public let emailEnabled: Bool
  public let emailAddress: String
  public let emailMessage: String
  public let nextSolarDate: Date?
  private let versionValue: DecimalInt64
  public let createdAt: Date
  public let updatedAt: Date
  public let deletedAt: Date?

  public var id: UUID { idValue.value }
  public var version: Int64 { versionValue.value }
  public var reminder: ReminderConfig {
    ReminderConfig(
      timeMinutes: reminderTimeMinutes,
      notifyDayBefore: notifyDayBefore,
      notifySameDay: notifySameDay,
      emailEnabled: emailEnabled,
      emailAddress: emailAddress,
      emailMessage: emailMessage
    )
  }

  enum CodingKeys: String, CodingKey {
    case idValue = "id"
    case name, lunarMonth, lunarDay, isLeapMonth, reminderTimeMinutes
    case notifyDayBefore, notifySameDay, emailEnabled, emailAddress, emailMessage
    case nextSolarDate
    case versionValue = "version"
    case createdAt, updatedAt, deletedAt
  }

  public init(
    id: UUID,
    name: String,
    lunarMonth: Int,
    lunarDay: Int,
    isLeapMonth: Bool,
    reminder: ReminderConfig,
    nextSolarDate: Date?,
    version: Int64,
    createdAt: Date,
    updatedAt: Date,
    deletedAt: Date?
  ) {
    idValue = MobileUUID(id)
    self.name = name
    self.lunarMonth = lunarMonth
    self.lunarDay = lunarDay
    self.isLeapMonth = isLeapMonth
    reminderTimeMinutes = reminder.timeMinutes
    notifyDayBefore = reminder.notifyDayBefore
    notifySameDay = reminder.notifySameDay
    emailEnabled = reminder.emailEnabled
    emailAddress = reminder.emailAddress
    emailMessage = reminder.emailMessage
    self.nextSolarDate = nextSolarDate
    versionValue = DecimalInt64(version)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  public func asRecord(syncState: SyncState) -> BirthdayRecord {
    BirthdayRecord(
      id: id,
      name: name,
      lunarBirthday: LunarBirthday(
        month: lunarMonth,
        day: lunarDay,
        isLeapMonth: isLeapMonth
      ),
      reminder: reminder,
      nextSolarDate: nextSolarDate,
      version: version,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
      syncState: syncState
    )
  }
}

public struct SnapshotResponse: Codable, Equatable, Sendable {
  private let cursorValue: DecimalInt64
  public let birthdays: [APIBirthday]

  public var cursor: Int64 { cursorValue.value }

  enum CodingKeys: String, CodingKey {
    case cursorValue = "cursor"
    case birthdays
  }

  public init(cursor: Int64, birthdays: [APIBirthday]) {
    cursorValue = DecimalInt64(cursor)
    self.birthdays = birthdays
  }
}

public struct LoginRequest: Codable, Equatable, Sendable {
  public let username: String
  public let password: String
  private let deviceIdValue: MobileUUID
  public let deviceName: String

  public var deviceId: UUID { deviceIdValue.value }

  enum CodingKeys: String, CodingKey {
    case username, password
    case deviceIdValue = "deviceId"
    case deviceName
  }

  public init(username: String, password: String, deviceId: UUID, deviceName: String) {
    self.username = username
    self.password = password
    deviceIdValue = MobileUUID(deviceId)
    self.deviceName = deviceName
  }
}

public struct RefreshRequest: Codable, Equatable, Sendable {
  public let refreshToken: String

  public init(refreshToken: String) {
    self.refreshToken = refreshToken
  }
}

public struct TokenResponse: Codable, Equatable, Sendable {
  private let deviceIdValue: MobileUUID
  public let accessToken: String
  public let accessExpiresAt: Date
  public let refreshToken: String
  public let refreshExpiresAt: Date

  public var deviceId: UUID { deviceIdValue.value }

  enum CodingKeys: String, CodingKey {
    case deviceIdValue = "deviceId"
    case accessToken, accessExpiresAt, refreshToken, refreshExpiresAt
  }

  public init(
    deviceId: UUID,
    accessToken: String,
    accessExpiresAt: Date,
    refreshToken: String,
    refreshExpiresAt: Date
  ) {
    deviceIdValue = MobileUUID(deviceId)
    self.accessToken = accessToken
    self.accessExpiresAt = accessExpiresAt
    self.refreshToken = refreshToken
    self.refreshExpiresAt = refreshExpiresAt
  }
}

public struct BirthdayPayloadDTO: Codable, Equatable, Sendable {
  private let idValue: MobileUUID
  public let name: String
  public let lunarMonth: Int
  public let lunarDay: Int
  public let isLeapMonth: Bool
  public let reminderTimeMinutes: Int
  public let notifyDayBefore: Bool
  public let notifySameDay: Bool
  public let emailEnabled: Bool
  public let emailAddress: String
  public let emailMessage: String

  public var id: UUID { idValue.value }

  enum CodingKeys: String, CodingKey {
    case idValue = "id"
    case name, lunarMonth, lunarDay, isLeapMonth, reminderTimeMinutes
    case notifyDayBefore, notifySameDay, emailEnabled, emailAddress, emailMessage
  }

  public init(
    id: UUID,
    name: String,
    lunarMonth: Int,
    lunarDay: Int,
    isLeapMonth: Bool,
    reminderTimeMinutes: Int,
    notifyDayBefore: Bool,
    notifySameDay: Bool,
    emailEnabled: Bool,
    emailAddress: String,
    emailMessage: String
  ) {
    idValue = MobileUUID(id)
    self.name = name
    self.lunarMonth = lunarMonth
    self.lunarDay = lunarDay
    self.isLeapMonth = isLeapMonth
    self.reminderTimeMinutes = reminderTimeMinutes
    self.notifyDayBefore = notifyDayBefore
    self.notifySameDay = notifySameDay
    self.emailEnabled = emailEnabled
    self.emailAddress = emailEnabled ? emailAddress : ""
    self.emailMessage = emailEnabled ? emailMessage : ""
  }

  public init(record: BirthdayRecord) {
    self.init(
      id: record.id,
      name: record.name,
      lunarMonth: record.lunarBirthday.month,
      lunarDay: record.lunarBirthday.day,
      isLeapMonth: record.lunarBirthday.isLeapMonth,
      reminderTimeMinutes: record.reminder.timeMinutes,
      notifyDayBefore: record.reminder.notifyDayBefore,
      notifySameDay: record.reminder.notifySameDay,
      emailEnabled: record.reminder.emailEnabled,
      emailAddress: record.reminder.emailAddress,
      emailMessage: record.reminder.emailMessage
    )
  }
}

public enum PushOperationKind: String, Codable, Equatable, Sendable {
  case upsert
  case delete
}

public enum MobileSyncDTOError: Error, Equatable, Sendable {
  case invalidOperationType(String)
  case invalidBaseVersion(Int64)
  case payloadEntityMismatch
}

public struct PushOperationDTO: Codable, Equatable, Sendable {
  private let operationIdValue: MobileUUID
  private let entityIdValue: MobileUUID
  public let type: PushOperationKind
  private let baseVersionValue: DecimalInt64
  public let payload: BirthdayPayloadDTO?

  public var operationId: UUID { operationIdValue.value }
  public var entityId: UUID { entityIdValue.value }
  public var baseVersion: Int64 { baseVersionValue.value }

  enum CodingKeys: String, CodingKey {
    case operationIdValue = "operationId"
    case entityIdValue = "entityId"
    case type
    case baseVersionValue = "baseVersion"
    case payload
  }

  public init(
    operationId: UUID,
    entityId: UUID,
    type: PushOperationKind,
    baseVersion: Int64,
    payload: BirthdayPayloadDTO?
  ) {
    operationIdValue = MobileUUID(operationId)
    entityIdValue = MobileUUID(entityId)
    self.type = type
    baseVersionValue = DecimalInt64(baseVersion)
    self.payload = payload
  }

  public init(_ operation: SyncOperation) throws {
    guard let type = PushOperationKind(rawValue: operation.operationType) else {
      throw MobileSyncDTOError.invalidOperationType(operation.operationType)
    }
    guard operation.baseVersion >= 0 else {
      throw MobileSyncDTOError.invalidBaseVersion(operation.baseVersion)
    }

    let payload: BirthdayPayloadDTO?
    switch type {
    case .upsert:
      let decoded = try MobileJSON.decoder.decode(
        BirthdayPayloadDTO.self, from: operation.payloadJSON)
      guard decoded.id == operation.entityId else {
        throw MobileSyncDTOError.payloadEntityMismatch
      }
      payload = decoded
    case .delete:
      payload = nil
    }

    self.init(
      operationId: operation.operationId,
      entityId: operation.entityId,
      type: type,
      baseVersion: operation.baseVersion,
      payload: payload
    )
  }
}

public struct PushRequest: Codable, Equatable, Sendable {
  public let operations: [PushOperationDTO]

  public init(operations: [PushOperationDTO]) {
    self.operations = operations
  }
}

public enum PushResultStatus: String, Codable, Equatable, Sendable {
  case applied
  case conflict
}

public struct PushResult: Codable, Equatable, Sendable {
  private let operationIdValue: MobileUUID
  public let status: PushResultStatus
  public let record: APIBirthday?
  public let remote: APIBirthday?

  public var operationId: UUID { operationIdValue.value }

  enum CodingKeys: String, CodingKey {
    case operationIdValue = "operationId"
    case status, record, remote
  }

  public init(
    operationId: UUID,
    status: PushResultStatus,
    record: APIBirthday?,
    remote: APIBirthday?
  ) {
    operationIdValue = MobileUUID(operationId)
    self.status = status
    self.record = record
    self.remote = remote
  }
}

public struct PushResponse: Codable, Equatable, Sendable {
  public let results: [PushResult]

  public init(results: [PushResult]) {
    self.results = results
  }
}

public enum PullOperation: String, Codable, Equatable, Sendable {
  case upsert
  case delete
}

public struct PullChange: Codable, Equatable, Sendable {
  private let seqValue: DecimalInt64
  public let operation: PullOperation
  public let record: APIBirthday

  public var seq: Int64 { seqValue.value }

  enum CodingKeys: String, CodingKey {
    case seqValue = "seq"
    case operation, record
  }

  public init(seq: Int64, operation: PullOperation, record: APIBirthday) {
    seqValue = DecimalInt64(seq)
    self.operation = operation
    self.record = record
  }
}

public struct PullResponse: Codable, Equatable, Sendable {
  public let changes: [PullChange]
  private let nextCursorValue: DecimalInt64
  public let hasMore: Bool

  public var nextCursor: Int64 { nextCursorValue.value }

  enum CodingKeys: String, CodingKey {
    case changes
    case nextCursorValue = "nextCursor"
    case hasMore
  }

  public init(changes: [PullChange], nextCursor: Int64, hasMore: Bool) {
    self.changes = changes
    nextCursorValue = DecimalInt64(nextCursor)
    self.hasMore = hasMore
  }
}

public struct MobileDevice: Codable, Equatable, Sendable {
  private let deviceIdValue: MobileUUID
  public let deviceName: String
  public let createdAt: Date
  public let lastUsedAt: Date?
  public let revokedAt: Date?

  public var deviceId: UUID { deviceIdValue.value }

  enum CodingKeys: String, CodingKey {
    case deviceIdValue = "deviceId"
    case deviceName, createdAt, lastUsedAt, revokedAt
  }

  public init(
    deviceId: UUID,
    deviceName: String,
    createdAt: Date,
    lastUsedAt: Date?,
    revokedAt: Date?
  ) {
    deviceIdValue = MobileUUID(deviceId)
    self.deviceName = deviceName
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.revokedAt = revokedAt
  }
}
