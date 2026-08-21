const REQUIRED_TABLES = [
  'birthdays',
  'email_reminders',
  'mobile_sync_changes',
  'mobile_sync_operations',
  'mobile_device_sessions',
]

const COLUMN_CONTRACTS = [
  { table: 'birthdays', column: 'version', kind: 'signed_bigint', nullable: false, defaultValue: '1', label: 'signed BIGINT' },
  { table: 'birthdays', column: 'deleted_at', kind: 'datetime', nullable: true, defaultValue: null, label: 'DATETIME' },
  { table: 'birthdays', column: 'notify_day_before', kind: 'tinyint_bool', nullable: false, defaultValue: '1', label: 'TINYINT(1)' },
  { table: 'birthdays', column: 'notify_same_day', kind: 'tinyint_bool', nullable: false, defaultValue: '1', label: 'TINYINT(1)' },

  { table: 'email_reminders', column: 'status', kind: 'tinyint', nullable: false, defaultValue: '0', label: 'TINYINT' },
  { table: 'email_reminders', column: 'remind_time', kind: 'datetime', nullable: false, defaultValue: null, label: 'DATETIME' },
  { table: 'email_reminders', column: 'schedule_mode', kind: 'enum', values: ['derived', 'exact'], nullable: false, defaultValue: null, label: "ENUM('derived','exact')" },
  { table: 'email_reminders', column: 'generation', kind: 'char', length: 36, nullable: false, defaultValue: null, label: 'CHAR(36)' },
  { table: 'email_reminders', column: 'claim_token', kind: 'char', length: 36, nullable: true, defaultValue: null, label: 'CHAR(36)' },
  { table: 'email_reminders', column: 'claim_generation', kind: 'char', length: 36, nullable: true, defaultValue: null, label: 'CHAR(36)' },
  { table: 'email_reminders', column: 'claim_remind_time', kind: 'datetime', nullable: true, defaultValue: null, label: 'DATETIME' },
  { table: 'email_reminders', column: 'claimed_at', kind: 'datetime', nullable: true, defaultValue: null, label: 'DATETIME' },
  { table: 'email_reminders', column: 'delivered_remind_time', kind: 'datetime', nullable: true, defaultValue: null, label: 'DATETIME' },

  { table: 'mobile_sync_changes', column: 'seq', kind: 'signed_bigint', nullable: false, defaultValue: null, autoIncrement: true, label: 'signed BIGINT' },
  { table: 'mobile_sync_changes', column: 'entity_type', kind: 'varchar', length: 32, nullable: false, defaultValue: null, label: 'VARCHAR(32)' },
  { table: 'mobile_sync_changes', column: 'entity_id', kind: 'varchar', length: 36, nullable: false, defaultValue: null, label: 'VARCHAR(36)' },
  { table: 'mobile_sync_changes', column: 'operation', kind: 'enum', values: ['upsert', 'delete'], nullable: false, defaultValue: null, label: "ENUM('upsert','delete')" },
  { table: 'mobile_sync_changes', column: 'entity_version', kind: 'signed_bigint', nullable: false, defaultValue: null, label: 'signed BIGINT' },
  { table: 'mobile_sync_changes', column: 'record_json', kind: 'json', nullable: false, defaultValue: null, label: 'JSON' },
  { table: 'mobile_sync_changes', column: 'changed_at', kind: 'timestamp', nullable: false, defaultValue: 'current_timestamp', label: 'TIMESTAMP' },

  { table: 'mobile_sync_operations', column: 'operation_id', kind: 'varchar', length: 36, nullable: false, defaultValue: null, label: 'VARCHAR(36)' },
  { table: 'mobile_sync_operations', column: 'device_id', kind: 'varchar', length: 36, nullable: false, defaultValue: null, label: 'VARCHAR(36)' },
  { table: 'mobile_sync_operations', column: 'base_version', kind: 'signed_bigint', nullable: false, defaultValue: null, label: 'signed BIGINT' },
  { table: 'mobile_sync_operations', column: 'response_json', kind: 'json', nullable: false, defaultValue: null, label: 'JSON' },
  { table: 'mobile_sync_operations', column: 'processed_at', kind: 'timestamp', nullable: false, defaultValue: 'current_timestamp', label: 'TIMESTAMP' },

  { table: 'mobile_device_sessions', column: 'device_id', kind: 'varchar', length: 36, nullable: false, defaultValue: null, label: 'VARCHAR(36)' },
  { table: 'mobile_device_sessions', column: 'username', kind: 'varchar', length: 64, nullable: false, defaultValue: null, label: 'VARCHAR(64)' },
  { table: 'mobile_device_sessions', column: 'device_name', kind: 'varchar', length: 100, nullable: false, defaultValue: null, label: 'VARCHAR(100)' },
  { table: 'mobile_device_sessions', column: 'access_token_hash', kind: 'char', length: 64, nullable: false, defaultValue: null, label: 'CHAR(64)' },
  { table: 'mobile_device_sessions', column: 'refresh_token_hash', kind: 'char', length: 64, nullable: false, defaultValue: null, label: 'CHAR(64)' },
  { table: 'mobile_device_sessions', column: 'access_expires_at', kind: 'datetime', nullable: false, defaultValue: null, label: 'DATETIME' },
  { table: 'mobile_device_sessions', column: 'refresh_expires_at', kind: 'datetime', nullable: false, defaultValue: null, label: 'DATETIME' },
  { table: 'mobile_device_sessions', column: 'created_at', kind: 'timestamp', nullable: false, defaultValue: 'current_timestamp', label: 'TIMESTAMP' },
  { table: 'mobile_device_sessions', column: 'last_used_at', kind: 'timestamp', nullable: true, defaultValue: null, label: 'TIMESTAMP' },
  { table: 'mobile_device_sessions', column: 'revoked_at', kind: 'timestamp', nullable: true, defaultValue: null, label: 'TIMESTAMP' },
]

