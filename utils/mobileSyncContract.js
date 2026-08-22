const moment = require('moment-timezone')
const { calculateNextSolarDate, TZ } = require('./helpers')
const { MOBILE_API_CONTRACT, MOBILE_ERROR_CODES } = require('./mobileApiContract')

const DECIMAL_INT64_PATTERN = /^(?:0|[1-9]\d*)$/
const LIMIT_PATTERN = /^[1-9]\d*$/
const TIME_PATTERN = /^(\d{2}):(\d{2})(?::(\d{2}))?$/
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const EDGE_WHITE_SPACE_PATTERN = /^(?:\p{White_Space})+|(?:\p{White_Space})+$/gu
const STORAGE_DATE_PATTERN = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
const RFC3339_INSTANT_PATTERN = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:Z|[+-](\d{2}):(\d{2}))$/
const INT64_MAX = BigInt(MOBILE_API_CONTRACT.limits.signedInt64Maximum)
const INT64_MAX_DECIMAL = INT64_MAX.toString(10)
const MAX_ENABLED_EMAIL_STORAGE_BYTES = MOBILE_API_CONTRACT.limits.enabledEmailStorageBytes
const MAX_PUSH_REQUEST_BYTES = MOBILE_API_CONTRACT.limits.pushCompactJSONBytes
const MAX_LUNAR_YEAR_PROBES = 20
const NORMALIZED_PUSH_OPERATION = Symbol('normalizedPushOperation')
const DEFAULT_GRAPHEME_SEGMENTER = (
  typeof Intl === 'object' && typeof Intl.Segmenter === 'function'
    ? new Intl.Segmenter('und', { granularity: 'grapheme' })
    : null
)

class MobileSyncValidationError extends Error {
  constructor(code, message = code) {
    super(message)
    this.name = 'MobileSyncValidationError'
    this.code = code
  }
}

class MobileSyncDataConsistencyError extends Error {
  constructor(message = 'invalid mobile sync database state') {
    super(message)
    this.name = 'MobileSyncDataConsistencyError'
    this.code = 'mobile_sync_inconsistent_state'
  }
}

function invalidBirthdayPayload() {
  return new MobileSyncValidationError(MOBILE_ERROR_CODES.invalidBirthdayPayload, 'invalid birthday payload')
}

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function normalizeUUID(value) {
  if (typeof value !== 'string' || !UUID_PATTERN.test(value)) {
    throw invalidBirthdayPayload()
  }
  return value.toLowerCase()
}

function isUUID(value) {
  return typeof value === 'string' && UUID_PATTERN.test(value)
}

function isCanonicalInt64String(value) {
  return typeof value === 'string'
    && DECIMAL_INT64_PATTERN.test(value)
    && BigInt(value) <= INT64_MAX
}

function normalizeInt64String(value) {
  if (!isCanonicalInt64String(value)) {
    throw invalidBirthdayPayload()
  }
  return value
}

function isStrictISO8601Instant(value) {
  if (typeof value !== 'string') return false
  const match = value.match(RFC3339_INSTANT_PATTERN)
  if (!match) return false

  const year = Number(match[1])
  const month = Number(match[2])
  const day = Number(match[3])
  const hour = Number(match[4])
  const minute = Number(match[5])
  const second = Number(match[6])
  const offsetHour = match[8] === undefined ? 0 : Number(match[8])
  const offsetMinute = match[9] === undefined ? 0 : Number(match[9])
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)
  const daysInMonth = [
    31,
    leapYear ? 29 : 28,
    31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
  ]

  return month >= 1
    && month <= 12
    && day >= 1
    && day <= daysInMonth[month - 1]
    && hour <= 23
    && minute <= 59
    && second <= 59
    && offsetHour <= 23
    && offsetMinute <= 59
}

function invalidAPIRecord(message = 'invalid API birthday record') {
  throw new MobileSyncDataConsistencyError(message)
}

