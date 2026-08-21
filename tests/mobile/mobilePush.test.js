const test = require('node:test')
const assert = require('node:assert/strict')
const request = require('supertest')
const { createTestApp } = require('../helpers/createTestApp')
const {
  DEFAULT_BIRTHDAY_ID: BIRTHDAY_ID,
  DEFAULT_DEVICE_ID: DEVICE_ID,
  FakeDatabase,
  FakePool,
  birthdayRow,
  reminderRow,
  validPayload,
} = require('../helpers/fakeConnection')
const {
  graphemeLength,
  normalizeBirthdayPayload,
  normalizePushRequest,
} = require('../../utils/mobileSyncContract')
const { createMobileSyncRepository } = require('../../repositories/mobileSyncRepository')
const { createMobileSyncRouter } = require('../../routes/mobileSync')
const { applyMobileOperation } = require('../../services/birthdayMutationService')

const SECOND_BIRTHDAY_ID = '44444444-4444-4444-8444-444444444444'
const OPERATION_ID = '33333333-3333-4333-8333-333333333333'
const SECOND_OPERATION_ID = '55555555-5555-4555-8555-555555555555'
const ACCESS_TOKEN = 'opaque-access-token'

function operation(overrides = {}) {
  return {
    operationId: OPERATION_ID,
    entityId: BIRTHDAY_ID,
    type: 'upsert',
    baseVersion: '0',
    payload: validPayload(),
    ...overrides,
  }
}

function createRepository(database, options = {}) {
  return createMobileSyncRepository({ pool: new FakePool(database), ...options })
}

function injectedAuth(req, res, next) {
  req.mobileSession = { device_id: DEVICE_ID, username: 'admin' }
  next()
}

function createPushApp(options = {}, { errorHandler = false } = {}) {
  const mobileAuth = Object.hasOwn(options, 'mobileAuth') ? options.mobileAuth : injectedAuth
  const router = createMobileSyncRouter({
    syncRepository: options.repository,
    mobileAuth,
    sessions: options.sessions,
    calculateNextSolarDateFn: options.calculateNextSolarDateFn,
  })
  const app = createTestApp({ path: '/api/mobile/sync', router })
  if (errorHandler) {
    app.use((error, req, res, next) => {
      res.status(503).json({ error: 'server_error' })
    })
  }
  return app
}

test('strict payload normalization rejects coercions and preserves the exact birthday field contract', () => {
  const normalized = normalizeBirthdayPayload(validPayload({
    name: '  妈妈  ',
    emailEnabled: true,
    emailAddress: ' mom@example.com ',
  }))
  assert.deepEqual(normalized, {
    ...validPayload({
      name: '妈妈',
      emailEnabled: true,
      emailAddress: 'mom@example.com',
    }),
    remindTime: '09:00:00',
    nextSolarDate: normalized.nextSolarDate,
  })

  for (const payload of [
    validPayload({ lunarMonth: '8' }),
    validPayload({ lunarDay: true }),
    validPayload({ reminderTimeMinutes: '540' }),
    validPayload({ isLeapMonth: 0 }),
    validPayload({ notifyDayBefore: 1 }),
    validPayload({ emailEnabled: 'false' }),
    validPayload({ emailAddress: false }),
    validPayload({ emailMessage: null }),
  ]) {
    assert.throws(
      () => normalizeBirthdayPayload(payload),
      error => error.code === 'invalid_birthday_payload',
    )
  }
})

test('push normalization accepts Swift-style uppercase UUID JSON and canonicalizes every identifier', () => {
  const operationId = 'ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF'
  const entityId = 'ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDF0'
  const normalized = normalizePushRequest({ operations: [operation({
    operationId,
    entityId,
    payload: validPayload({ id: entityId }),
  })] })

  assert.equal(normalized.operations[0].operationId, operationId.toLowerCase())
  assert.equal(normalized.operations[0].entityId, entityId.toLowerCase())
  assert.equal(normalized.operations[0].payload.id, entityId.toLowerCase())
})

test('semantic normalization finds the next real lunar day 30 instead of failing on the current short month', () => {
  const normalized = normalizePushRequest({ operations: [operation({
    payload: validPayload({ lunarMonth: 2, lunarDay: 30 }),
  })] }, { nowInput: '2026-08-22T12:00:00+08:00' })

  assert.equal(normalized.operations[0].payload.nextSolarDate, '2028-03-25 09:00:00')
})

