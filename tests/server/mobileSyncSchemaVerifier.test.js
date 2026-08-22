const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const {
  verifyMobileSyncSchema,
  runCli,
  reminderStateIsCompatible,
} = require('../../scripts/verify_mobile_sync_schema')

function column(tableName, columnName, dataType, columnType, options = {}) {
  return {
    table_name: tableName,
    column_name: columnName,
    data_type: dataType,
    column_type: columnType,
    is_nullable: options.nullable ? 'YES' : 'NO',
    column_default: options.defaultValue ?? null,
    extra: options.extra ?? '',
    character_maximum_length: options.length ?? null,
  }
}

function indexRows(tableName, indexName, columns, unique = false) {
  return columns.map((columnName, offset) => ({
    table_name: tableName,
    index_name: indexName,
    non_unique: unique ? 0 : 1,
    seq_in_index: offset + 1,
    column_name: columnName,
    sub_part: null,
    index_type: 'BTREE',
  }))
}

function validMetadata() {
  const tables = [
    'birthdays',
    'email_reminders',
    'mobile_sync_changes',
    'mobile_sync_operations',
    'mobile_device_sessions',
  ].map(tableName => ({ table_name: tableName, engine: 'InnoDB' }))

  const columns = [
    column('birthdays', 'version', 'bigint', 'bigint', { defaultValue: '1' }),
    column('birthdays', 'deleted_at', 'datetime', 'datetime', { nullable: true }),
    column('birthdays', 'notify_day_before', 'tinyint', 'tinyint(1)', { defaultValue: '1' }),
    column('birthdays', 'notify_same_day', 'tinyint', 'tinyint(1)', { defaultValue: '1' }),

    column('email_reminders', 'status', 'tinyint', 'tinyint', { defaultValue: '0' }),
    column('email_reminders', 'remind_time', 'datetime', 'datetime'),
    column('email_reminders', 'schedule_mode', 'enum', "enum('derived','exact')"),
    column('email_reminders', 'generation', 'char', 'char(36)', { length: 36 }),
    column('email_reminders', 'claim_token', 'char', 'char(36)', { nullable: true, length: 36 }),
    column('email_reminders', 'claim_generation', 'char', 'char(36)', { nullable: true, length: 36 }),
    column('email_reminders', 'claim_remind_time', 'datetime', 'datetime', { nullable: true }),
    column('email_reminders', 'claimed_at', 'datetime', 'datetime', { nullable: true }),
    column('email_reminders', 'delivered_remind_time', 'datetime', 'datetime', { nullable: true }),

    column('mobile_sync_changes', 'seq', 'bigint', 'bigint', { extra: 'auto_increment' }),
    column('mobile_sync_changes', 'entity_type', 'varchar', 'varchar(32)', { length: 32 }),
    column('mobile_sync_changes', 'entity_id', 'varchar', 'varchar(36)', { length: 36 }),
    column('mobile_sync_changes', 'operation', 'enum', "enum('upsert','delete')"),
    column('mobile_sync_changes', 'entity_version', 'bigint', 'bigint'),
    column('mobile_sync_changes', 'record_json', 'json', 'json'),
    column('mobile_sync_changes', 'changed_at', 'timestamp', 'timestamp', { defaultValue: 'CURRENT_TIMESTAMP' }),

    column('mobile_sync_operations', 'operation_id', 'varchar', 'varchar(36)', { length: 36 }),
    column('mobile_sync_operations', 'device_id', 'varchar', 'varchar(36)', { length: 36 }),
    column('mobile_sync_operations', 'base_version', 'bigint', 'bigint'),
    column('mobile_sync_operations', 'response_json', 'json', 'json'),
    column('mobile_sync_operations', 'processed_at', 'timestamp', 'timestamp', { defaultValue: 'current_timestamp()' }),

    column('mobile_device_sessions', 'device_id', 'varchar', 'varchar(36)', { length: 36 }),
    column('mobile_device_sessions', 'username', 'varchar', 'varchar(64)', { length: 64 }),
    column('mobile_device_sessions', 'device_name', 'varchar', 'varchar(100)', { length: 100 }),
    column('mobile_device_sessions', 'access_token_hash', 'char', 'char(64)', { length: 64 }),
    column('mobile_device_sessions', 'refresh_token_hash', 'char', 'char(64)', { length: 64 }),
    column('mobile_device_sessions', 'access_expires_at', 'datetime', 'datetime'),
    column('mobile_device_sessions', 'refresh_expires_at', 'datetime', 'datetime'),
    column('mobile_device_sessions', 'created_at', 'timestamp', 'timestamp', { defaultValue: 'CURRENT_TIMESTAMP' }),
    column('mobile_device_sessions', 'last_used_at', 'timestamp', 'timestamp', { nullable: true }),
    column('mobile_device_sessions', 'revoked_at', 'timestamp', 'timestamp', { nullable: true }),
  ]

  const indexes = [
    ...indexRows('birthdays', 'PRIMARY', ['id'], true),
    ...indexRows('birthdays', 'idx_birthdays_deleted_at', ['deleted_at']),
    ...indexRows('email_reminders', 'PRIMARY', ['id'], true),
    ...indexRows('email_reminders', 'uk_birthday_id', ['birthday_id'], true),
    ...indexRows('email_reminders', 'idx_status_time', ['status', 'remind_time']),
    ...indexRows('mobile_sync_changes', 'PRIMARY', ['seq'], true),
    ...indexRows('mobile_sync_changes', 'idx_mobile_changes_entity', ['entity_type', 'entity_id', 'seq']),
    ...indexRows('mobile_sync_operations', 'uk_mobile_operation_id', ['operation_id'], true),
    ...indexRows('mobile_sync_operations', 'idx_mobile_operations_device', ['device_id', 'processed_at']),
    ...indexRows('mobile_device_sessions', 'PRIMARY', ['device_id'], true),
    ...indexRows('mobile_device_sessions', 'uk_mobile_access_hash', ['access_token_hash'], true),
    ...indexRows('mobile_device_sessions', 'uk_mobile_refresh_hash', ['refresh_token_hash'], true),
    ...indexRows('mobile_device_sessions', 'idx_mobile_sessions_username', ['username', 'revoked_at']),
  ]

  return { tables, columns, indexes }
}