function hasExactFields(record, expectedFields) {
  const actualFields = Object.keys(record)
  return actualFields.length === expectedFields.length
    && expectedFields.every(field => Object.hasOwn(record, field))
}

function validateAPIBirthdayDTO(record) {
  const fields = MOBILE_API_CONTRACT.dtoFields.birthday
  if (!isPlainObject(record) || !hasExactFields(record, fields)) invalidAPIRecord()
  if (!isUUID(record.id)) invalidAPIRecord('birthday id is invalid')
  if (typeof record.name !== 'string') invalidAPIRecord('birthday name is invalid')

  const name = trimUnicodeWhiteSpace(record.name)
  if (!name || !fitsUTF8MB4Column(name, 64)) {
    invalidAPIRecord('birthday name is invalid')
  }
  if (!Number.isInteger(record.lunarMonth) || record.lunarMonth < 1 || record.lunarMonth > 12) {
    invalidAPIRecord('birthday lunar month is invalid')
  }
  if (!Number.isInteger(record.lunarDay) || record.lunarDay < 1 || record.lunarDay > 30) {
    invalidAPIRecord('birthday lunar day is invalid')
  }
  if (
    typeof record.isLeapMonth !== 'boolean'
    || typeof record.notifyDayBefore !== 'boolean'
    || typeof record.notifySameDay !== 'boolean'
    || typeof record.emailEnabled !== 'boolean'
  ) {
    invalidAPIRecord('birthday boolean field is invalid')
  }
  if (!record.notifyDayBefore && !record.notifySameDay) {
    invalidAPIRecord('birthday notification channel is required')
  }
  if (
    !Number.isInteger(record.reminderTimeMinutes)
    || record.reminderTimeMinutes < 0
    || record.reminderTimeMinutes >= 1440
  ) {
    invalidAPIRecord('birthday reminder time is invalid')
  }
  if (typeof record.emailAddress !== 'string' || typeof record.emailMessage !== 'string') {
    invalidAPIRecord('birthday email field is invalid')
  }

  if (record.emailEnabled) {
    const emailAddress = trimUnicodeWhiteSpace(record.emailAddress)
    if (
      !emailAddress
      || !fitsUTF8MB4Column(emailAddress, 128)
      || !isValidEmailAddress(emailAddress)
      || Buffer.byteLength(`${name}${record.emailMessage}`, 'utf8') > MAX_ENABLED_EMAIL_STORAGE_BYTES
    ) {
      invalidAPIRecord('birthday enabled email is invalid')
    }
  } else if (record.emailAddress !== '' || record.emailMessage !== '') {
    invalidAPIRecord('birthday disabled email must be empty')
  }

  if (record.nextSolarDate !== null && !isStrictISO8601Instant(record.nextSolarDate)) {
    invalidAPIRecord('birthday next date is invalid')
  }
  if (!isCanonicalInt64String(record.version)) invalidAPIRecord('birthday version is invalid')
  if (!isStrictISO8601Instant(record.createdAt) || !isStrictISO8601Instant(record.updatedAt)) {
    invalidAPIRecord('birthday audit date is invalid')
  }
  if (record.deletedAt !== null && !isStrictISO8601Instant(record.deletedAt)) {
    invalidAPIRecord('birthday deleted date is invalid')
  }
  return record
}

function assertAPIBirthdayChange({ entityId, operation, entityVersion, record }) {
  validateAPIBirthdayDTO(record)
  if (
    !isUUID(entityId)
    || record.id !== entityId
    || !isCanonicalInt64String(entityVersion)
    || record.version !== entityVersion
    || (operation !== 'upsert' && operation !== 'delete')
    || (operation === 'upsert' && record.deletedAt !== null)
    || (
      operation === 'delete'
      && (
        record.deletedAt === null
        || record.emailEnabled !== false
        || record.emailAddress !== ''
        || record.emailMessage !== ''
      )
    )
  ) {
    invalidAPIRecord('change metadata does not match its birthday record')
  }
  return record
}

