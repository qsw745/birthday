const test = require('node:test')
const assert = require('node:assert/strict')
const request = require('supertest')
const { createTestApp } = require('../helpers/createTestApp')
const {
  serializeBirthdayRow,
  timeToMinutes,
} = require('../../utils/mobileSyncContract')
const { createMobileSyncRepository } = require('../../repositories/mobileSyncRepository')
const { createMobileSyncRouter } = require('../../routes/mobileSync')

const BIRTHDAY_ID = '11111111-1111-4111-8111-111111111111'
const SECOND_BIRTHDAY_ID = '22222222-2222-4222-8222-222222222222'
const INT64_MAX = '9223372036854775807'
const INT64_MAX_PLUS_ONE = '9223372036854775808'

function birthdayRow(overrides = {}) {
  return {
    id: BIRTHDAY_ID,
    name: '妈妈',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: 0,
    remindTime: '09:00:00',
    nextSolarDate: '2026-09-25 09:00:00',
    notify_day_before: 1,
    notify_same_day: 1,
    version: '9007199254740993',
    deleted_at: null,
    created_at: '2026-01-01T00:00:00.000Z',
    updated_at: '2026-08-01T00:00:00.000Z',
    userEmail: 'a@example.com',
    message: '妈妈生日快乐',
    ...overrides,
  }
}

function change(seq, entityId, operation = 'upsert', overrides = {}) {
  const record = serializeBirthdayRow(birthdayRow({
    id: entityId,
    version: String(seq),
    deleted_at: operation === 'delete' ? '2026-08-21 10:30:00' : null,
    userEmail: operation === 'delete' ? null : 'a@example.com',
    message: operation === 'delete' ? null : '妈妈生日快乐',
    ...overrides,
  }))
  return {
    seq: String(seq),
    entity_id: entityId,
    operation,
    entity_version: record.version,
    record_json: record,
  }
}

function createPullPool({ changes = [], afterChangeQuery } = {}) {
  const calls = []
  return {
    calls,
    async execute(sql, params) {
      calls.push({ sql, params })
      if (/FROM\s+mobile_sync_changes/i.test(sql)) {
        const selected = changes
          .filter(row => BigInt(row.seq) > BigInt(params[1]))
          .slice(0, params[2])
        if (afterChangeQuery) await afterChangeQuery()
        return [selected]
      }
      assert.fail(`unexpected SQL: ${sql}`)
    },
  }
}

function createSnapshotConnection({ maxSeq = '0', rows = [], failAt } = {}) {
  const calls = []
  const failure = new Error(`snapshot ${failAt} failed`)
  let readCount = 0
  const connection = {
    calls,
    failure,
    async query(sql, params) {
      if (/SET\s+TRANSACTION\s+ISOLATION\s+LEVEL\s+REPEATABLE\s+READ/i.test(sql)) {
        calls.push({ type: 'isolation', sql, params })
        if (failAt === 'isolation') throw failure
        return [{ affectedRows: 0 }]
      }
      readCount += 1
      if (readCount === 1) {
        calls.push({ type: 'max', sql, params })
        if (failAt === 'max') throw failure
        return [[{ max_seq: maxSeq }]]
      }
      calls.push({ type: 'birthdays', sql, params })
      if (failAt === 'birthdays') throw failure
      return [rows]
    },
    async beginTransaction() {
      calls.push({ type: 'begin' })
      if (failAt === 'begin') throw failure
    },
    async commit() {
      calls.push({ type: 'commit' })
      if (failAt === 'commit') throw failure
    },
    async rollback() {
      calls.push({ type: 'rollback' })
    },
    release() {
      calls.push({ type: 'release' })
    },
  }
  return connection
}

function createRouterApp(options, { errorHandler = false } = {}) {
  const router = createMobileSyncRouter(options)
  const app = createTestApp({ path: '/api/mobile/sync', router })
  if (errorHandler) {
    app.use((error, req, res, next) => {
      res.status(503).json({ error: 'server_error' })
    })
  }
  return app
}

