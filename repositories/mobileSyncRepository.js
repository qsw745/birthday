const {
  decimalString,
  normalizeCursor,
  normalizeLimit,
  serializeBirthdayRow,
} = require('../utils/mobileSyncContract')

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

function requireUsername(username) {
  if (typeof username !== 'string' || username.trim().length === 0) {
    const error = new TypeError('username is required for the single-admin snapshot')
    error.code = 'invalid_username'
    throw error
  }
}

function createMobileSyncRepository({ pool }) {
  async function snapshot(username) {
    requireUsername(username)
    const connection = await pool.getConnection()
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
      try {
        await connection.rollback()
      } catch {
        // Preserve the operation error while still releasing the connection.
      }
      throw error
    } finally {
      connection.release()
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
         AND seq > ?
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
    const records = new Map(
      birthdayRows.map(row => [String(row.id), serializeBirthdayRow(row)]),
    )
    const changes = pageRows.map(row => ({
      seq: decimalString(row.seq, 'sequence'),
      operation: row.operation,
      record: records.get(String(row.entity_id)) || null,
    }))

    return {
      changes,
      nextCursor: changes.at(-1).seq,
      hasMore: changeRows.length > normalizedLimit,
    }
  }

  return { snapshot, pull }
}

module.exports = { createMobileSyncRepository }