const INDEX_CONTRACTS = [
  { table: 'birthdays', columns: ['id'], unique: true, primary: true },
  { table: 'birthdays', columns: ['deleted_at'] },
  { table: 'email_reminders', columns: ['id'], unique: true, primary: true },
  { table: 'email_reminders', columns: ['birthday_id'], unique: true },
  { table: 'email_reminders', columns: ['status', 'remind_time'] },
  { table: 'mobile_sync_changes', columns: ['seq'], unique: true, primary: true },
  { table: 'mobile_sync_changes', columns: ['entity_type', 'entity_id', 'seq'] },
  { table: 'mobile_sync_operations', columns: ['operation_id'], unique: true },
  { table: 'mobile_sync_operations', columns: ['device_id', 'processed_at'] },
  { table: 'mobile_device_sessions', columns: ['device_id'], unique: true, primary: true },
  { table: 'mobile_device_sessions', columns: ['access_token_hash'], unique: true },
  { table: 'mobile_device_sessions', columns: ['refresh_token_hash'], unique: true },
  { table: 'mobile_device_sessions', columns: ['username', 'revoked_at'] },
]

const TABLE_SQL = `
  SELECT TABLE_NAME AS table_name, ENGINE AS engine
  FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME IN (${REQUIRED_TABLES.map(() => '?').join(', ')})
  ORDER BY TABLE_NAME
`

const COLUMN_SQL = `
  SELECT TABLE_NAME AS table_name,
         COLUMN_NAME AS column_name,
         DATA_TYPE AS data_type,
         COLUMN_TYPE AS column_type,
         IS_NULLABLE AS is_nullable,
         COLUMN_DEFAULT AS column_default,
         EXTRA AS extra,
         CHARACTER_MAXIMUM_LENGTH AS character_maximum_length
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME IN (${REQUIRED_TABLES.map(() => '?').join(', ')})
  ORDER BY TABLE_NAME, ORDINAL_POSITION
`