function authenticateAs(username = 'admin') {
  return (req, res, next) => {
    req.mobileSession = { device_id: 'device-1', username }
    next()
  }
}

test('serializer emits exactly the platform-neutral birthday DTO with lossless version and Shanghai ISO timestamps', () => {
  const dto = serializeBirthdayRow(birthdayRow())

  assert.deepEqual(dto, {
    id: BIRTHDAY_ID,
    name: '妈妈',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    reminderTimeMinutes: 540,
    notifyDayBefore: true,
    notifySameDay: true,
    emailEnabled: true,
    emailAddress: 'a@example.com',
    emailMessage: '生日快乐',
    nextSolarDate: '2026-09-25T01:00:00.000Z',
    version: '9007199254740993',
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-08-01T00:00:00.000Z',
    deletedAt: null,
  })
})

test('serializer preserves boolean semantics for numeric-string MySQL flags and disabled email', () => {
  const dto = serializeBirthdayRow(birthdayRow({
    isLeapMonth: '0',
    notify_day_before: '0',
    notify_same_day: '1',
    userEmail: null,
    message: null,
  }))

  assert.equal(dto.isLeapMonth, false)
  assert.equal(dto.notifyDayBefore, false)
  assert.equal(dto.notifySameDay, true)
  assert.equal(dto.emailEnabled, false)
  assert.equal(dto.emailAddress, '')
  assert.equal(dto.emailMessage, '')
})

test('timeToMinutes accepts only valid HH:mm or HH:mm:ss values and defaults malformed legacy data to 09:00', () => {
  const validCases = [
    ['00:00', 0],
    ['08:30:59', 510],
    ['23:59', 1439],
  ]
  const invalidValues = [
    '8:30',
    '24:00',
    '23:60',
    '08:30:60',
    '08:30junk',
    ' 08:30',
    '',
    null,
  ]

  for (const [value, expected] of validCases) assert.equal(timeToMinutes(value), expected, value)
  for (const value of invalidValues) assert.equal(timeToMinutes(value), 540, String(value))
})

