const moment = require('moment-timezone')
const { TZ } = require('./helpers')

const DECIMAL_PATTERN = /^\d+$/
const LIMIT_PATTERN = /^[1-9]\d*$/
const TIME_PATTERN = /^(\d{2}):(\d{2})(?::(\d{2}))?$/

class MobileSyncValidationError extends Error {
  constructor(code) {
    super(code)
    this.name = 'MobileSyncValidationError'
    this.code = code
  }
}

function normalizeCursor(value) {
  if (typeof value !== 'string' || !DECIMAL_PATTERN.test(value)) {
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
  normalizeCursor,
  normalizeLimit,
  serializeBirthdayRow,
  timeToMinutes,
}
