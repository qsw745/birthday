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
const UINT64_MAX = '18446744073709551615'
const UINT64_MAX_PLUS_ONE = '18446744073709551616'

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

function change(seq, entityId, operation = 'upsert') {
  return {
    seq: String(seq),
    entity_id: entityId,
    operation,
    version: String(seq),
  }
}

function createPullPool({ changes = [], rows = [] } = {}) {
  const calls = []
  return {
    calls,
    async execute(sql, params) {
      calls.push({ sql, params })
      if (/FROM\s+mobile_sync_changes/i.test(sql)) return [changes]
      if (/FROM\s+birthdays/i.test(sql)) return [rows]
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
    const rows = [
      birthdayRow(),
      birthdayRow({ id: SECOND_BIRTHDAY_ID, name: '爸爸', message: '爸爸生日快乐' }),
    ]
    const pool = createPullPool({ changes, rows })
    const repository = createMobileSyncRepository({ pool })

    const result = await repository.pull('0', limit)

    assert.equal(result.hasMore, expectedHasMore)
    assert.deepEqual(result.changes.map(item => item.seq), expectedSeqs)
    assert.equal(result.nextCursor, expectedSeqs.at(-1))
    assert.match(pool.calls[0].sql, /seq\s*>\s*CAST\s*\(\s*\?\s+AS\s+UNSIGNED\s*\)[\s\S]*ORDER\s+BY\s+seq\s+ASC[\s\S]*LIMIT\s+\?/i)
    assert.deepEqual(pool.calls[0].params, ['birthday', '0', expectedLimitParam])
    assert.equal(pool.calls[0].params[1], '0')
  })
}

test('pull preserves an empty-page cursor verbatim and skips the current-row query', async () => {
  const cursor = '0009007199254740993'
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
    changes: [change(next, BIRTHDAY_ID)],
    rows: [birthdayRow({ version: '18446744073709551615' })],
  })
  const repository = createMobileSyncRepository({ pool })

  const result = await repository.pull(cursor, 1)

  assert.equal(pool.calls[0].params[1], cursor)
  assert.equal(result.nextCursor, next)
  assert.equal(result.changes[0].seq, next)
  assert.equal(result.changes[0].record.version, '18446744073709551615')
  assert.match(pool.calls[0].sql, /CAST\s*\(\s*seq\s+AS\s+CHAR\s*\)/i)
  assert.match(pool.calls[0].sql, /seq\s*>\s*CAST\s*\(\s*\?\s+AS\s+UNSIGNED\s*\)/i)
})

test('pull keeps every ordered change and reuses one complete current tombstone for duplicate IDs', async () => {
  const tombstone = birthdayRow({
    version: '12',
    deleted_at: '2026-08-21 10:30:00',
    userEmail: null,
    message: null,
  })
  const pool = createPullPool({
    changes: [
      change('10', BIRTHDAY_ID, 'upsert'),
      change('11', BIRTHDAY_ID, 'delete'),
    ],
    rows: [tombstone],
  })
  const repository = createMobileSyncRepository({ pool })

  const result = await repository.pull('9', 2)

  assert.deepEqual(result.changes.map(item => ({
    seq: item.seq,
    operation: item.operation,
    id: item.record && item.record.id,
    deletedAt: item.record && item.record.deletedAt,
  })), [
    { seq: '10', operation: 'upsert', id: BIRTHDAY_ID, deletedAt: '2026-08-21T02:30:00.000Z' },
    { seq: '11', operation: 'delete', id: BIRTHDAY_ID, deletedAt: '2026-08-21T02:30:00.000Z' },
  ])
  assert.equal(result.changes[0].record, result.changes[1].record)
  assert.ok(result.changes.every(item => item.record !== null))
  assert.equal(result.nextCursor, '11')
  assert.equal(result.hasMore, false)
  assert.equal(pool.calls.length, 2)
  assert.deepEqual(pool.calls[1].params, [BIRTHDAY_ID])
  assert.equal((pool.calls[1].sql.match(/\?/g) || []).length, 1)
})

test('pull rejects the entire page with a stable consistency error when one current birthday row is missing', async () => {
  const missingId = "x') OR 1=1 --"
  const pool = createPullPool({
    changes: [change('10', missingId)],
    rows: [],
  })
  const repository = createMobileSyncRepository({ pool })

  await assert.rejects(
    repository.pull('9', 1),
    error => error.name === 'MobileSyncDataConsistencyError'
      && error.code === 'mobile_sync_inconsistent_state'
      && error.message === 'current birthday row missing for sync change',
  )

  assert.equal(pool.calls.length, 2)
  assert.doesNotMatch(pool.calls[1].sql, /x'\) OR 1=1/)
  assert.deepEqual(pool.calls[1].params, [missingId])
})

test('pull rejects a partially resolvable page before constructing changes or performing later side effects', async () => {
  const pool = createPullPool({
    changes: [
      change('10', BIRTHDAY_ID),
      change('11', SECOND_BIRTHDAY_ID),
    ],
    rows: [birthdayRow()],
  })
  const repository = createMobileSyncRepository({ pool })

  let result
  await assert.rejects(
    async () => { result = await repository.pull('9', 2) },
    error => error.code === 'mobile_sync_inconsistent_state',
  )

  assert.equal(result, undefined)
  assert.equal(pool.calls.length, 2)
  assert.deepEqual(pool.calls[1].params, [BIRTHDAY_ID, SECOND_BIRTHDAY_ID])
})

test('pull defaults limit to 200 and binds limit+1 as an integer query parameter', async () => {
  const pool = createPullPool({ changes: [] })
  const repository = createMobileSyncRepository({ pool })

  await repository.pull('0')

  assert.deepEqual(pool.calls[0].params, ['birthday', '0', 201])
  assert.equal(Number.isSafeInteger(pool.calls[0].params[2]), true)
})

test('pull rejects malformed cursor strings before touching the database', async () => {
  const invalidCursors = [undefined, null, '', -1, 0, '-1', '+1', '1.0', '1e3', ' 1', '1 ', '0 OR 1=1', UINT64_MAX_PLUS_ONE]
  let executeCalls = 0
  const repository = createMobileSyncRepository({
    pool: { execute: async () => { executeCalls += 1; return [[]] } },
  })

  for (const cursor of invalidCursors) {
    await assert.rejects(repository.pull(cursor), error => error.code === 'invalid_cursor', String(cursor))
  }
  assert.equal(executeCalls, 0)
})

test('pull accepts the UInt64 maximum cursor as an exact bound string', async () => {
  const pool = createPullPool({ changes: [] })
  const repository = createMobileSyncRepository({ pool })

  const result = await repository.pull(UINT64_MAX, 1)

  assert.deepEqual(result, { changes: [], nextCursor: UINT64_MAX, hasMore: false })
  assert.deepEqual(pool.calls[0].params, ['birthday', UINT64_MAX, 2])
  assert.equal(typeof pool.calls[0].params[1], 'string')
  assert.match(pool.calls[0].sql, /seq\s*>\s*CAST\s*\(\s*\?\s+AS\s+UNSIGNED\s*\)/i)
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
    `/api/mobile/sync/pull?cursor=${UINT64_MAX_PLUS_ONE}`,
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
  const pool = createPullPool({
    changes: [change('10', BIRTHDAY_ID)],
    rows: [],
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
  assert.equal(pool.calls.length, 2)
})