function validQuery(overrides = {}) {
  const metadata = validMetadata()
  const results = [
    overrides.tables ?? metadata.tables,
    overrides.columns ?? metadata.columns,
    overrides.indexes ?? metadata.indexes,
    overrides.counts ?? [
      { table_name: 'birthdays', row_count: '3' },
      { table_name: 'email_reminders', row_count: '2' },
      { table_name: 'mobile_sync_changes', row_count: '4' },
      { table_name: 'mobile_sync_operations', row_count: '4' },
      { table_name: 'mobile_device_sessions', row_count: '1' },
    ],
    overrides.reminderStates ?? [
      { schedule_mode: 'derived', status: 0, row_count: '2' },
    ],
    overrides.invalidStates ?? [{
      invalid_birthday_rows: '0',
      invalid_reminder_rows: '0',
      invalid_change_rows: '0',
      invalid_operation_rows: '0',
      invalid_session_rows: '0',
    }],
  ]
  const sql = []

  return {
    sql,
    query: async statement => {
      sql.push(statement)
      if (results.length === 0) throw new Error('unexpected query')
      return results.shift()
    },
  }
}

test('accepts the complete compatible schema using only read-only queries', async () => {
  const fake = validQuery()

  const result = await verifyMobileSyncSchema({ query: fake.query })

  assert.deepEqual(result.tableCounts, {
    birthdays: '3',
    email_reminders: '2',
    mobile_sync_changes: '4',
    mobile_sync_operations: '4',
    mobile_device_sessions: '1',
  })
  assert.equal(fake.sql.length, 6)
  assert.equal(fake.sql.every(statement => /^\s*SELECT\b/i.test(statement)), true)
  assert.equal(fake.sql.some(statement => /(?:^|;)\s*(?:ALTER|CREATE|DELETE|INSERT|UPDATE|REPLACE|DROP|TRUNCATE)\b/i.test(statement)), false)
})

test('rejects a missing required birthday column', async () => {
  const metadata = validMetadata()
  const fake = validQuery({
    columns: metadata.columns.filter(row => row.column_name !== 'notify_same_day'),
  })

  await assert.rejects(
    verifyMobileSyncSchema({ query: fake.query }),
    /birthdays\.notify_same_day: missing column/,
  )
})

