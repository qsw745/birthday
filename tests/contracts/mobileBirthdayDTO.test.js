const test = require('node:test')
const assert = require('node:assert/strict')
const {
  assertAPIBirthdayChange,
  serializeBirthdayRow,
  validateAPIBirthdayDTO,
} = require('../../utils/mobileSyncContract')

const UUID_V7 = '018f6f7a-b123-7abc-8def-abcdefabcdef'
const INT64_MAX = '9223372036854775807'
const VALID_RFC3339_INSTANTS = [
  '2026-08-22T12:34:56Z',
  '2026-08-22T12:34:56.1Z',
  '2026-08-22T12:34:56.123456789Z',
  '2026-08-22T12:34:56+08:00',
  '2026-08-22T12:34:56.123-03:30',
  '2024-02-29T23:59:59Z',
]
const INVALID_RFC3339_INSTANTS = [
  ' 2026-08-22T12:34:56Z',
  '2026-08-22T12:34:56Z ',
  '2026-08-22 12:34:56Z',
  '2026-08-22T12:34:56 Z',
  '20260822T123456Z',
  '2026-W34-6T12:34:56Z',
  '2026-234T12:34:56Z',
  '2026-08-22T12:34:56',
  '2026-08-22T12:34:56+0800',
  '2026-08-22T12:34:56z',
  '2026-08-22T12:34:56.Z',
  '2026-08-22T24:00:00Z',
  '2026-08-22T12:60:00Z',
  '2026-08-22T12:34:60Z',
  '2026-08-22T12:34:56+24:00',
  '2026-08-22T12:34:56+08:60',
  '2023-02-29T12:34:56Z',
  '2024-02-30T12:34:56Z',
  '2026-13-01T12:34:56Z',
]

function validDTO(overrides = {}) {
  return {
    id: UUID_V7,
    name: '妈妈',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    reminderTimeMinutes: 540,
    notifyDayBefore: true,
    notifySameDay: false,
    emailEnabled: true,
    emailAddress: 'mom@example.com',
    emailMessage: '生日快乐',
    nextSolarDate: null,
    version: INT64_MAX,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-08-22T12:00:00+08:00',
    deletedAt: null,
    ...overrides,
  }
}

function corrupt(mutator) {
  const dto = validDTO()
  mutator(dto)
  return dto
}

function isConsistencyError(error) {
  return error.name === 'MobileSyncDataConsistencyError'
    && error.code === 'mobile_sync_inconsistent_state'
}

test('complete APIBirthday validator accepts UUIDv7, signed Int64 maximum, and nullable next date', () => {
  const dto = validDTO()

  assert.equal(validateAPIBirthdayDTO(dto), dto)
  assert.equal(assertAPIBirthdayChange({
    entityId: UUID_V7,
    operation: 'upsert',
    entityVersion: INT64_MAX,
    record: dto,
  }), dto)
})

test('complete APIBirthday validator accepts a valid tombstone and disabled email canonical empties', () => {
  const dto = validDTO({
    emailEnabled: false,
    emailAddress: '',
    emailMessage: '',
    deletedAt: '2026-08-22T12:00:00.123Z',
  })

  assert.equal(validateAPIBirthdayDTO(dto), dto)
  assert.equal(assertAPIBirthdayChange({
    entityId: UUID_V7,
    operation: 'delete',
    entityVersion: INT64_MAX,
    record: dto,
  }), dto)
})

test('complete APIBirthday validator applies the shared Unicode trim semantics to name and enabled email', () => {
  const dto = validDTO({
    name: '\u0085妈妈\u0085',
    emailAddress: '\u0085mom@example.com\u0085',
  })

  assert.equal(validateAPIBirthdayDTO(dto), dto)
})