const INDEX_SQL = `
  SELECT TABLE_NAME AS table_name,
         INDEX_NAME AS index_name,
         NON_UNIQUE AS non_unique,
         SEQ_IN_INDEX AS seq_in_index,
         COLUMN_NAME AS column_name,
         SUB_PART AS sub_part,
         INDEX_TYPE AS index_type
  FROM information_schema.STATISTICS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME IN (${REQUIRED_TABLES.map(() => '?').join(', ')})
  ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
`

const COUNT_SQL = REQUIRED_TABLES
  .map(tableName => `SELECT '${tableName}' AS table_name, COUNT(*) AS row_count FROM \`${tableName}\``)
  .join('\nUNION ALL\n')

const REMINDER_STATE_SQL = `
  SELECT schedule_mode, status, COUNT(*) AS row_count
  FROM email_reminders
  GROUP BY schedule_mode, status
  ORDER BY schedule_mode, status
`

const REMINDER_DELIVERY_MATCH_SQL = '(delivered_remind_time <=> remind_time)'

const INVALID_STATE_SQL = `
  SELECT
    (SELECT COUNT(*) FROM birthdays
      WHERE version < 1 OR notify_day_before NOT IN (0, 1) OR notify_same_day NOT IN (0, 1)) AS invalid_birthday_rows,
    (SELECT COUNT(*) FROM email_reminders
      WHERE status IS NULL
         OR remind_time IS NULL
         OR schedule_mode IS NULL
         OR schedule_mode NOT IN ('derived', 'exact')
         OR generation IS NULL
         OR CHAR_LENGTH(generation) <> 36
         OR status NOT IN (0, 1)
         OR ((claim_token IS NULL) <> (claim_generation IS NULL))
         OR ((claim_token IS NULL) <> (claim_remind_time IS NULL))
         OR ((claim_token IS NULL) <> (claimed_at IS NULL))
         OR (status = 1 AND NOT ${REMINDER_DELIVERY_MATCH_SQL})
         OR (status = 0 AND ${REMINDER_DELIVERY_MATCH_SQL})) AS invalid_reminder_rows,
    (SELECT COUNT(*) FROM mobile_sync_changes
      WHERE seq < 1 OR entity_version < 1 OR operation NOT IN ('upsert', 'delete')) AS invalid_change_rows,
    (SELECT COUNT(*) FROM mobile_sync_operations
      WHERE base_version < 0) AS invalid_operation_rows,
    (SELECT COUNT(*) FROM mobile_device_sessions
      WHERE CHAR_LENGTH(device_id) <> 36
         OR CHAR_LENGTH(access_token_hash) <> 64
         OR CHAR_LENGTH(refresh_token_hash) <> 64) AS invalid_session_rows
`

class SchemaVerificationError extends Error {
  constructor(issues) {
    const marker = issues.partial ? '; partial migration detected' : ''
    super(`schema verification failed: ${issues.items.join('; ')}${marker}`)
    this.name = 'SchemaVerificationError'
  }
}

class SchemaQueryError extends Error {
  constructor(phase) {
    super(`schema query failed (${phase})`)
    this.name = 'SchemaQueryError'
  }
}

function lower(value) {
  return String(value ?? '').trim().toLowerCase()
}

function compactType(value) {
  return lower(value).replace(/\s+/g, '')
}

function normalizeDefault(value) {
  if (value === null || value === undefined) return null
  return lower(value).replace(/\s+/g, '').replace(/\(\)$/, '')
}

function rowValue(row, key) {
  if (Object.hasOwn(row, key)) return row[key]
  const match = Object.keys(row).find(candidate => lower(candidate) === lower(key))
  return match === undefined ? undefined : row[match]
}

function normalizeName(value) {
  return lower(value)
}