test('rejects incompatible signedness, type, nullability, enum, length, and auto increment contracts', async t => {
  const cases = [
    {
      name: 'unsigned signed-Int64 column',
      target: ['birthdays', 'version'],
      patch: { column_type: 'bigint unsigned' },
      expected: /birthdays\.version: expected signed BIGINT/,
    },
    {
      name: 'JSON stored as text',
      target: ['mobile_sync_changes', 'record_json'],
      patch: { data_type: 'longtext', column_type: 'longtext' },
      expected: /mobile_sync_changes\.record_json: expected JSON/,
    },
    {
      name: 'required response made nullable',
      target: ['mobile_sync_operations', 'response_json'],
      patch: { is_nullable: 'YES' },
      expected: /mobile_sync_operations\.response_json: expected NOT NULL/,
    },
    {
      name: 'reminder status uses the wrong type',
      target: ['email_reminders', 'status'],
      patch: { data_type: 'bigint', column_type: 'bigint' },
      expected: /email_reminders\.status: expected TINYINT/,
    },
    {
      name: 'reminder status uses the wrong default',
      target: ['email_reminders', 'status'],
      patch: { column_default: '1' },
      expected: /email_reminders\.status: expected default 0/,
    },
    {
      name: 'reminder time is nullable',
      target: ['email_reminders', 'remind_time'],
      patch: { is_nullable: 'YES' },
      expected: /email_reminders\.remind_time: expected NOT NULL/,
    },
    {
      name: 'enum loses a value',
      target: ['email_reminders', 'schedule_mode'],
      patch: { column_type: "enum('derived')" },
      expected: /email_reminders\.schedule_mode: expected ENUM\('derived','exact'\)/,
    },
    {
      name: 'token hash length is incompatible',
      target: ['mobile_device_sessions', 'access_token_hash'],
      patch: { column_type: 'char(63)', character_maximum_length: 63 },
      expected: /mobile_device_sessions\.access_token_hash: expected CHAR\(64\)/,
    },
    {
      name: 'sequence loses auto increment',
      target: ['mobile_sync_changes', 'seq'],
      patch: { extra: '' },
      expected: /mobile_sync_changes\.seq: expected AUTO_INCREMENT/,
    },
  ]

  for (const item of cases) {
    await t.test(item.name, async () => {
      const metadata = validMetadata()
      const columns = metadata.columns.map(row => (
        row.table_name === item.target[0] && row.column_name === item.target[1]
          ? { ...row, ...item.patch }
          : row
      ))
      const fake = validQuery({ columns })

      await assert.rejects(verifyMobileSyncSchema({ query: fake.query }), item.expected)
    })
  }
})

test('rejects non-InnoDB tables and missing required indexes', async t => {
  await t.test('engine', async () => {
    const metadata = validMetadata()
    const tables = metadata.tables.map(row => (
      row.table_name === 'mobile_sync_operations' ? { ...row, engine: 'MyISAM' } : row
    ))
    const fake = validQuery({ tables })

    await assert.rejects(
      verifyMobileSyncSchema({ query: fake.query }),
      /mobile_sync_operations: expected InnoDB engine/,
    )
  })

  await t.test('unique index', async () => {
    const metadata = validMetadata()
    const indexes = metadata.indexes.filter(row => row.index_name !== 'uk_mobile_refresh_hash')
    const fake = validQuery({ indexes })

    await assert.rejects(
      verifyMobileSyncSchema({ query: fake.query }),
      /mobile_device_sessions: missing UNIQUE index \(refresh_token_hash\)/,
    )
  })

  await t.test('prefix unique index', async () => {
    const metadata = validMetadata()
    const indexes = metadata.indexes.map(row => (
      row.index_name === 'uk_mobile_access_hash' ? { ...row, sub_part: 32 } : row
    ))
    const fake = validQuery({ indexes })

    await assert.rejects(
      verifyMobileSyncSchema({ query: fake.query }),
      /mobile_device_sessions: missing UNIQUE index \(access_token_hash\)/,
    )
  })

  await t.test('prefix on a trailing extra query-index column remains compatible', async () => {
    const metadata = validMetadata()
    const indexes = [
      ...metadata.indexes,
      {
        table_name: 'email_reminders',
        index_name: 'idx_status_time',
        non_unique: 1,
        seq_in_index: 3,
        column_name: 'id',
        sub_part: 8,
        index_type: 'BTREE',
      },
    ]
    const fake = validQuery({ indexes })

    await verifyMobileSyncSchema({ query: fake.query })
  })

  await t.test('a full-length unique composite left prefix satisfies a query-index contract', async () => {
    const metadata = validMetadata()
    const indexes = [
      ...metadata.indexes.filter(row => row.index_name !== 'idx_status_time'),
      ...indexRows(
        'email_reminders',
        'uk_status_time_id',
        ['status', 'remind_time', 'id'],
        true,
      ),
    ]
    const fake = validQuery({ indexes })

    await verifyMobileSyncSchema({ query: fake.query })
  })

  await t.test('prefix on a required query-index column is incompatible', async () => {
    const metadata = validMetadata()
    const indexes = metadata.indexes.map(row => (
      row.index_name === 'idx_status_time' && row.column_name === 'remind_time'
        ? { ...row, sub_part: 4 }
        : row
    ))
    const fake = validQuery({ indexes })

    await assert.rejects(
      verifyMobileSyncSchema({ query: fake.query }),
      /email_reminders: missing index \(status, remind_time\)/,
    )
  })
})