test('server validation matches iOS for trimmed minimal email addresses and common whitespace', () => {
  for (const { name, emailAddress } of [
    { name: '妈妈', emailAddress: 'a@b' },
    { name: '\t\n妈妈\r ', emailAddress: ' \t a@b \n' },
  ]) {
    const normalized = normalizeBirthdayPayload(validPayload({
      name,
      emailEnabled: true,
      emailAddress,
    }))
    assert.equal(normalized.name, '妈妈')
    assert.equal(normalized.emailAddress, 'a@b')
  }

  for (const emailAddress of ['@b', 'a@', 'a@@b']) {
    assert.throws(
      () => normalizeBirthdayPayload(validPayload({ emailEnabled: true, emailAddress })),
      error => error.code === 'invalid_birthday_payload',
    )
  }
})

test('server name and email limits count extended grapheme clusters like Swift String.count', () => {
  const combining = 'e\u0301'
  const family = '👨‍👩‍👧‍👦'
  for (const name of [combining.repeat(64), family.repeat(64)]) {
    assert.equal(graphemeLength(name), 64)
    assert.doesNotThrow(() => normalizeBirthdayPayload(validPayload({ name })))
  }
  for (const name of [combining.repeat(65), family.repeat(65)]) {
    assert.equal(graphemeLength(name), 65)
    assert.throws(
      () => normalizeBirthdayPayload(validPayload({ name })),
      error => error.code === 'invalid_birthday_payload',
    )
  }

  const email128 = `${combining.repeat(126)}@b`
  const email129 = `${combining.repeat(127)}@b`
  assert.equal(graphemeLength(email128), 128)
  assert.equal(graphemeLength(email129), 129)
  assert.doesNotThrow(() => normalizeBirthdayPayload(validPayload({
    emailEnabled: true,
    emailAddress: email128,
  })))
  assert.throws(
    () => normalizeBirthdayPayload(validPayload({
      emailEnabled: true,
      emailAddress: email129,
    })),
    error => error.code === 'invalid_birthday_payload',
  )
})

test('server fails explicitly if Intl.Segmenter is unavailable', () => {
  assert.throws(
    () => graphemeLength('妈妈', null),
    error => error.code === 'grapheme_segmenter_unavailable',
  )
})

test('email message TEXT limit matches the iOS UTF-8 contract only while email is enabled', () => {
  assert.doesNotThrow(() => normalizeBirthdayPayload(validPayload({
    name: 'M',
    emailEnabled: true,
    emailAddress: 'a@b',
    emailMessage: 'a'.repeat(65534),
  })))
  assert.throws(
    () => normalizeBirthdayPayload(validPayload({
      name: 'M',
      emailEnabled: true,
      emailAddress: 'a@b',
      emailMessage: 'a'.repeat(65535),
    })),
    error => error.code === 'invalid_birthday_payload',
  )
  assert.doesNotThrow(() => normalizeBirthdayPayload(validPayload({
    name: 'M',
    emailEnabled: false,
    emailMessage: '🎂'.repeat(20000),
  })))
})

test('payload validation enforces remaining field ranges and disabled-email clearing', () => {
  for (const payload of [
    validPayload({ name: '人'.repeat(65) }),
    validPayload({ emailEnabled: true, emailAddress: `${'a'.repeat(117)}@example.com` }),
    validPayload({ lunarMonth: 13 }),
    validPayload({ lunarDay: 31 }),
    validPayload({ reminderTimeMinutes: 1440 }),
    validPayload({ notifyDayBefore: false, notifySameDay: false }),
  ]) {
    assert.throws(
      () => normalizeBirthdayPayload(payload),
      error => error.code === 'invalid_birthday_payload',
    )
  }

  const disabled = normalizeBirthdayPayload(validPayload({
    emailEnabled: false,
    emailAddress: 'not-an-email',
    emailMessage: 'unused',
  }))
  assert.equal(disabled.emailAddress, '')
  assert.equal(disabled.emailMessage, '')
})

test('whole request envelope is validated before any operation transaction starts', async () => {
  const database = new FakeDatabase()
  const pool = new FakePool(database)
  const repository = createMobileSyncRepository({ pool })
  const app = createPushApp({ repository })
  const response = await request(app)
    .post('/api/mobile/sync/push')
    .send({
      operations: [
        operation(),
        operation({
          operationId: SECOND_OPERATION_ID,
          entityId: SECOND_BIRTHDAY_ID,
          payload: validPayload({ id: SECOND_BIRTHDAY_ID, lunarMonth: '9' }),
        }),
      ],
    })

  assert.equal(response.status, 400)
  assert.deepEqual(response.body, { error: 'invalid_birthday_payload' })
  assert.equal(pool.getConnectionCalls, 0)
  assert.equal(database.state.birthdays.size, 0)
  assert.equal(database.state.changes.length, 0)
})