function isExpectedColumnType(row, contract) {
  const dataType = lower(rowValue(row, 'data_type'))
  const columnType = compactType(rowValue(row, 'column_type'))
  const length = Number(rowValue(row, 'character_maximum_length'))

  switch (contract.kind) {
    case 'signed_bigint':
      return dataType === 'bigint' && /^bigint(?:\(\d+\))?$/.test(columnType) && !columnType.includes('unsigned')
    case 'tinyint_bool':
      return dataType === 'tinyint' && columnType === 'tinyint(1)' && !columnType.includes('unsigned')
    case 'tinyint':
      return dataType === 'tinyint' && /^tinyint(?:\(\d+\))?$/.test(columnType) && !columnType.includes('unsigned')
    case 'datetime':
      return dataType === 'datetime' && /^(?:datetime|datetime\(0\))$/.test(columnType)
    case 'timestamp':
      return dataType === 'timestamp' && /^(?:timestamp|timestamp\(0\))$/.test(columnType)
    case 'json':
      return dataType === 'json' && columnType === 'json'
    case 'char':
    case 'varchar':
      return dataType === contract.kind
        && columnType === `${contract.kind}(${contract.length})`
        && length === contract.length
    case 'enum':
      return dataType === 'enum'
        && columnType === `enum(${contract.values.map(value => `'${value}'`).join(',')})`
    default:
      return false
  }
}

function collectIndexes(rows) {
  const groups = new Map()
  for (const row of rows) {
    const table = normalizeName(rowValue(row, 'table_name'))
    const name = normalizeName(rowValue(row, 'index_name'))
    const key = `${table}\u0000${name}`
    const group = groups.get(key) ?? {
      table,
      name,
      unique: Number(rowValue(row, 'non_unique')) === 0,
      type: lower(rowValue(row, 'index_type')),
      entries: [],
    }
    group.entries.push({
      position: Number(rowValue(row, 'seq_in_index')),
      column: normalizeName(rowValue(row, 'column_name')),
      fullLength: rowValue(row, 'sub_part') === null || rowValue(row, 'sub_part') === undefined,
    })
    groups.set(key, group)
  }

  return [...groups.values()].map(group => {
    const entries = group.entries.sort((left, right) => left.position - right.position)
    return {
      table: group.table,
      name: group.name,
      unique: group.unique,
      type: group.type,
      columns: entries.map(entry => entry.column),
      fullLengths: entries.map(entry => entry.fullLength),
    }
  })
}

function hasCompatibleIndex(indexes, contract) {
  return indexes.some(index => {
    if (index.table !== contract.table) return false
    if (index.type !== 'btree') return false
    if (contract.primary && index.name !== 'primary') return false
    if (contract.unique && !index.unique) return false
    if (!contract.unique && index.unique) return false
    const requiredPrefixMatches = contract.columns.every((column, offset) => (
      index.columns[offset] === column && index.fullLengths[offset]
    ))
    if (!requiredPrefixMatches) return false
    return contract.unique || contract.primary
      ? index.columns.length === contract.columns.length
      : true
  })
}

function nullSafeValueEqual(left, right) {
  const leftNull = left === null || left === undefined
  const rightNull = right === null || right === undefined
  if (leftNull || rightNull) return leftNull && rightNull
  if (left instanceof Date || right instanceof Date) {
    const leftTime = left instanceof Date ? left.getTime() : new Date(left).getTime()
    const rightTime = right instanceof Date ? right.getTime() : new Date(right).getTime()
    return Number.isFinite(leftTime) && Number.isFinite(rightTime) && leftTime === rightTime
  }
  return String(left) === String(right)
}

function reminderStateIsCompatible(row) {
  if (!row || (row.status !== 0 && row.status !== 1)) return false
  if (row.remind_time === null || row.remind_time === undefined) return false
  if (row.schedule_mode !== 'derived' && row.schedule_mode !== 'exact') return false
  if (typeof row.generation !== 'string' || row.generation.length !== 36) return false

  const claimFields = [
    row.claim_token,
    row.claim_generation,
    row.claim_remind_time,
    row.claimed_at,
  ]
  const nullClaimFields = claimFields.filter(value => value === null || value === undefined).length
  if (nullClaimFields !== 0 && nullClaimFields !== claimFields.length) return false

  const currentOccurrenceDelivered = nullSafeValueEqual(
    row.delivered_remind_time,
    row.remind_time,
  )
  return row.status === 1 ? currentOccurrenceDelivered : !currentOccurrenceDelivered
}

