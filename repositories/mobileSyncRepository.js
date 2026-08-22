const {
  assertAPIBirthdayChange,
  decimalString,
  isNormalizedPushOperation,
  MobileSyncDataConsistencyError,
  normalizeCursor,
  normalizeLimit,
  normalizePushRequest,
  serializeBirthdayRow,
} = require('../utils/mobileSyncContract')
const { MOBILE_API_CONTRACT } = require('../utils/mobileApiContract')
const {
  applyMobileOperation,
  readStoredOperation,
} = require('../services/birthdayMutationService')

const BIRTHDAY_SELECT = `SELECT
  b.id,
  b.name,
  b.lunarMonth,
  b.lunarDay,
  b.isLeapMonth,
  b.remindTime,
  b.nextSolarDate,
  CAST(b.version AS CHAR) AS version,
  b.deleted_at,
  b.notify_day_before,
  b.notify_same_day,
  b.created_at,
  b.updated_at,
  r.email AS userEmail,
  r.message AS message
FROM birthdays b
LEFT JOIN email_reminders r ON r.birthday_id = b.id`
const MAX_OPERATION_ATTEMPTS = 3
const RETRYABLE_TRANSACTION_CODES = new Set([
  'ER_LOCK_DEADLOCK',
  'ER_LOCK_WAIT_TIMEOUT',
])

function requireUsername(username) {
  if (typeof username !== 'string' || username.trim().length === 0) {
    const error = new TypeError('username is required for the single-admin snapshot')
    error.code = 'invalid_username'
    throw error
  }
}

function parseChangeRecord(value) {
  if (Buffer.isBuffer(value)) value = value.toString('utf8')
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value)
    } catch {
      throw new MobileSyncDataConsistencyError('invalid change record JSON')
    }
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new MobileSyncDataConsistencyError('change record must be an object')
  }
  return value
}

function canonicalChangeInt64(value, fieldName) {
  if (typeof value !== 'string') {
    throw new MobileSyncDataConsistencyError(`${fieldName} must be a canonical string`)
  }
  return decimalString(value, fieldName)
}

function serializeChangeRow(row) {
  const seq = canonicalChangeInt64(row.seq, 'sequence')
  const entityVersion = canonicalChangeInt64(row.entity_version, 'entity version')
  const record = parseChangeRecord(row.record_json)
  assertAPIBirthdayChange({
    entityId: row.entity_id,
    operation: row.operation,
    entityVersion,
    record,
  })
  return { seq, operation: row.operation, record }
}

function connectionErrorMetadata(error) {
  const metadata = {
    name: typeof error?.name === 'string' ? error.name : 'Error',
  }
  if (typeof error?.code === 'string') metadata.code = error.code
  return metadata
}

function attachRollbackFailure(primaryError, rollbackError) {
  if (!primaryError || (typeof primaryError !== 'object' && typeof primaryError !== 'function')) {
    return
  }
  try {
    Object.defineProperty(primaryError, 'rollbackFailure', {
      configurable: true,
      enumerable: false,
      value: connectionErrorMetadata(rollbackError),
    })
  } catch {
    // A frozen third-party error still remains the primary failure.
  }
}

async function rollbackAfterFailure(connection, primaryError) {
  try {
    await connection.rollback()
    return false
  } catch (rollbackError) {
    attachRollbackFailure(primaryError, rollbackError)
    try {
      if (typeof connection.destroy === 'function') connection.destroy()
    } catch {
      // The original error remains primary; a tainted connection is never released.
    }
    return true
  }
}

function isRetryableOperationFailure(error) {
  return Boolean(
    error?.mobileBirthdayInsertRace
    || RETRYABLE_TRANSACTION_CODES.has(error?.code),
  )
}