test('all semantic birthday dates are calculated before the first transaction and failures return invalid_birthday_payload', async () => {
  const database = new FakeDatabase()
  const pool = new FakePool(database)
  const repository = createMobileSyncRepository({ pool })
  const calculateCalls = []
  const app = createPushApp({
    repository,
    calculateNextSolarDateFn(payload) {
      calculateCalls.push(payload.lunarMonth)
      if (payload.lunarMonth === 2) throw new Error('semantic lunar date failure')
      return '2026-09-25 09:00:00'
    },
  })
  const response = await request(app)
    .post('/api/mobile/sync/push')
    .send({ operations: [
      operation(),
      operation({
        operationId: SECOND_OPERATION_ID,
        entityId: SECOND_BIRTHDAY_ID,
        payload: validPayload({ id: SECOND_BIRTHDAY_ID, lunarMonth: 2 }),
      }),
    ] })

  assert.equal(response.status, 400)
  assert.deepEqual(response.body, { error: 'invalid_birthday_payload' })
  assert.ok(calculateCalls.includes(8))
  assert.ok(calculateCalls.includes(2))
  assert.equal(pool.getConnectionCalls, 0)
  assert.equal(database.state.birthdays.size, 0)
  assert.equal(database.state.changes.length, 0)
})

test('request envelope requires 1...50 operations, canonical UUIDs, UInt64 string versions, matching payload IDs, and no delete payload', () => {
  const invalidRequests = [
    null,
    {},
    { operations: [] },
    { operations: {} },
    { operations: [operation({ operationId: 'not-a-uuid' })] },
    { operations: [operation({ entityId: 'not-a-uuid' })] },
    { operations: [operation({ type: 'patch' })] },
    { operations: [operation({ baseVersion: 0 })] },
    { operations: [operation({ baseVersion: '-1' })] },
    { operations: [operation({ baseVersion: '01' })] },
    { operations: [operation({ baseVersion: '18446744073709551616' })] },
    { operations: [operation({ payload: validPayload({ id: SECOND_BIRTHDAY_ID }) })] },
    { operations: [operation({ type: 'delete', payload: validPayload() })] },
    { operations: [operation({ type: 'upsert', payload: null })] },
    { operations: [
      operation(),
      operation({ entityId: SECOND_BIRTHDAY_ID, payload: validPayload({ id: SECOND_BIRTHDAY_ID }) }),
    ] },
  ]

  for (const body of invalidRequests) {
    assert.throws(
      () => normalizePushRequest(body),
      error => error.code === 'invalid_birthday_payload',
    )
  }
  assert.throws(
    () => normalizePushRequest({ operations: Array.from({ length: 51 }, (_, index) => operation({
      operationId: `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
    })) }),
    error => error.code === 'too_many_operations',
  )
})

test('new upsert atomically inserts birthday, one email reminder, one change, and its stored response', async () => {
  const database = new FakeDatabase()
  const repository = createRepository(database)
  const result = await repository.applyOperation(DEVICE_ID, operation({
    payload: validPayload({
      emailEnabled: true,
      emailAddress: 'mom@example.com',
      emailMessage: '生日快乐',
    }),
  }))

  assert.equal(result.status, 'applied')
  assert.equal(result.record.id, BIRTHDAY_ID)
  assert.equal(result.record.version, '1')
  assert.equal(result.record.emailEnabled, true)
  assert.equal(database.birthday(BIRTHDAY_ID).deleted_at, null)
  assert.deepEqual(database.reminder(BIRTHDAY_ID), {
    id: database.reminder(BIRTHDAY_ID).id,
    birthday_id: BIRTHDAY_ID,
    name: '妈妈',
    email: 'mom@example.com',
    remind_time: '2026-09-25 09:00:00',
    message: '妈妈生日快乐',
    status: 0,
  })
  assert.deepEqual(database.state.changes.map(change => ({
    entity_id: change.entity_id,
    operation: change.operation,
    version: change.version,
  })), [{ entity_id: BIRTHDAY_ID, operation: 'upsert', version: '1' }])
  assert.deepEqual(database.operation(OPERATION_ID).response_json, result)
  assert.deepEqual(database.connections[0].lifecycle, ['begin', 'commit', 'release'])
})

test('applyMobileOperation accepts the documented raw operation inside its caller-owned transaction', async () => {
  const database = new FakeDatabase()
  const connection = database.createConnection()
  await connection.beginTransaction()
  const result = await applyMobileOperation(connection, {
    deviceId: DEVICE_ID,
    operation: operation(),
  })
  await connection.commit()

  assert.equal(result.status, 'applied')
  assert.equal(database.birthday(BIRTHDAY_ID).remindTime, '09:00:00')
})

test('FakeConnection rejects a first birthday read that omits FOR UPDATE', async () => {
  const database = new FakeDatabase({ birthdays: [birthdayRow()] })
  const connection = database.createConnection()
  await connection.beginTransaction()

  await assert.rejects(
    connection.query(
      `SELECT b.id
         FROM birthdays b
         LEFT JOIN email_reminders r ON r.birthday_id = b.id
        WHERE b.id = ?`,
      [BIRTHDAY_ID],
    ),
    /FOR UPDATE/,
  )
  await connection.rollback()
})

test('concurrent updates to one existing birthday serialize so only one baseVersion applies', async () => {
  const database = new FakeDatabase({ birthdays: [birthdayRow({ version: '1' })] })
  const repository = createRepository(database)
  const first = operation({
    baseVersion: '1',
    payload: validPayload({ name: '第一项' }),
  })
  const second = operation({
    operationId: SECOND_OPERATION_ID,
    baseVersion: '1',
    payload: validPayload({ name: '第二项' }),
  })

  const results = await Promise.all([
    repository.applyOperation(DEVICE_ID, first),
    repository.applyOperation(DEVICE_ID, second),
  ])

  assert.deepEqual(results.map(result => result.status).sort(), ['applied', 'conflict'])
  const applied = results.find(result => result.status === 'applied')
  assert.equal(database.birthday(BIRTHDAY_ID).name, applied.record.name)
  assert.equal(database.birthday(BIRTHDAY_ID).version, '2')
  assert.equal(database.state.changes.length, 1)
  assert.equal(database.state.operations.size, 2)
})

test('concurrent creates for one missing birthday serialize the gap so only one applies', async () => {
  const database = new FakeDatabase()
  const repository = createRepository(database)
  const results = await Promise.all([
    repository.applyOperation(DEVICE_ID, operation({ payload: validPayload({ name: '第一项' }) })),
    repository.applyOperation(DEVICE_ID, operation({
      operationId: SECOND_OPERATION_ID,
      payload: validPayload({ name: '第二项' }),
    })),
  ])

  assert.deepEqual(results.map(result => result.status).sort(), ['applied', 'conflict'])
  assert.equal(database.birthday(BIRTHDAY_ID).version, '1')
  assert.equal(database.state.changes.length, 1)
  assert.equal(database.state.operations.size, 2)
})

test('a duplicate-key error from a business INSERT is never recovered as operation idempotency', async () => {
  const database = new FakeDatabase()
  const duplicate = Object.assign(new Error('birthday uniqueness failed'), { code: 'ER_DUP_ENTRY' })
  database.failNext(/^INSERT INTO birthdays /, duplicate)
  const pool = new FakePool(database)
  const repository = createMobileSyncRepository({ pool })

  await assert.rejects(
    repository.applyOperation(DEVICE_ID, operation()),
    error => error === duplicate && error.mobileOperationResponseDuplicate !== true,
  )
  assert.equal(pool.getConnectionCalls, 1)
  assert.equal(database.birthday(BIRTHDAY_ID), null)
  assert.equal(database.operation(OPERATION_ID), null)
})

test('upsert updates an active birthday and disabling email removes its unique reminder in the same transaction', async () => {
  const database = new FakeDatabase({
    birthdays: [birthdayRow({ version: '7' })],
    reminders: [reminderRow()],
  })
  const result = await createRepository(database).applyOperation(DEVICE_ID, operation({
    baseVersion: '7',
    payload: validPayload({ name: '母亲', emailEnabled: false, emailAddress: 'old@example.com' }),
  }))

  assert.equal(result.record.name, '母亲')
  assert.equal(result.record.version, '8')
  assert.equal(result.record.emailEnabled, false)
  assert.equal(result.record.emailAddress, '')
  assert.equal(database.birthday(BIRTHDAY_ID).version, '8')
  assert.equal(database.reminder(BIRTHDAY_ID), null)
  assert.equal(database.state.changes.length, 1)
})

test('enabled email update preserves one reminder, replaces its content, and resets delivery status', async () => {
  const originalReminder = reminderRow({ email: 'old@example.com', status: 1 })
  const database = new FakeDatabase({
    birthdays: [birthdayRow({ version: '3' })],
    reminders: [originalReminder],
  })
  const result = await createRepository(database).applyOperation(DEVICE_ID, operation({
    baseVersion: '3',
    payload: validPayload({
      emailEnabled: true,
      emailAddress: 'new@example.com',
      emailMessage: '新的祝福',
    }),
  }))

  const reminder = database.reminder(BIRTHDAY_ID)
  assert.equal(database.state.reminders.size, 1)
  assert.equal(reminder.id, originalReminder.id)
  assert.equal(reminder.email, 'new@example.com')
  assert.equal(reminder.message, '妈妈新的祝福')
  assert.equal(reminder.status, 0)
  assert.equal(result.record.emailAddress, 'new@example.com')
  assert.equal(result.record.emailMessage, '新的祝福')
})

test('upsert restores a tombstone and recreates exactly one enabled email reminder', async () => {
  const database = new FakeDatabase({
    birthdays: [birthdayRow({ version: '5', deleted_at: '2026-08-20 10:00:00' })],
  })
  const repository = createRepository(database)
  const result = await repository.applyOperation(DEVICE_ID, operation({
    baseVersion: '5',
    payload: validPayload({ emailEnabled: true, emailAddress: 'mom@example.com' }),
  }))

  assert.equal(result.record.version, '6')
  assert.equal(result.record.deletedAt, null)
  assert.equal(database.birthday(BIRTHDAY_ID).deleted_at, null)
  assert.equal(database.state.reminders.size, 1)
  assert.equal(database.state.changes.length, 1)
})

test('birthday versions above Number.MAX_SAFE_INTEGER increment and bind as exact decimal strings', async () => {
  const database = new FakeDatabase({
    birthdays: [birthdayRow({ version: '9007199254740993' })],
  })
  const result = await createRepository(database).applyOperation(DEVICE_ID, operation({
    baseVersion: '9007199254740993',
  }))

  assert.equal(result.record.version, '9007199254740994')
  assert.equal(database.birthday(BIRTHDAY_ID).version, '9007199254740994')
  const update = database.connections[0].queries.find(entry => /^UPDATE birthdays SET name/.test(entry.sql))
  assert.equal(update.params[6], '9007199254740994')
  assert.equal(database.state.changes[0].version, '9007199254740994')
})

test('delete keeps a versioned birthday tombstone, removes its reminder, and appends one delete change', async () => {
  const database = new FakeDatabase({
    birthdays: [birthdayRow({ version: '2' })],
    reminders: [reminderRow()],
  })
  const result = await createRepository(database).applyOperation(DEVICE_ID, operation({
    type: 'delete',
    baseVersion: '2',
    payload: undefined,
  }))

  assert.equal(result.status, 'applied')
  assert.equal(result.record.version, '3')
  assert.ok(result.record.deletedAt)
  assert.ok(database.birthday(BIRTHDAY_ID))
  assert.equal(database.reminder(BIRTHDAY_ID), null)
  assert.deepEqual(database.state.changes.map(change => change.operation), ['delete'])
})

test('version mismatch persists a conflict response without birthday, reminder, or change mutation', async () => {
  const originalBirthday = birthdayRow({ version: '5' })
  const originalReminder = reminderRow()
  const database = new FakeDatabase({
    birthdays: [originalBirthday],
    reminders: [originalReminder],
  })
  const result = await createRepository(database).applyOperation(DEVICE_ID, operation({ baseVersion: '4' }))

  assert.equal(result.status, 'conflict')
  assert.equal(result.remote.version, '5')
  assert.deepEqual(database.birthday(BIRTHDAY_ID), originalBirthday)
  assert.deepEqual(database.reminder(BIRTHDAY_ID), originalReminder)
  assert.equal(database.state.changes.length, 0)
  assert.deepEqual(database.operation(OPERATION_ID).response_json, result)
  assert.deepEqual(database.connections[0].lifecycle, ['begin', 'commit', 'release'])
})

test('a stale operation for a missing UUID is rejected as inconsistent instead of storing an unscoped replay response', async () => {
  const database = new FakeDatabase()
  await assert.rejects(
    createRepository(database).applyOperation(DEVICE_ID, operation({ baseVersion: '9' })),
    error => error.code === 'mobile_sync_inconsistent_state',
  )

  assert.equal(database.operation(OPERATION_ID), null)
  assert.equal(database.state.changes.length, 0)
  assert.deepEqual(database.connections[0].lifecycle, ['begin', 'rollback', 'release'])
})

test('replay returns the exact stored JSON and performs no birthday, reminder, or change write', async () => {
  const stored = {
    operationId: OPERATION_ID,
    status: 'applied',
    record: { id: BIRTHDAY_ID, version: '2' },
  }
  const database = new FakeDatabase({ operations: [{
    operation_id: OPERATION_ID,
    device_id: DEVICE_ID,
    entity_id: BIRTHDAY_ID,
    response_json: stored,
  }] })
  const result = await createRepository(database).applyOperation(DEVICE_ID, operation({ baseVersion: '999' }))

  assert.deepEqual(result, stored)
  assert.equal(database.state.birthdays.size, 0)
  assert.equal(database.state.reminders.size, 0)
  assert.equal(database.state.changes.length, 0)
  assert.equal(database.connections[0].queries.length, 1)
  assert.deepEqual(database.connections[0].lifecycle, ['begin', 'commit', 'release'])
})

test('stored operation IDs cannot be replayed across devices or entities', async () => {
  for (const { deviceId, entityId } of [
    { deviceId: '66666666-6666-4666-8666-666666666666', entityId: BIRTHDAY_ID },
    { deviceId: DEVICE_ID, entityId: SECOND_BIRTHDAY_ID },
  ]) {
    const stored = {
      operationId: OPERATION_ID,
      status: 'applied',
      record: { id: BIRTHDAY_ID, version: '2' },
    }
    const database = new FakeDatabase({ operations: [{
      operation_id: OPERATION_ID,
      device_id: DEVICE_ID,
      entity_id: BIRTHDAY_ID,
      response_json: stored,
    }] })
    await assert.rejects(
      createRepository(database).applyOperation(deviceId, operation({
        entityId,
        payload: validPayload({ id: entityId }),
      })),
      error => error.code === 'invalid_birthday_payload',
    )
    assert.deepEqual(database.connections[0].lifecycle, ['begin', 'rollback', 'release'])
  }
})

test('push handles each valid operation in order and a conflict does not roll back another item', async () => {
  const database = new FakeDatabase({ birthdays: [birthdayRow({ version: '5' })] })
  const pool = new FakePool(database)
  const repository = createMobileSyncRepository({ pool })
  const app = createPushApp({ repository })
  const response = await request(app)
    .post('/api/mobile/sync/push')
    .send({ operations: [
      operation({ baseVersion: '4' }),
      operation({
        operationId: SECOND_OPERATION_ID,
        entityId: SECOND_BIRTHDAY_ID,
        payload: validPayload({ id: SECOND_BIRTHDAY_ID, name: '爸爸' }),
      }),
    ] })

  assert.equal(response.status, 200)
  assert.deepEqual(response.body.results.map(result => result.status), ['conflict', 'applied'])
  assert.equal(pool.getConnectionCalls, 2)
  assert.ok(database.birthday(SECOND_BIRTHDAY_ID))
  assert.equal(database.state.changes.length, 1)
  assert.deepEqual(database.connections.map(connection => connection.lifecycle), [
    ['begin', 'commit', 'release'],
    ['begin', 'commit', 'release'],
  ])
})

test('duplicate operation IDs in one batch preserve order and replay the first baseVersion result', async () => {
  const database = new FakeDatabase()
  const pool = new FakePool(database)
  const repository = createMobileSyncRepository({ pool })
  const app = createPushApp({ repository })
  const response = await request(app)
    .post('/api/mobile/sync/push')
    .send({ operations: [operation(), operation({ baseVersion: '18446744073709551615' })] })

  assert.equal(response.status, 200)
  assert.deepEqual(response.body.results[1], response.body.results[0])
  assert.equal(response.body.results[0].record.version, '1')
  assert.equal(pool.getConnectionCalls, 2)
  assert.equal(database.state.changes.length, 1)
  assert.equal(database.connections[1].queries.length, 1)
})

test('51 operations returns the exact too_many_operations error without opening a connection', async () => {
  const database = new FakeDatabase()
  const pool = new FakePool(database)
  const app = createPushApp({ repository: createMobileSyncRepository({ pool }) })
  const operations = Array.from({ length: 51 }, (_, index) => operation({
    operationId: `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
  }))
  const response = await request(app).post('/api/mobile/sync/push').send({ operations })

  assert.equal(response.status, 400)
  assert.deepEqual(response.body, { error: 'too_many_operations' })
  assert.equal(pool.getConnectionCalls, 0)
})

test('transaction failures roll back all staged business writes, release the connection, and reach Express error handling', async () => {
  const database = new FakeDatabase()
  const failure = new Error('change insert failed')
  database.failNext(/^INSERT INTO mobile_sync_changes /, failure)
  const pool = new FakePool(database)
  const repository = createMobileSyncRepository({ pool })
  const app = createPushApp({ repository }, { errorHandler: true })
  const response = await request(app).post('/api/mobile/sync/push').send({ operations: [operation()] })

  assert.equal(response.status, 503)
  assert.deepEqual(response.body, { error: 'server_error' })
  assert.equal(database.birthday(BIRTHDAY_ID), null)
  assert.equal(database.state.changes.length, 0)
  assert.deepEqual(database.connections[0].lifecycle, ['begin', 'rollback', 'release'])
})

test('begin and commit failures preserve the primary error, roll back, and release a healthy connection', async () => {
  for (const failurePoint of ['beginTransaction', 'commit']) {
    const database = new FakeDatabase()
    const primary = Object.assign(new Error(`${failurePoint} failed`), {
      code: failurePoint === 'commit' ? 'ER_COMMIT' : 'ER_BEGIN',
    })
    const pool = {
      async getConnection() {
        const connection = database.createConnection()
        if (failurePoint === 'beginTransaction') {
          connection.beginTransaction = async function beginFailure() {
            this.lifecycle.push('begin')
            throw primary
          }
        } else {
          connection.commit = async function commitFailure() {
            this.lifecycle.push('commit')
            throw primary
          }
        }
        return connection
      },
    }

    await assert.rejects(
      createMobileSyncRepository({ pool }).applyOperation(DEVICE_ID, operation()),
      error => error === primary,
    )
    assert.deepEqual(
      database.connections[0].lifecycle,
      failurePoint === 'beginTransaction'
        ? ['begin', 'rollback', 'release']
        : ['begin', 'commit', 'rollback', 'release'],
    )
    assert.equal(database.birthday(BIRTHDAY_ID), null)
  }
})

test('rollback failure destroys the connection, keeps the primary error, and attaches only sanitized rollback metadata', async () => {
  const database = new FakeDatabase()
  const primary = new Error('business failure with private payload')
  const rollbackFailure = Object.assign(new Error('rollback leaked secret'), { code: 'ER_ROLLBACK' })
  database.failNext(/^INSERT INTO mobile_sync_changes /, primary)
  const pool = {
    async getConnection() {
      const connection = database.createConnection()
      connection.rollback = async function rollbackError() {
        this.lifecycle.push('rollback')
        throw rollbackFailure
      }
      connection.destroy = function destroyAfterRollbackFailure() {
        this.lifecycle.push('destroy')
        this.destroyed = true
        this.transactionState = null
        this.releaseBirthdayLocks()
      }
      return connection
    },
  }

  await assert.rejects(
    createMobileSyncRepository({ pool }).applyOperation(DEVICE_ID, operation()),
    error => {
      assert.equal(error, primary)
      assert.deepEqual(error.rollbackFailure, { name: 'Error', code: 'ER_ROLLBACK' })
      assert.equal(Object.getOwnPropertyDescriptor(error, 'rollbackFailure').enumerable, false)
      assert.doesNotMatch(JSON.stringify(error), /rollback leaked secret/)
      return true
    },
  )
  assert.deepEqual(database.connections[0].lifecycle, ['begin', 'rollback', 'destroy'])
  assert.equal(database.connections[0].released, false)
  assert.equal(database.connections[0].destroyed, true)
  assert.equal(database.birthday(BIRTHDAY_ID), null)
})

test('a committed first batch item replays exactly when the second item fails and the whole batch is retried', async () => {
  const database = new FakeDatabase()
  const pool = new FakePool(database)
  const realRepository = createMobileSyncRepository({ pool })
  const secondFailure = new Error('second operation failed')
  let calls = 0
  const repository = {
    ...realRepository,
    async applyOperation(...args) {
      calls += 1
      if (calls === 2) database.failNext(/^INSERT INTO mobile_sync_changes /, secondFailure)
      return realRepository.applyOperation(...args)
    },
  }
  const app = createPushApp({ repository }, { errorHandler: true })
  const body = { operations: [
    operation({ payload: validPayload({ name: '妈妈' }) }),
    operation({
      operationId: SECOND_OPERATION_ID,
      entityId: SECOND_BIRTHDAY_ID,
      payload: validPayload({ id: SECOND_BIRTHDAY_ID, name: '爸爸' }),
    }),
  ] }

  const failed = await request(app).post('/api/mobile/sync/push').send(body)
  assert.equal(failed.status, 503)
  const storedFirst = database.operation(OPERATION_ID).response_json
  assert.equal(storedFirst.status, 'applied')
  assert.equal(database.operation(SECOND_OPERATION_ID), null)
  assert.equal(database.state.changes.length, 1)

  const retried = await request(app).post('/api/mobile/sync/push').send(body)
  assert.equal(retried.status, 200)
  assert.deepEqual(retried.body.results[0], storedFirst)
  assert.equal(retried.body.results[1].status, 'applied')
  assert.equal(database.birthday(BIRTHDAY_ID).version, '1')
  assert.equal(database.birthday(SECOND_BIRTHDAY_ID).version, '1')
  assert.equal(database.state.changes.length, 2)
  assert.equal(database.state.operations.size, 2)
  assert.deepEqual(database.connections.map(connection => connection.lifecycle), [
    ['begin', 'commit', 'release'],
    ['begin', 'rollback', 'release'],
    ['begin', 'commit', 'release'],
    ['begin', 'commit', 'release'],
  ])
})

test('duplicate-key race rolls back the losing transaction and returns the committed same-device same-entity response from a new consistent read', async () => {
  const winner = {
    operationId: OPERATION_ID,
    status: 'applied',
    record: {
      id: BIRTHDAY_ID,
      name: '赢家',
      lunarMonth: 8,
      lunarDay: 15,
      isLeapMonth: false,
      reminderTimeMinutes: 540,
      notifyDayBefore: true,
      notifySameDay: true,
      emailEnabled: false,
      emailAddress: '',
      emailMessage: '',
      nextSolarDate: '2026-09-25T01:00:00.000Z',
      version: '1',
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-08-22T04:00:00.000Z',
      deletedAt: null,
    },
  }
  const database = new FakeDatabase()
  database.operationInsertRace = db => {
    db.state.birthdays.set(BIRTHDAY_ID, birthdayRow({ name: '赢家', version: '1' }))
    db.state.changes.push({
      seq: '1',
      entity_type: 'birthday',
      entity_id: BIRTHDAY_ID,
      operation: 'upsert',
      version: '1',
    })
    db.state.operations.set(OPERATION_ID, {
      operation_id: OPERATION_ID,
      device_id: DEVICE_ID,
      entity_id: BIRTHDAY_ID,
      response_json: winner,
    })
  }
  const pool = new FakePool(database)
  const result = await createMobileSyncRepository({ pool }).applyOperation(DEVICE_ID, operation())

  assert.deepEqual(result, winner)
  assert.equal(pool.getConnectionCalls, 2)
  assert.equal(database.birthday(BIRTHDAY_ID).name, '赢家')
  assert.equal(database.state.changes.length, 1)
  assert.deepEqual(database.connections[0].lifecycle, ['begin', 'rollback', 'release'])
  assert.deepEqual(database.connections[1].lifecycle, ['begin', 'commit', 'release'])
  assert.match(database.connections[1].queries[0].sql, /SET TRANSACTION ISOLATION LEVEL READ COMMITTED/i)
})

test('default push authentication requires an exact Bearer token before validation or repository work', async () => {
  const database = new FakeDatabase()
  const pool = new FakePool(database)
  const repository = createMobileSyncRepository({ pool })
  const sessions = {
    calls: [],
    async findByAccessToken(token) {
      this.calls.push(token)
      return token === ACCESS_TOKEN ? { device_id: DEVICE_ID, username: 'admin' } : null
    },
  }
  const app = createPushApp({ repository, mobileAuth: undefined, sessions })

  const unauthenticated = await request(app).post('/api/mobile/sync/push').send({ operations: [operation()] })
  assert.equal(unauthenticated.status, 401)
  assert.deepEqual(unauthenticated.body, { error: 'mobile_auth_required' })
  assert.equal(pool.getConnectionCalls, 0)

  const authenticated = await request(app)
    .post('/api/mobile/sync/push')
    .set('Authorization', `Bearer ${ACCESS_TOKEN}`)
    .send({ operations: [operation()] })
  assert.equal(authenticated.status, 200)
  assert.deepEqual(sessions.calls, [ACCESS_TOKEN])
  assert.equal(pool.getConnectionCalls, 1)
})