function graphemeLength(value, segmenter = DEFAULT_GRAPHEME_SEGMENTER) {
  if (!segmenter || typeof segmenter.segment !== 'function') {
    const error = new Error('Intl.Segmenter is required for birthday validation')
    error.code = 'grapheme_segmenter_unavailable'
    throw error
  }

  let count = 0
  for (const _part of segmenter.segment(value)) count += 1
  return count
}

function trimUnicodeWhiteSpace(value) {
  return value.replace(EDGE_WHITE_SPACE_PATTERN, '')
}

function fitsUTF8MB4Column(value, maximum) {
  return graphemeLength(value) <= maximum && Array.from(value).length <= maximum
}

function isValidEmailAddress(emailAddress) {
  const atIndex = emailAddress.indexOf('@')
  return (
    atIndex > 0
    && atIndex === emailAddress.lastIndexOf('@')
    && atIndex < emailAddress.length - 1
  )
}

function calculateNextAvailableDate(payload, {
  calculateNextSolarDateFn = calculateNextSolarDate,
  nowInput = new Date(),
} = {}) {
  const start = moment.tz(nowInput, TZ)
  if (!start.isValid()) throw invalidBirthdayPayload()

  for (let offset = 0; offset <= MAX_LUNAR_YEAR_PROBES; offset += 1) {
    const probe = offset === 0 ? start : start.clone().add(offset, 'year')
    try {
      const value = calculateNextSolarDateFn({
        lunarMonth: payload.lunarMonth,
        lunarDay: payload.lunarDay,
        isLeapMonth: payload.isLeapMonth,
        remindTime: payload.remindTime,
      }, probe.toDate())
      if (typeof value === 'string' && STORAGE_DATE_PATTERN.test(value)) return value
    } catch {
      // A lunar month may have only 29 days in this year; probe later years.
    }
  }
  throw invalidBirthdayPayload()
}

function normalizeBirthdayPayload(payload, dateOptions) {
  if (!isPlainObject(payload)) throw invalidBirthdayPayload()

  const {
    id,
    name: rawName,
    lunarMonth,
    lunarDay,
    isLeapMonth,
    reminderTimeMinutes,
    notifyDayBefore,
    notifySameDay,
    emailEnabled,
    emailAddress: rawEmailAddress,
    emailMessage: rawEmailMessage,
  } = payload
  const normalizedId = normalizeUUID(id)
  if (typeof rawName !== 'string') throw invalidBirthdayPayload()

  const name = trimUnicodeWhiteSpace(rawName)
  if (!name || !fitsUTF8MB4Column(name, 64)) throw invalidBirthdayPayload()
  if (!Number.isInteger(lunarMonth) || lunarMonth < 1 || lunarMonth > 12) {
    throw invalidBirthdayPayload()
  }
  if (!Number.isInteger(lunarDay) || lunarDay < 1 || lunarDay > 30) {
    throw invalidBirthdayPayload()
  }
  if (typeof isLeapMonth !== 'boolean') throw invalidBirthdayPayload()
  if (
    !Number.isInteger(reminderTimeMinutes)
    || reminderTimeMinutes < 0
    || reminderTimeMinutes >= 1440
  ) {
    throw invalidBirthdayPayload()
  }
  if (typeof notifyDayBefore !== 'boolean' || typeof notifySameDay !== 'boolean') {
    throw invalidBirthdayPayload()
  }
  if (!notifyDayBefore && !notifySameDay) throw invalidBirthdayPayload()
  if (typeof emailEnabled !== 'boolean') throw invalidBirthdayPayload()
  if (typeof rawEmailAddress !== 'string' || typeof rawEmailMessage !== 'string') {
    throw invalidBirthdayPayload()
  }

  let emailAddress = trimUnicodeWhiteSpace(rawEmailAddress)
  let emailMessage = rawEmailMessage
  if (emailEnabled) {
    if (
      !emailAddress
      || !fitsUTF8MB4Column(emailAddress, 128)
      || !isValidEmailAddress(emailAddress)
      || Buffer.byteLength(`${name}${emailMessage}`, 'utf8') > MAX_ENABLED_EMAIL_STORAGE_BYTES
    ) {
      throw invalidBirthdayPayload()
    }
  } else {
    emailAddress = ''
    emailMessage = ''
  }

  const hour = String(Math.floor(reminderTimeMinutes / 60)).padStart(2, '0')
  const minute = String(reminderTimeMinutes % 60).padStart(2, '0')
  const normalized = {
    id: normalizedId,
    name,
    lunarMonth,
    lunarDay,
    isLeapMonth,
    reminderTimeMinutes,
    notifyDayBefore,
    notifySameDay,
    emailEnabled,
    emailAddress,
    emailMessage,
    remindTime: `${hour}:${minute}:00`,
  }
  normalized.nextSolarDate = calculateNextAvailableDate(normalized, dateOptions)
  return normalized
}