test('snapshot reads cursor then all active rows and tombstones on one repeatable-read connection', async () => {
  const tombstone = birthdayRow({
    deleted_at: '2026-08-21 10:30:00',
    userEmail: null,
    message: null,
  })
  const connection = createSnapshotConnection({
    maxSeq: '9007199254740995',
    rows: [birthdayRow(), tombstone],
  })
  let getConnectionCalls = 0
  const pool = {
    async getConnection() {
      getConnectionCalls += 1
      return connection
    },
    execute: async () => assert.fail('snapshot must not use a pool-level query'),
  }
  const repository = createMobileSyncRepository({ pool })

  const result = await repository.snapshot('admin')

  assert.equal(getConnectionCalls, 1)
  assert.deepEqual(connection.calls.map(call => call.type), [
    'isolation',
    'begin',
    'max',
    'birthdays',
    'commit',
    'release',
  ])
  assert.match(connection.calls[2].sql, /CAST\s*\(\s*COALESCE\s*\(\s*MAX\s*\(\s*seq\s*\)/i)
  assert.match(connection.calls[3].sql, /LEFT\s+JOIN\s+email_reminders/i)
  assert.doesNotMatch(connection.calls[3].sql, /deleted_at\s+IS\s+NULL/i)
  assert.doesNotMatch(connection.calls[3].sql, /username/i)
  assert.deepEqual(connection.calls[3].params, [])
  assert.equal(result.cursor, '9007199254740995')
  assert.equal(result.birthdays.length, 2)
  assert.equal(result.birthdays[1].deletedAt, '2026-08-21T02:30:00.000Z')
})

for (const failAt of ['isolation', 'begin', 'max', 'birthdays', 'commit']) {
  test(`snapshot rolls back and releases its connection when ${failAt} fails`, async () => {
    const connection = createSnapshotConnection({ maxSeq: '1', rows: [birthdayRow()], failAt })
    const repository = createMobileSyncRepository({ pool: { getConnection: async () => connection } })

    await assert.rejects(repository.snapshot('admin'), error => error === connection.failure)

    const types = connection.calls.map(call => call.type)
    assert.equal(types.at(-2), 'rollback')
    assert.equal(types.at(-1), 'release')
    assert.equal(types.includes('commit') && failAt !== 'commit', false)
  })
}

test('snapshot requires an authenticated single-admin identity without querying a nonexistent birthday username column', async () => {
  let getConnectionCalls = 0
  const repository = createMobileSyncRepository({
    pool: { getConnection: async () => { getConnectionCalls += 1; return createSnapshotConnection() } },
  })

  await assert.rejects(repository.snapshot(), error => error.code === 'invalid_username')
  await assert.rejects(repository.snapshot('   '), error => error.code === 'invalid_username')
  assert.equal(getConnectionCalls, 0)
})

for (const [name, maxSeq, rows] of [
  ['negative cursor', '-1', []],
  ['cursor above Int64', INT64_MAX_PLUS_ONE, []],
  ['negative birthday version', '0', [birthdayRow({ version: '-1' })]],
  ['birthday version above Int64', '0', [birthdayRow({ version: INT64_MAX_PLUS_ONE })]],
]) {
  test(`snapshot rejects inconsistent database output for ${name}`, async () => {
    const connection = createSnapshotConnection({ maxSeq, rows })
    const repository = createMobileSyncRepository({ pool: { getConnection: async () => connection } })

    await assert.rejects(
      repository.snapshot('admin'),
      error => error.name === 'MobileSyncDataConsistencyError'
        && error.code === 'mobile_sync_inconsistent_state',
    )
    assert.deepEqual(connection.calls.slice(-2).map(call => call.type), ['rollback', 'release'])
  })
}

for (const { name, changes, limit, expectedHasMore, expectedSeqs, expectedLimitParam } of [
  {
    name: 'fewer than limit',
    changes: [change('1', BIRTHDAY_ID)],
    limit: 2,
    expectedHasMore: false,
    expectedSeqs: ['1'],
    expectedLimitParam: 3,
  },
  {
    name: 'exactly limit',
    changes: [change('1', BIRTHDAY_ID), change('2', SECOND_BIRTHDAY_ID)],
    limit: 2,
    expectedHasMore: false,
    expectedSeqs: ['1', '2'],
    expectedLimitParam: 3,
  },
  {
    name: 'more than limit',
    changes: [change('1', BIRTHDAY_ID), change('2', SECOND_BIRTHDAY_ID), change('3', '33333333-3333-4333-8333-333333333333')],
    limit: 2,
    expectedHasMore: true,
    expectedSeqs: ['1', '2'],
    expectedLimitParam: 3,
  },
]) {
  test(`pull computes exact hasMore and nextCursor when the page has ${name}`, async () => {
    const pool = createPullPool({ changes })
    const repository = createMobileSyncRepository({ pool })

    const result = await repository.pull('0', limit)

    assert.equal(result.hasMore, expectedHasMore)
    assert.deepEqual(result.changes.map(item => item.seq), expectedSeqs)
    assert.equal(result.nextCursor, expectedSeqs.at(-1))
    assert.match(pool.calls[0].sql, /seq\s*>\s*CAST\s*\(\s*\?\s+AS\s+SIGNED\s*\)[\s\S]*ORDER\s+BY\s+seq\s+ASC[\s\S]*LIMIT\s+\?/i)
    assert.deepEqual(pool.calls[0].params, ['birthday', '0', expectedLimitParam])
    assert.equal(pool.calls[0].params[1], '0')
  })
}

test('pull preserves a canonical empty-page cursor and performs only the event query', async () => {
  const cursor = '9007199254740993'
  const pool = createPullPool({ changes: [] })
  const repository = createMobileSyncRepository({ pool })

  const result = await repository.pull(cursor, 200)

  assert.deepEqual(result, { changes: [], nextCursor: cursor, hasMore: false })
  assert.equal(pool.calls.length, 1)
  assert.deepEqual(pool.calls[0].params, ['birthday', cursor, 201])
})

test('pull never converts BIGINT cursor or sequence values through Number', async () => {
  const cursor = '9007199254740993'
  const next = '9007199254740994'
  const pool = createPullPool({
    changes: [change(next, BIRTHDAY_ID, 'upsert', { version: INT64_MAX })],
  })
  const repository = createMobileSyncRepository({ pool })

  const result = await repository.pull(cursor, 1)

  assert.equal(pool.calls[0].params[1], cursor)
  assert.equal(result.nextCursor, next)
  assert.equal(result.changes[0].seq, next)
  assert.equal(result.changes[0].record.version, INT64_MAX)
  assert.match(pool.calls[0].sql, /CAST\s*\(\s*seq\s+AS\s+CHAR\s*\)/i)
  assert.match(pool.calls[0].sql, /seq\s*>\s*CAST\s*\(\s*\?\s+AS\s+SIGNED\s*\)/i)
})

test('pull preserves exact upsert, delete, and restore event snapshots across page boundaries', async () => {
  const pool = createPullPool({
    changes: [
      change('10', BIRTHDAY_ID, 'upsert', { name: '初始' }),
      change('11', BIRTHDAY_ID, 'delete', { name: '初始' }),
      change('12', BIRTHDAY_ID, 'upsert', { name: '恢复' }),
    ],
  })
  const repository = createMobileSyncRepository({ pool })

  const first = await repository.pull('9', 2)
  const second = await repository.pull(first.nextCursor, 2)

  assert.deepEqual([...first.changes, ...second.changes].map(item => ({
    seq: item.seq,
    operation: item.operation,
    version: item.record.version,
    name: item.record.name,
    deleted: item.record.deletedAt !== null,
  })), [
    { seq: '10', operation: 'upsert', version: '10', name: '初始', deleted: false },
    { seq: '11', operation: 'delete', version: '11', name: '初始', deleted: true },
    { seq: '12', operation: 'upsert', version: '12', name: '恢复', deleted: false },
  ])
  assert.equal(first.nextCursor, '11')
  assert.equal(first.hasMore, true)
  assert.equal(second.nextCursor, '12')
  assert.equal(second.hasMore, false)
  assert.equal(pool.calls.length, 2)
})

test('pull accepts JSON-column objects and JSON strings without consulting mutable current rows', async () => {
  let currentBirthday = birthdayRow({ name: '查询后的并发值', version: '99' })
  const first = change('10', BIRTHDAY_ID, 'upsert', { name: '事件值' })
  const second = change('11', SECOND_BIRTHDAY_ID, 'delete')
  second.record_json = JSON.stringify(second.record_json)
  const pool = createPullPool({
    changes: [first, second],
    afterChangeQuery: () => { currentBirthday = birthdayRow({ name: '再次变化', version: '100' }) },
  })
  const repository = createMobileSyncRepository({ pool })

  const result = await repository.pull('9', 2)

  assert.equal(result.changes[0].record.name, '事件值')
  assert.equal(result.changes[1].record.deletedAt !== null, true)
  assert.equal(currentBirthday.name, '再次变化')
  assert.equal(pool.calls.length, 1)
})

for (const [name, mutate] of [
  ['malformed JSON', row => { row.record_json = '{' }],
  ['non-object JSON', row => { row.record_json = [] }],
  ['record id mismatch', row => { row.record_json.id = BIRTHDAY_ID }],
  ['record version mismatch', row => { row.record_json.version = '9' }],
  ['incomplete birthday DTO', row => { delete row.record_json.name }],
  ['delete without tombstone', row => { row.operation = 'delete' }],
  ['delete missing deletedAt', row => { row.operation = 'delete'; delete row.record_json.deletedAt }],
  ['upsert carrying tombstone', row => { row.record_json.deletedAt = '2026-08-21T02:30:00.000Z' }],
  ['noncanonical sequence', row => { row.seq = '011' }],
  ['sequence above Int64', row => { row.seq = INT64_MAX_PLUS_ONE }],
  ['negative entity version', row => { row.entity_version = '-1' }],
  ['entity version above Int64', row => { row.entity_version = INT64_MAX_PLUS_ONE }],
]) {
  test(`pull rejects the entire event page for ${name}`, async () => {
    const valid = change('10', BIRTHDAY_ID)
    const corrupted = change('11', SECOND_BIRTHDAY_ID)
    mutate(corrupted)
    const pool = createPullPool({ changes: [valid, corrupted] })
    const repository = createMobileSyncRepository({ pool })

    await assert.rejects(
      repository.pull('9', 2),
      error => error.name === 'MobileSyncDataConsistencyError'
        && error.code === 'mobile_sync_inconsistent_state',
    )
    assert.equal(pool.calls.length, 1)
  })
}

test('pull defaults limit to 200 and binds limit+1 as an integer query parameter', async () => {
  const pool = createPullPool({ changes: [] })
  const repository = createMobileSyncRepository({ pool })

  await repository.pull('0')

  assert.deepEqual(pool.calls[0].params, ['birthday', '0', 201])
  assert.equal(Number.isSafeInteger(pool.calls[0].params[2]), true)
})

test('pull rejects malformed cursor strings before touching the database', async () => {
  const invalidCursors = [undefined, null, '', -1, 0, '-1', '+1', '00', '01', '1.0', '1e3', ' 1', '1 ', '0 OR 1=1', INT64_MAX_PLUS_ONE]
  let executeCalls = 0
  const repository = createMobileSyncRepository({
    pool: { execute: async () => { executeCalls += 1; return [[]] } },
  })

  for (const cursor of invalidCursors) {
    await assert.rejects(repository.pull(cursor), error => error.code === 'invalid_cursor', String(cursor))
  }
  assert.equal(executeCalls, 0)
})

test('pull accepts the signed Int64 maximum cursor as an exact bound string', async () => {
  const pool = createPullPool({ changes: [] })
  const repository = createMobileSyncRepository({ pool })

  const result = await repository.pull(INT64_MAX, 1)

  assert.deepEqual(result, { changes: [], nextCursor: INT64_MAX, hasMore: false })
  assert.deepEqual(pool.calls[0].params, ['birthday', INT64_MAX, 2])
  assert.equal(typeof pool.calls[0].params[1], 'string')
  assert.match(pool.calls[0].sql, /seq\s*>\s*CAST\s*\(\s*\?\s+AS\s+SIGNED\s*\)/i)
})

test('pull accepts only a safe integer limit from 1 through 200 before touching the database', async () => {
  const invalidLimits = [0, -1, 201, 1.5, Number.MAX_SAFE_INTEGER + 1, '', '0', '-1', '201', '1.5', '1e2', ' 2', {}, null]
  let executeCalls = 0
  const repository = createMobileSyncRepository({
    pool: { execute: async () => { executeCalls += 1; return [[]] } },
  })

  for (const limit of invalidLimits) {
    await assert.rejects(repository.pull('0', limit), error => error.code === 'invalid_limit', String(limit))
  }
  assert.equal(executeCalls, 0)
})

test('snapshot route authenticates, passes the current username, and returns the repository payload', async () => {
  let snapshotUsername
  const payload = { cursor: '7', birthdays: [] }
  const syncRepository = {
    snapshot: async username => {
      snapshotUsername = username
      return payload
    },
  }
  const app = createRouterApp({ syncRepository, mobileAuth: authenticateAs('admin') })

  const response = await request(app).get('/api/mobile/sync/snapshot')

  assert.equal(response.status, 200)
  assert.deepEqual(response.body, payload)
  assert.equal(snapshotUsername, 'admin')
})

test('pull route validates and normalizes cursor and limit before invoking the repository', async () => {
  let args
  const payload = { changes: [], nextCursor: '9007199254740993', hasMore: false }
  const syncRepository = {
    pull: async (...input) => {
      args = input
      return payload
    },
  }
  const app = createRouterApp({ syncRepository, mobileAuth: authenticateAs() })

  const response = await request(app)
    .get('/api/mobile/sync/pull')
    .query({ cursor: '9007199254740993', limit: '25' })

  assert.equal(response.status, 200)
  assert.deepEqual(response.body, payload)
  assert.deepEqual(args, ['9007199254740993', 25])
})

test('pull route returns exact validation errors and never calls the repository for bad input', async () => {
  let pullCalls = 0
  const syncRepository = { pull: async () => { pullCalls += 1 } }
  const app = createRouterApp({ syncRepository, mobileAuth: authenticateAs() })

  for (const path of [
    '/api/mobile/sync/pull',
    '/api/mobile/sync/pull?cursor=-1',
    '/api/mobile/sync/pull?cursor=1.5',
    '/api/mobile/sync/pull?cursor=0%20OR%201%3D1',
    '/api/mobile/sync/pull?cursor=01',
    `/api/mobile/sync/pull?cursor=${INT64_MAX_PLUS_ONE}`,
  ]) {
    const response = await request(app).get(path)
    assert.equal(response.status, 400, path)
    assert.deepEqual(response.body, { error: 'invalid_cursor' }, path)
  }

  for (const limit of ['0', '201', '1.5', '1e2', ' 2']) {
    const response = await request(app)
      .get('/api/mobile/sync/pull')
      .query({ cursor: '0', limit })
    assert.equal(response.status, 400, limit)
    assert.deepEqual(response.body, { error: 'invalid_limit' }, limit)
  }

  assert.equal(pullCalls, 0)
})

test('snapshot and pull use default mobile bearer authentication when middleware is not injected', async () => {
  let repositoryCalls = 0
  const syncRepository = {
    snapshot: async () => { repositoryCalls += 1 },
    pull: async () => { repositoryCalls += 1 },
  }
  const sessions = {
    findByAccessToken: async () => assert.fail('missing authorization must not query sessions'),
  }
  const app = createRouterApp({ syncRepository, sessions })

  const snapshot = await request(app).get('/api/mobile/sync/snapshot')
  const pull = await request(app).get('/api/mobile/sync/pull?cursor=0')

  assert.equal(snapshot.status, 401)
  assert.deepEqual(snapshot.body, { error: 'mobile_auth_required' })
  assert.equal(pull.status, 401)
  assert.deepEqual(pull.body, { error: 'mobile_auth_required' })
  assert.equal(repositoryCalls, 0)
})

for (const method of ['snapshot', 'pull']) {
  test(`${method} repository failures propagate through the Express error path`, async () => {
    const failure = new Error('database unavailable')
    const syncRepository = {
      [method]: async () => { throw failure },
    }
    const app = createRouterApp(
      { syncRepository, mobileAuth: authenticateAs() },
      { errorHandler: true },
    )
    const path = method === 'snapshot'
      ? '/api/mobile/sync/snapshot'
      : '/api/mobile/sync/pull?cursor=0'

    const response = await request(app).get(path)

    assert.equal(response.status, 503)
    assert.deepEqual(response.body, { error: 'server_error' })
  })
}

test('pull consistency failures propagate through Express without returning a cursor or partial page', async () => {
  const corrupted = change('10', BIRTHDAY_ID)
  corrupted.record_json.version = '9'
  const pool = createPullPool({
    changes: [corrupted],
  })
  const syncRepository = createMobileSyncRepository({ pool })
  const app = createRouterApp(
    { syncRepository, mobileAuth: authenticateAs() },
    { errorHandler: true },
  )

  const response = await request(app).get('/api/mobile/sync/pull?cursor=9')

  assert.equal(response.status, 503)
  assert.deepEqual(response.body, { error: 'server_error' })
  assert.equal(Object.hasOwn(response.body, 'nextCursor'), false)
  assert.equal(pool.calls.length, 1)
})
