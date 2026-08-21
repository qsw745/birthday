const moment = require('moment-timezone')
const { calculateNextSolarDate, TZ } = require('./helpers')

const DECIMAL_PATTERN = /^\d+$/
const LIMIT_PATTERN = /^[1-9]\d*$/
const TIME_PATTERN = /^(\d{2}):(\d{2})(?::(\d{2}))?$/
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const UINT64_PATTERN = /^(?:0|[1-9]\d*)$/
const STORAGE_DATE_PATTERN = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/
const UINT64_MAX = 18446744073709551615n
const MAX_TEXT_BYTES = 65535
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

function invalidBirthdayPayload() {
  return new MobileSyncValidationError('invalid_birthday_payload', 'invalid birthday payload')
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

function normalizeUInt64String(value) {
  if (
    typeof value !== 'string'
    || !UINT64_PATTERN.test(value)
    || BigInt(value) > UINT64_MAX
  ) {
    throw invalidBirthdayPayload()
  }
  return value
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

  const name = rawName.trim()
  if (!name || graphemeLength(name) > 64) throw invalidBirthdayPayload()
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

  let emailAddress = rawEmailAddress.trim()
  let emailMessage = rawEmailMessage
  if (emailEnabled) {
    if (
      !emailAddress
      || graphemeLength(emailAddress) > 128
      || !isValidEmailAddress(emailAddress)
      || Buffer.byteLength(`${name}${emailMessage}`, 'utf8') > MAX_TEXT_BYTES
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
  if (!isPlainObject(body) || !Array.isArray(body.operations)) {
    throw invalidBirthdayPayload()
  }
  if (body.operations.length > 50) {
    throw new MobileSyncValidationError('too_many_operations')
  }
  if (body.operations.length === 0) throw invalidBirthdayPayload()

  const entityByOperationId = new Map()
  const operations = body.operations.map(operation => {
    if (!isPlainObject(operation)) throw invalidBirthdayPayload()
    const normalizedOperationId = normalizeUUID(operation.operationId)
    const normalizedEntityId = normalizeUUID(operation.entityId)
    const { type } = operation
    if (type !== 'upsert' && type !== 'delete') throw invalidBirthdayPayload()
    const baseVersion = normalizeUInt64String(operation.baseVersion)

    const priorEntityId = entityByOperationId.get(normalizedOperationId)
    if (priorEntityId && priorEntityId !== normalizedEntityId) throw invalidBirthdayPayload()
    entityByOperationId.set(normalizedOperationId, normalizedEntityId)

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
    || !DECIMAL_PATTERN.test(value)
    || BigInt(value) > UINT64_MAX
  ) {
    throw new MobileSyncValidationError('invalid_cursor')
  }
  return value
}

function normalizeLimit(value = 200) {
  let parsed = value
  if (typeof value === 'string') {
    if (!LIMIT_PATTERN.test(value)) throw new MobileSyncValidationError('invalid_limit')
    parsed = Number(value)
  }
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 200) {
    throw new MobileSyncValidationError('invalid_limit')
  }
  return parsed
}

function decimalString(value, fieldName) {
  if (typeof value === 'string' && DECIMAL_PATTERN.test(value)) return value
  if (typeof value === 'bigint' && value >= 0n) return value.toString(10)
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 0) return String(value)
  throw new TypeError(`${fieldName} must be a lossless nonnegative decimal`)
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
  const parsed = hasExplicitOffset
    ? moment.parseZone(input, moment.ISO_8601, true)
    : moment.tz(
      input,
      [
        'YYYY-MM-DD HH:mm:ss',
        'YYYY-MM-DD HH:mm',
        'YYYY-MM-DDTHH:mm:ss.SSS',
        'YYYY-MM-DDTHH:mm:ss',
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
  return {
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
}

module.exports = {
  MobileSyncValidationError,
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
}