function validateMetadata(tableRows, columnRows, indexRows) {
  const issues = []
  const tables = new Map(tableRows.map(row => [
    normalizeName(rowValue(row, 'table_name')),
    row,
  ]))
  const columns = new Map(columnRows.map(row => [
    `${normalizeName(rowValue(row, 'table_name'))}.${normalizeName(rowValue(row, 'column_name'))}`,
    row,
  ]))

  for (const tableName of REQUIRED_TABLES) {
    const table = tables.get(tableName)
    if (!table) {
      issues.push(`${tableName}: missing table`)
    } else if (lower(rowValue(table, 'engine')) !== 'innodb') {
      issues.push(`${tableName}: expected InnoDB engine`)
    }
  }

  for (const contract of COLUMN_CONTRACTS) {
    const key = `${contract.table}.${contract.column}`
    const row = columns.get(key)
    if (!row) {
      issues.push(`${key}: missing column`)
      continue
    }

    if (!isExpectedColumnType(row, contract)) {
      issues.push(`${key}: expected ${contract.label}`)
    }

    const nullable = lower(rowValue(row, 'is_nullable')) === 'yes'
    if (nullable !== contract.nullable) {
      issues.push(`${key}: expected ${contract.nullable ? 'NULL' : 'NOT NULL'}`)
    }

    if (normalizeDefault(rowValue(row, 'column_default')) !== normalizeDefault(contract.defaultValue)) {
      const expected = contract.defaultValue === null ? 'no default' : `default ${contract.defaultValue}`
      issues.push(`${key}: expected ${expected}`)
    }

    const extras = lower(rowValue(row, 'extra')).split(/\s+/).filter(Boolean)
    if (contract.autoIncrement && !extras.includes('auto_increment')) {
      issues.push(`${key}: expected AUTO_INCREMENT`)
    }
    if (!contract.autoIncrement && extras.includes('auto_increment')) {
      issues.push(`${key}: unexpected AUTO_INCREMENT`)
    }
  }

  const indexes = collectIndexes(indexRows)
  for (const contract of INDEX_CONTRACTS) {
    if (hasCompatibleIndex(indexes, contract)) continue
    const kind = contract.primary ? 'PRIMARY KEY' : contract.unique ? 'UNIQUE index' : 'index'
    issues.push(`${contract.table}: missing ${kind} (${contract.columns.join(', ')})`)
  }

  if (issues.length > 0) {
    const mobileTables = new Set([
      'mobile_sync_changes',
      'mobile_sync_operations',
      'mobile_device_sessions',
    ])
    const markerCount = COLUMN_CONTRACTS.reduce(
      (count, contract) => count + (columns.has(`${contract.table}.${contract.column}`) ? 1 : 0),
      0,
    ) + [...mobileTables].filter(table => tables.has(table)).length
    const markerTotal = COLUMN_CONTRACTS.length + mobileTables.size
    throw new SchemaVerificationError({
      items: issues,
      partial: markerCount > 0 && markerCount < markerTotal,
    })
  }
}

function parseCount(value) {
  const decimal = String(value)
  return /^\d+$/.test(decimal) ? decimal : null
}