function markNormalizedOperation(operation) {
  Object.defineProperty(operation, NORMALIZED_PUSH_OPERATION, { value: true })
  return operation
}

function isNormalizedPushOperation(operation) {
  return Boolean(operation && operation[NORMALIZED_PUSH_OPERATION])
}

function normalizePushRequest(body, dateOptions) {
  if (!isPlainObject(body)) throw invalidBirthdayPayload()
  let compactJSON
  try {
    compactJSON = JSON.stringify(body)
  } catch {
    throw invalidBirthdayPayload()
  }
  if (
    typeof compactJSON !== 'string'
    || Buffer.byteLength(compactJSON, 'utf8') > MAX_PUSH_REQUEST_BYTES
  ) {
    throw invalidBirthdayPayload()
  }
  if (!Array.isArray(body.operations)) {
    throw invalidBirthdayPayload()
  }
  if (body.operations.length > MOBILE_API_CONTRACT.limits.pushOperations) {
    throw new MobileSyncValidationError(MOBILE_ERROR_CODES.tooManyOperations)
  }
  if (body.operations.length === 0) throw invalidBirthdayPayload()

  const replayScopeByOperationId = new Map()
  const operations = body.operations.map(operation => {
    if (!isPlainObject(operation)) throw invalidBirthdayPayload()
    const normalizedOperationId = normalizeUUID(operation.operationId)
    const normalizedEntityId = normalizeUUID(operation.entityId)
    const { type } = operation
    if (type !== 'upsert' && type !== 'delete') throw invalidBirthdayPayload()
    const baseVersion = normalizeInt64String(operation.baseVersion)

    const priorScope = replayScopeByOperationId.get(normalizedOperationId)
    if (
      priorScope
      && (
        priorScope.entityId !== normalizedEntityId
        || priorScope.baseVersion !== baseVersion
      )
    ) {
      throw invalidBirthdayPayload()
    }
    replayScopeByOperationId.set(normalizedOperationId, {
      entityId: normalizedEntityId,
      baseVersion,
    })

    if (type === 'delete') {
      if (operation.payload !== undefined && operation.payload !== null) {
        throw invalidBirthdayPayload()
      }
      return markNormalizedOperation({
        operationId: normalizedOperationId,
        entityId: normalizedEntityId,
        type,
        baseVersion,
        payload: null,
      })
    }

    const payload = normalizeBirthdayPayload(operation.payload, dateOptions)
    if (payload.id !== normalizedEntityId) throw invalidBirthdayPayload()
    return markNormalizedOperation({
      operationId: normalizedOperationId,
      entityId: normalizedEntityId,
      type,
      baseVersion,
      payload,
    })
  })

  return { operations }
}

function normalizeCursor(value) {
  if (
    typeof value !== 'string'
    || !DECIMAL_INT64_PATTERN.test(value)
    || BigInt(value) > INT64_MAX
  ) {
    throw new MobileSyncValidationError(MOBILE_ERROR_CODES.invalidCursor)
  }
  return value
}