test('complete APIBirthday validator accepts only the RFC3339 instant forms decoded by Plan3 MobileJSON', () => {
  for (const value of VALID_RFC3339_INSTANTS) {
    const dto = validDTO({
      nextSolarDate: value,
      createdAt: value,
      updatedAt: value,
      deletedAt: value,
    })
    assert.equal(validateAPIBirthdayDTO(dto), dto, value)
  }
})

for (const value of INVALID_RFC3339_INSTANTS) {
  test(`complete APIBirthday validator rejects non-RFC3339 instant ${JSON.stringify(value)}`, () => {
    assert.throws(
      () => validateAPIBirthdayDTO(validDTO({ createdAt: value })),
      isConsistencyError,
    )
  })
}

const invalidDTOCases = [
  ['missing field', corrupt(dto => { delete dto.emailMessage })],
  ['extra field', { ...validDTO(), internalOnly: true }],
  ['invalid UUID', validDTO({ id: 'not-a-uuid' })],
  ['numeric name', validDTO({ name: 42 })],
  ['blank name after Unicode trimming', validDTO({ name: '\u0085\t ' })],
  ['name beyond scalar and grapheme limit', validDTO({ name: '人'.repeat(65) })],
  ['lunar month below range', validDTO({ lunarMonth: 0 })],
  ['lunar month above range', validDTO({ lunarMonth: 13 })],
  ['fractional lunar day', validDTO({ lunarDay: 15.5 })],
  ['lunar day above range', validDTO({ lunarDay: 31 })],
  ['string leap-month flag', validDTO({ isLeapMonth: 'false' })],
  ['string notification flag', validDTO({ notifySameDay: 'false' })],
  ['string email flag', validDTO({ emailEnabled: 'true' })],
  ['all notification channels disabled', validDTO({ notifyDayBefore: false, notifySameDay: false })],
  ['negative reminder minute', validDTO({ reminderTimeMinutes: -1 })],
  ['reminder minute above range', validDTO({ reminderTimeMinutes: 1440 })],
  ['fractional reminder minute', validDTO({ reminderTimeMinutes: 1.5 })],
  ['enabled email with malformed address', validDTO({ emailAddress: 'a@@b' })],
  ['enabled email with non-string message', validDTO({ emailMessage: 42 })],
  ['enabled email over storage limit', validDTO({ name: 'M', emailMessage: 'x'.repeat(8192) })],
  ['disabled email retaining address', validDTO({ emailEnabled: false, emailMessage: '', emailAddress: 'a@b' })],
  ['disabled email retaining message', validDTO({ emailEnabled: false, emailAddress: '', emailMessage: 'unused' })],
  ['invalid next date suffix', validDTO({ nextSolarDate: '2026-08-22T12:00:00Zjunk' })],
  ['invalid next date offset', validDTO({ nextSolarDate: '2026-08-22T12:00:00+08:99' })],
  ['numeric next date', validDTO({ nextSolarDate: 0 })],
  ['numeric version', validDTO({ version: 1 })],
  ['noncanonical version', validDTO({ version: '01' })],
  ['version above signed Int64', validDTO({ version: '9223372036854775808' })],
  ['null created date', validDTO({ createdAt: null })],
  ['invalid created date', validDTO({ createdAt: '2026-02-30T00:00:00Z' })],
  ['invalid updated date suffix', validDTO({ updatedAt: '2026-08-22T12:00:00Z trailing' })],
  ['numeric deleted date', validDTO({ deletedAt: 0 })],
  ['invalid deleted date', validDTO({ deletedAt: '2026-13-01T00:00:00Z' })],
]

for (const [name, dto] of invalidDTOCases) {
  test(`complete APIBirthday validator rejects ${name}`, () => {
    assert.throws(() => validateAPIBirthdayDTO(dto), isConsistencyError)
  })
}

