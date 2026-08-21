const {
  decimalString,
  isNormalizedPushOperation,
  normalizeCursor,
  normalizeLimit,
  normalizePushRequest,
  serializeBirthdayRow,
} = require('../utils/mobileSyncContract')
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

class MobileSyncDataConsistencyError extends Error {
  constructor() {
    super('current birthday row missing for sync change')
    this.name = 'MobileSyncDataConsistencyError'
    this.code = 'mobile_sync_inconsistent_state'
  }
}

function requireUsername(username) {
  if (typeof username !== 'string' || username.trim().length === 0) {
    const error = new TypeError('username is required for the single-admin snapshot')
    error.code = 'invalid_username'
    throw error
  }
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

  async function pull(cursor, limit = 200) {
    const normalizedCursor = normalizeCursor(cursor)
    const normalizedLimit = normalizeLimit(limit)
    const [changeRows] = await pool.execute(
      `SELECT
         CAST(seq AS CHAR) AS seq,
         entity_id,
         operation,
         CAST(version AS CHAR) AS version
       FROM mobile_sync_changes
       WHERE entity_type = ?
         AND seq > CAST(? AS UNSIGNED)
       ORDER BY seq ASC
       LIMIT ?`,
      ['birthday', normalizedCursor, normalizedLimit + 1],
    )
    const pageRows = changeRows.slice(0, normalizedLimit)
    if (pageRows.length === 0) {
      return { changes: [], nextCursor: normalizedCursor, hasMore: false }
    }

    const entityIds = [...new Set(pageRows.map(row => String(row.entity_id)))]
    const placeholders = entityIds.map(() => '?').join(', ')
    const [birthdayRows] = await pool.execute(
      `${BIRTHDAY_SELECT}\nWHERE b.id IN (${placeholders})`,
      entityIds,
    )
    const rowsById = new Map(birthdayRows.map(row => [String(row.id), row]))
    if (entityIds.some(entityId => !rowsById.has(entityId))) {
      throw new MobileSyncDataConsistencyError()
    }
    const records = new Map(
      entityIds.map(entityId => [entityId, serializeBirthdayRow(rowsById.get(entityId))]),
    )
    const changes = pageRows.map(row => ({
      seq: decimalString(row.seq, 'sequence'),
      operation: row.operation,
      record: records.get(String(row.entity_id)),
    }))

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
    const connection = await pool.getConnection()
    let duplicateError = null
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
      } else {
        throw error
      }
    } finally {
      if (!destroyed) connection.release()
    }

    return recoverDuplicateOperation(deviceId, operation, duplicateError)
  }

  return { snapshot, pull, applyOperation }
}

module.exports = { createMobileSyncRepository }