function validateState(countRows, invalidStateRows) {
  const issues = []
  const counts = new Map(countRows.map(row => [
    normalizeName(rowValue(row, 'table_name')),
    parseCount(rowValue(row, 'row_count')),
  ]))
  for (const tableName of REQUIRED_TABLES) {
    if (counts.get(tableName) === null || counts.get(tableName) === undefined) {
      issues.push(`${tableName}: missing read-only row count`)
    }
  }

  const invalid = invalidStateRows[0]
  if (!invalid) {
    issues.push('missing read-only compatibility state')
  } else {
    const stateChecks = [
      ['birthdays', 'invalid_birthday_rows'],
      ['email_reminders', 'invalid_reminder_rows'],
      ['mobile_sync_changes', 'invalid_change_rows'],
      ['mobile_sync_operations', 'invalid_operation_rows'],
      ['mobile_device_sessions', 'invalid_session_rows'],
    ]
    for (const [tableName, key] of stateChecks) {
      const count = parseCount(rowValue(invalid, key))
      if (count === null) issues.push(`${tableName}: invalid compatibility count`)
      else if (count !== '0') issues.push(`${tableName}: ${count} incompatible row state`)
    }
  }

  if (issues.length > 0) {
    throw new SchemaVerificationError({ items: issues, partial: false })
  }

  return Object.fromEntries(REQUIRED_TABLES.map(tableName => [tableName, counts.get(tableName)]))
}

async function readRows(query, phase, sql, params = []) {
  try {
    const rows = await query(sql, params)
    if (!Array.isArray(rows)) throw new Error('non-row result')
    return rows
  } catch (_error) {
    throw new SchemaQueryError(phase)
  }
}

async function verifyMobileSyncSchema({ query }) {
  if (typeof query !== 'function') throw new TypeError('query must be a function')

  const tables = await readRows(query, 'tables', TABLE_SQL, REQUIRED_TABLES)
  const columns = await readRows(query, 'columns', COLUMN_SQL, REQUIRED_TABLES)
  const indexes = await readRows(query, 'indexes', INDEX_SQL, REQUIRED_TABLES)
  validateMetadata(tables, columns, indexes)

  const counts = await readRows(query, 'counts', COUNT_SQL)
  const reminderStates = await readRows(query, 'reminder states', REMINDER_STATE_SQL)
  const invalidStates = await readRows(query, 'compatibility state', INVALID_STATE_SQL)
  const tableCounts = validateState(counts, invalidStates)

  return {
    tableCounts,
    reminderStates: reminderStates.map(row => ({
      scheduleMode: rowValue(row, 'schedule_mode'),
      status: rowValue(row, 'status'),
      rowCount: String(rowValue(row, 'row_count')),
    })),
  }
}

function loadProductionDatabase() {
  require('dotenv').config({ quiet: true })
  return require('../utils/db')
}

function safeFailureMessage(error) {
  if (error instanceof SchemaVerificationError || error instanceof SchemaQueryError) {
    return error.message
  }
  return 'database unavailable'
}

async function runCli(options = {}) {
  const loadDb = options.loadDb ?? loadProductionDatabase
  const stdout = options.stdout ?? console.log
  const stderr = options.stderr ?? console.error
  let database
  let failure
  let closeFailed = false

  try {
    database = loadDb()
    if (!database || typeof database.query !== 'function') {
      throw new Error('query unavailable')
    }
    if (!database.pool || typeof database.pool.end !== 'function') {
      throw new Error('pool unavailable')
    }
    await verifyMobileSyncSchema({ query: database.query })
  } catch (error) {
    failure = error
  } finally {
    if (database?.pool && typeof database.pool.end === 'function') {
      try {
        await database.pool.end()
      } catch (_error) {
        closeFailed = true
      }
    }
  }

  if (failure || closeFailed) {
    const reasons = []
    if (failure) reasons.push(safeFailureMessage(failure))
    if (closeFailed) reasons.push('database close failed')
    stderr(`MOBILE_SYNC_SCHEMA=FAIL ${reasons.join('; ')}`)
    return 1
  }

  stdout('MOBILE_SYNC_SCHEMA=PASS')
  return 0
}

if (require.main === module) {
  runCli()
    .then(exitCode => { process.exitCode = exitCode })
    .catch(() => {
      console.error('MOBILE_SYNC_SCHEMA=FAIL unexpected verifier failure')
      process.exitCode = 1
    })
}

module.exports = {
  verifyMobileSyncSchema,
  runCli,
  SchemaVerificationError,
  reminderStateIsCompatible,
}