for (const [name, change] of [
  ['invalid entity UUID even when the record id matches', {
    entityId: 'not-a-uuid',
    operation: 'upsert',
    entityVersion: '1',
    record: validDTO({ id: 'not-a-uuid', version: '1' }),
  }],
  ['entity id mismatch', {
    entityId: '11111111-1111-4111-8111-111111111111',
    operation: 'upsert',
    entityVersion: INT64_MAX,
    record: validDTO(),
  }],
  ['entity version mismatch', {
    entityId: UUID_V7,
    operation: 'upsert',
    entityVersion: '1',
    record: validDTO(),
  }],
  ['noncanonical entity version', {
    entityId: UUID_V7,
    operation: 'upsert',
    entityVersion: '01',
    record: validDTO({ version: '01' }),
  }],
  ['unknown operation', {
    entityId: UUID_V7,
    operation: 'restore',
    entityVersion: INT64_MAX,
    record: validDTO(),
  }],
  ['upsert tombstone', {
    entityId: UUID_V7,
    operation: 'upsert',
    entityVersion: INT64_MAX,
    record: validDTO({ deletedAt: '2026-08-22T12:00:00Z' }),
  }],
  ['delete without tombstone', {
    entityId: UUID_V7,
    operation: 'delete',
    entityVersion: INT64_MAX,
    record: validDTO(),
  }],
  ['delete retaining an enabled email snapshot', {
    entityId: UUID_V7,
    operation: 'delete',
    entityVersion: INT64_MAX,
    record: validDTO({ deletedAt: '2026-08-22T12:00:00Z' }),
  }],
]) {
  test(`change assertion rejects ${name}`, () => {
    assert.throws(() => assertAPIBirthdayChange(change), isConsistencyError)
  })
}

test('database serializer validates its complete DTO before returning it', () => {
  const validRow = {
    id: UUID_V7,
    name: '妈妈',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: 0,
    remindTime: '09:00:00',
    nextSolarDate: null,
    version: INT64_MAX,
    deleted_at: null,
    notify_day_before: 1,
    notify_same_day: 0,
    created_at: '2026-01-01 00:00:00',
    updated_at: '2026-08-22 12:00:00',
    userEmail: null,
    message: null,
  }

  assert.equal(serializeBirthdayRow(validRow).version, INT64_MAX)
  for (const row of [
    { ...validRow, id: 'not-a-uuid' },
    { ...validRow, name: 42 },
    { ...validRow, lunarMonth: 0 },
    { ...validRow, notify_day_before: 0, notify_same_day: 0 },
    { ...validRow, created_at: 'not-a-date' },
    { ...validRow, userEmail: 'a@@b', message: '妈妈message' },
  ]) {
    assert.throws(() => serializeBirthdayRow(row), isConsistencyError)
  }
})

test('database serializer emits Date.toISOString milliseconds and rejects explicit non-RFC3339 inputs', () => {
  const validRow = {
    id: UUID_V7,
    name: '妈妈',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: 0,
    remindTime: '09:00:00',
    nextSolarDate: new Date('2026-09-25T01:00:00.000Z'),
    version: '1',
    deleted_at: null,
    notify_day_before: 1,
    notify_same_day: 0,
    created_at: new Date('2026-01-01T00:00:00.000Z'),
    updated_at: new Date('2026-08-22T04:00:00.000Z'),
    userEmail: null,
    message: null,
  }

  const dto = serializeBirthdayRow(validRow)
  assert.equal(dto.nextSolarDate, '2026-09-25T01:00:00.000Z')
  assert.equal(dto.createdAt, '2026-01-01T00:00:00.000Z')
  assert.equal(dto.updatedAt, '2026-08-22T04:00:00.000Z')

  for (const createdAt of VALID_RFC3339_INSTANTS) {
    const serialized = serializeBirthdayRow({ ...validRow, created_at: createdAt })
    assert.equal(validateAPIBirthdayDTO(serialized), serialized, createdAt)
  }

  for (const createdAt of INVALID_RFC3339_INSTANTS) {
    assert.throws(
      () => serializeBirthdayRow({ ...validRow, created_at: createdAt }),
      isConsistencyError,
      createdAt,
    )
  }
})