function createMobileSyncRepository({
  pool,
  applyMobileOperationFn = applyMobileOperation,
  readStoredOperationFn = readStoredOperation,
}) {
  async function snapshot(username) {
    requireUsername(username)
    const connection = await pool.getConnection()
    let destroyed = false
    try {
      await connection.query('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ', [])
      await connection.beginTransaction()
      const [cursorRows] = await connection.query(
        'SELECT CAST(COALESCE(MAX(seq), 0) AS CHAR) AS max_seq FROM mobile_sync_changes',
        [],
      )
      const [rows] = await connection.query(`${BIRTHDAY_SELECT}\nORDER BY b.id ASC`, [])
      const result = {
        cursor: decimalString(cursorRows[0] ? cursorRows[0].max_seq : '0', 'cursor'),
        birthdays: rows.map(serializeBirthdayRow),
      }
      await connection.commit()
      return result
    } catch (error) {
      destroyed = await rollbackAfterFailure(connection, error)
      throw error
    } finally {
      if (!destroyed) connection.release()
    }
  }

  async function pull(cursor, limit = MOBILE_API_CONTRACT.limits.pullDefault) {
    const normalizedCursor = normalizeCursor(cursor)
    const normalizedLimit = normalizeLimit(limit)
    const [changeRows] = await pool.execute(
      `SELECT
         CAST(seq AS CHAR) AS seq,
         entity_id,
         operation,
         CAST(entity_version AS CHAR) AS entity_version,
         record_json
       FROM mobile_sync_changes
       WHERE entity_type = ?
         AND seq > CAST(? AS SIGNED)
       ORDER BY seq ASC
       LIMIT ?`,
      // mysql2/MySQL 8 rejects a numeric LIMIT parameter in the native
      // prepared-statement path with ER_WRONG_ARGUMENTS. The value has already
      // passed the strict 1...200 integer contract; bind its canonical decimal
      // string so the server can execute the prepared LIMIT safely.
      ['birthday', normalizedCursor, String(normalizedLimit + 1)],
    )
    const pageRows = changeRows.slice(0, normalizedLimit)
    if (pageRows.length === 0) {
      return { changes: [], nextCursor: normalizedCursor, hasMore: false }
    }

    const changes = pageRows.map(serializeChangeRow)

    return {
      changes,
      nextCursor: changes.at(-1).seq,
      hasMore: changeRows.length > normalizedLimit,
    }
  }

  async function recoverDuplicateOperation(deviceId, operation, duplicateError) {
    const connection = await pool.getConnection()
    let destroyed = false
    try {
      await connection.query('SET TRANSACTION ISOLATION LEVEL READ COMMITTED', [])
      await connection.beginTransaction()
      const stored = await readStoredOperationFn(connection, { deviceId, operation })
      if (!stored) throw duplicateError
      await connection.commit()
      return stored
    } catch (error) {
      destroyed = await rollbackAfterFailure(connection, error)
      throw error
    } finally {
      if (!destroyed) connection.release()
    }
  }

  async function applyOperation(deviceId, operationInput) {
    const operation = isNormalizedPushOperation(operationInput)
      ? operationInput
      : normalizePushRequest({ operations: [operationInput] }).operations[0]
    for (let attempt = 1; ; attempt += 1) {
      const connection = await pool.getConnection()
      let duplicateError = null
      let shouldRetry = false
      let destroyed = false
      try {
        await connection.beginTransaction()
        const result = await applyMobileOperationFn(connection, { deviceId, operation })
        await connection.commit()
        return result
      } catch (error) {
        destroyed = await rollbackAfterFailure(connection, error)
        if (error && error.mobileOperationResponseDuplicate) {
          duplicateError = error
        } else if (
          isRetryableOperationFailure(error)
          && attempt < MAX_OPERATION_ATTEMPTS
        ) {
          shouldRetry = true
        } else {
          throw error
        }
      } finally {
        if (!destroyed) connection.release()
      }

      if (duplicateError) {
        return recoverDuplicateOperation(deviceId, operation, duplicateError)
      }
      if (shouldRetry) continue
    }
  }

  return { snapshot, pull, applyOperation }
}

module.exports = { createMobileSyncRepository }