test('rejects a partially applied migration instead of accepting the objects that exist', async () => {
  const metadata = validMetadata()
  const fake = validQuery({
    tables: metadata.tables.filter(row => row.table_name !== 'mobile_device_sessions'),
    columns: metadata.columns.filter(row => row.table_name !== 'mobile_device_sessions'),
    indexes: metadata.indexes.filter(row => row.table_name !== 'mobile_device_sessions'),
  })

  await assert.rejects(
    verifyMobileSyncSchema({ query: fake.query }),
    /mobile_device_sessions: missing table.*partial migration detected/s,
  )
})

test('rejects incompatible post-migration row state reported by read-only checks', async () => {
  const fake = validQuery({
    invalidStates: [{
      invalid_birthday_rows: '0',
      invalid_reminder_rows: '1',
      invalid_change_rows: '0',
      invalid_operation_rows: '0',
      invalid_session_rows: '0',
    }],
  })

  await assert.rejects(
    verifyMobileSyncSchema({ query: fake.query }),
    /email_reminders: 1 incompatible row state/,
  )
})

test('reminder delivery state follows the current occurrence with null-safe equality', async () => {
  const base = {
    schedule_mode: 'derived',
    generation: '11111111-1111-4111-8111-111111111111',
    remind_time: '2027-08-22 09:00:00',
    claim_token: null,
    claim_generation: null,
    claim_remind_time: null,
    claimed_at: null,
  }

  assert.equal(reminderStateIsCompatible({
    ...base,
    status: 1,
    delivered_remind_time: base.remind_time,
  }), true, 'current occurrence delivered')
  assert.equal(reminderStateIsCompatible({
    ...base,
    status: 0,
    delivered_remind_time: '2026-08-22 09:00:00',
  }), true, 'old delivered marker retained after advancing occurrence')
  assert.equal(reminderStateIsCompatible({
    ...base,
    status: 1,
    delivered_remind_time: null,
  }), false, 'delivered status without current marker')
  assert.equal(reminderStateIsCompatible({
    ...base,
    status: 0,
    delivered_remind_time: base.remind_time,
  }), false, 'pending status for an already delivered current occurrence')
  assert.equal(reminderStateIsCompatible({
    ...base,
    status: null,
    delivered_remind_time: null,
  }), false, 'NULL status is explicit corruption')
  assert.equal(reminderStateIsCompatible({
    ...base,
    status: 0,
    remind_time: null,
    delivered_remind_time: null,
  }), false, 'NULL occurrence is explicit corruption')
  assert.equal(reminderStateIsCompatible({
    ...base,
    status: 0,
    generation: null,
    delivered_remind_time: null,
  }), false, 'NULL generation is explicit corruption')

  const fake = validQuery()
  await verifyMobileSyncSchema({ query: fake.query })
  const stateSql = fake.sql.at(-1)
  assert.match(stateSql, /status IS NULL/)
  assert.match(stateSql, /remind_time IS NULL/)
  assert.match(stateSql, /generation IS NULL/)
  assert.match(stateSql, /status = 1 AND NOT \(delivered_remind_time <=> remind_time\)/)
  assert.match(stateSql, /status = 0 AND \(delivered_remind_time <=> remind_time\)/)
})