function normalizeLimit(value = MOBILE_API_CONTRACT.limits.pullDefault) {
  let parsed = value
  if (typeof value === 'string') {
    if (!LIMIT_PATTERN.test(value)) throw new MobileSyncValidationError(MOBILE_ERROR_CODES.invalidLimit)
    parsed = Number(value)
  }
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > MOBILE_API_CONTRACT.limits.pullMaximum) {
    throw new MobileSyncValidationError(MOBILE_ERROR_CODES.invalidLimit)
  }
  return parsed
}

function decimalString(value, fieldName) {
  let normalized = null
  if (typeof value === 'string' && DECIMAL_INT64_PATTERN.test(value)) normalized = value
  if (typeof value === 'bigint' && value >= 0n) normalized = value.toString(10)
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) normalized = String(value)
  if (normalized === null || BigInt(normalized) > INT64_MAX) {
    throw new MobileSyncDataConsistencyError(`${fieldName} is outside signed Int64`)
  }
  return normalized
}

function timeToMinutes(value) {
  const match = typeof value === 'string' ? value.match(TIME_PATTERN) : null
  if (!match) return 9 * 60

  const hour = Number(match[1])
  const minute = Number(match[2])
  const second = match[3] === undefined ? 0 : Number(match[3])
  if (hour > 23 || minute > 59 || second > 59) return 9 * 60
  return hour * 60 + minute
}

function toBoolean(value) {
  return value === true || value === 1 || value === '1'
}

function toISO(value) {
  if (value == null) return null
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : value.toISOString()
  }

  const input = String(value)
  const hasExplicitOffset = /(?:Z|[+-]\d{2}:?\d{2})$/i.test(input)
  if (hasExplicitOffset && !isStrictISO8601Instant(input)) return null
  const parsed = hasExplicitOffset
    ? moment.parseZone(input, moment.ISO_8601, true)
    : moment.tz(
      input,
      [
        'YYYY-MM-DD HH:mm:ss',
        'YYYY-MM-DD HH:mm',
      ],
      true,
      TZ,
    )
  return parsed.isValid() ? parsed.toISOString() : null
}

function emailMessage(row) {
  if (!row.message) return ''
  const message = String(row.message)
  const name = String(row.name || '')
  return name && message.startsWith(name) ? message.slice(name.length) : message
}

function serializeBirthdayRow(row) {
  const record = {
    id: row.id,
    name: row.name,
    lunarMonth: Number(row.lunarMonth),
    lunarDay: Number(row.lunarDay),
    isLeapMonth: toBoolean(row.isLeapMonth),
    reminderTimeMinutes: timeToMinutes(row.remindTime),
    notifyDayBefore: toBoolean(row.notify_day_before),
    notifySameDay: toBoolean(row.notify_same_day),
    emailEnabled: !!row.userEmail,
    emailAddress: row.userEmail || '',
    emailMessage: emailMessage(row),
    nextSolarDate: toISO(row.nextSolarDate),
    version: decimalString(row.version, 'version'),
    createdAt: toISO(row.created_at),
    updatedAt: toISO(row.updated_at),
    deletedAt: toISO(row.deleted_at),
  }
  return validateAPIBirthdayDTO(record)
}

module.exports = {
  INT64_MAX_DECIMAL,
  MAX_PUSH_REQUEST_BYTES,
  MobileSyncDataConsistencyError,
  MobileSyncValidationError,
  assertAPIBirthdayChange,
  decimalString,
  graphemeLength,
  invalidBirthdayPayload,
  isNormalizedPushOperation,
  normalizeBirthdayPayload,
  normalizeCursor,
  normalizeLimit,
  normalizePushRequest,
  serializeBirthdayRow,
  timeToMinutes,
  validateAPIBirthdayDTO,
}