test('accepts harmless metadata casing and current-timestamp display variants', async () => {
  const metadata = validMetadata()
  const fake = validQuery({
    tables: metadata.tables.map(row => ({ ...row, engine: row.engine.toUpperCase() })),
    columns: metadata.columns.map(row => ({
      ...row,
      data_type: row.data_type.toUpperCase(),
      column_type: row.column_type.toUpperCase(),
      extra: row.extra.toUpperCase(),
      column_default: String(row.column_default ?? '').toUpperCase() || null,
    })),
  })

  await verifyMobileSyncSchema({ query: fake.query })
})

test('CLI lazily loads the database, closes the pool, and prints PASS only after success', async () => {
  const fake = validQuery()
  const stdout = []
  const stderr = []
  let loads = 0
  let closes = 0

  const exitCode = await runCli({
    loadDb: () => {
      loads += 1
      return {
        query: fake.query,
        pool: { end: async () => { closes += 1 } },
      }
    },
    stdout: line => stdout.push(line),
    stderr: line => stderr.push(line),
  })

  assert.equal(exitCode, 0)
  assert.equal(loads, 1)
  assert.equal(closes, 1)
  assert.deepEqual(stdout, ['MOBILE_SYNC_SCHEMA=PASS'])
  assert.deepEqual(stderr, [])
})

test('CLI closes the pool after query failure and never exposes the database error or credentials', async () => {
  const stdout = []
  const stderr = []
  let closes = 0

  const exitCode = await runCli({
    loadDb: () => ({
      query: async () => {
        throw new Error('Access denied password=hunter2 host=secret.example')
      },
      pool: { end: async () => { closes += 1 } },
    }),
    stdout: line => stdout.push(line),
    stderr: line => stderr.push(line),
  })

  assert.equal(exitCode, 1)
  assert.equal(closes, 1)
  assert.deepEqual(stdout, [])
  assert.equal(stderr.length, 1)
  assert.match(stderr[0], /^MOBILE_SYNC_SCHEMA=FAIL /)
  assert.doesNotMatch(stderr[0], /hunter2|secret\.example|password/i)
})

test('CLI treats pool close failure as failure and does not print PASS', async () => {
  const fake = validQuery()
  const stdout = []
  const stderr = []

  const exitCode = await runCli({
    loadDb: () => ({
      query: fake.query,
      pool: { end: async () => { throw new Error('password=do-not-print') } },
    }),
    stdout: line => stdout.push(line),
    stderr: line => stderr.push(line),
  })

  assert.equal(exitCode, 1)
  assert.deepEqual(stdout, [])
  assert.deepEqual(stderr, ['MOBILE_SYNC_SCHEMA=FAIL database close failed'])
})

test('a clean child process can import the verifier silently and exit immediately', () => {
  const modulePath = require.resolve('../../scripts/verify_mobile_sync_schema')
  const child = spawnSync(process.execPath, ['-e', `require(${JSON.stringify(modulePath)})`], {
    cwd: path.resolve(__dirname, '../..'),
    encoding: 'utf8',
    timeout: 2000,
  })

  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  assert.equal(child.status, 0)
  assert.equal(child.stdout, '')
  assert.equal(child.stderr, '')
})

test('the real CLI entrypoint sanitizes query failure, closes the pool, and exits 1', () => {
  const scriptPath = require.resolve('../../scripts/verify_mobile_sync_schema')
  const preloadPath = path.resolve(__dirname, '../fixtures/schemaVerifierDbFailurePreload.js')
  const child = spawnSync(process.execPath, ['--require', preloadPath, scriptPath], {
    cwd: path.resolve(__dirname, '../..'),
    encoding: 'utf8',
    timeout: 2000,
    stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
  })

  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  assert.equal(child.status, 1)
  assert.equal(child.stdout, '')
  assert.match(child.stderr, /^MOBILE_SYNC_SCHEMA=FAIL schema query failed \(tables\)\n$/)
  assert.doesNotMatch(child.stderr, /hunter2|secret\.example|password/i)
  assert.equal(child.output[3], 'POOL_END=CALLED\n')
})
