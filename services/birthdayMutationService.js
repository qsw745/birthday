const { generateUUID } = require('../utils/helpers')
const {
  invalidBirthdayPayload,
  isNormalizedPushOperation,
  normalizePushRequest,
  serializeBirthdayRow,
} = require('../utils/mobileSyncContract')

const UINT64_MAX = 18446744073709551615n

const BIRTHDAY_BY_ID_SELECT = `SELECT
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
LEFT JOIN email_reminders r ON r.birthday_id = b.id
WHERE b.id = ?`

function parseStoredResponse(value) {
  if (Buffer.isBuffer(value)) value = value.toString('utf8')
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value)
    } catch {
      throw invalidBirthdayPayload()
    }
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw invalidBirthdayPayload()
  }
  return value
}

function responseEntityId(response) {
  return response.record?.id || response.remote?.id || null
}

async function readStoredOperation(connection, { deviceId, operation }) {
  const [rows] = await connection.query(
    `SELECT operation_id,
            device_id,
            COALESCE(
              JSON_UNQUOTE(JSON_EXTRACT(response_json, '$.record.id')),
              JSON_UNQUOTE(JSON_EXTRACT(response_json, '$.remote.id'))
            ) AS entity_id,
            response_json
       FROM mobile_sync_operations
      WHERE operation_id = ?`,
    [operation.operationId],
  )
  const stored = rows[0]
  if (!stored) return null

  const response = parseStoredResponse(stored.response_json)
  const storedEntityId = stored.entity_id || responseEntityId(response)
  if (
    stored.device_id !== deviceId
    || storedEntityId !== operation.entityId
    || response.operationId !== operation.operationId
  ) {
    throw invalidBirthdayPayload()
  }
  return response
}

async function readBirthday(connection, entityId, { forUpdate = false } = {}) {
  const [rows] = await connection.query(
    `${BIRTHDAY_BY_ID_SELECT}${forUpdate ? '\nFOR UPDATE' : ''}`,
    [entityId],
  )
  return rows[0] || null
}

function nextVersion(currentVersion) {
  const next = BigInt(currentVersion) + 1n
  if (next > UINT64_MAX) {
    const error = new RangeError('mobile sync birthday version overflow')
    error.code = 'mobile_sync_version_overflow'
    throw error
  }
  return next.toString(10)
}

async function storeOperationResponse(connection, { deviceId, operation, response }) {
  try {
    await connection.query(
      `INSERT INTO mobile_sync_operations (operation_id, device_id, response_json)
       VALUES (?, ?, ?)`,
      [operation.operationId, deviceId, JSON.stringify(response)],
    )
  } catch (error) {
    if (error && error.code === 'ER_DUP_ENTRY') {
      error.mobileOperationResponseDuplicate = true
    }
    throw error
  }
}

async function persistConflict(connection, context, remoteRow) {
  const response = {
    operationId: context.operation.operationId,
    status: 'conflict',
    remote: remoteRow ? serializeBirthdayRow(remoteRow) : null,
  }
  await storeOperationResponse(connection, { ...context, response })
  return response
}

async function upsertBirthday(connection, operation, currentRow, version) {
  const payload = operation.payload
  const nextSolarDate = payload.nextSolarDate
  const birthdayParams = [
    payload.name,
    payload.lunarMonth,
    payload.lunarDay,
    payload.isLeapMonth ? 1 : 0,
    payload.remindTime,
    nextSolarDate,
    version,
    payload.notifyDayBefore ? 1 : 0,
    payload.notifySameDay ? 1 : 0,
  ]

  if (currentRow) {
    await connection.query(
      `UPDATE birthdays
          SET name = ?, lunarMonth = ?, lunarDay = ?, isLeapMonth = ?,
              remindTime = ?, nextSolarDate = ?, version = ?, deleted_at = NULL,
              notify_day_before = ?, notify_same_day = ?
        WHERE id = ?`,
      [...birthdayParams, operation.entityId],
    )
  } else {
    await connection.query(
      `INSERT INTO birthdays
        (id, name, lunarMonth, lunarDay, isLeapMonth, remindTime, nextSolarDate,
         version, deleted_at, notify_day_before, notify_same_day)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)`,
      [operation.entityId, ...birthdayParams],
    )
  }

  if (payload.emailEnabled) {
    await connection.query(
      `INSERT INTO email_reminders
        (id, birthday_id, name, email, remind_time, message, status)
       VALUES (?, ?, ?, ?, ?, ?, 0)
       ON DUPLICATE KEY UPDATE
         name = VALUES(name), email = VALUES(email),
         remind_time = VALUES(remind_time), message = VALUES(message), status = 0`,
      [
        generateUUID(),
        operation.entityId,
        payload.name,
        payload.emailAddress,
        nextSolarDate,
        `${payload.name}${payload.emailMessage}`,
      ],
    )
  } else {
    await connection.query(
      'DELETE FROM email_reminders WHERE birthday_id = ?',
      [operation.entityId],
    )
  }
}

async function softDeleteBirthday(connection, operation, version) {
  await connection.query(
    `UPDATE birthdays
        SET deleted_at = CURRENT_TIMESTAMP, version = ?
      WHERE id = ?`,
    [version, operation.entityId],
  )
  await connection.query(
    'DELETE FROM email_reminders WHERE birthday_id = ?',
    [operation.entityId],
  )
}

async function appendChange(connection, operation, version) {
  await connection.query(
    `INSERT INTO mobile_sync_changes (entity_type, entity_id, operation, version)
     VALUES (?, ?, ?, ?)`,
    ['birthday', operation.entityId, operation.type, version],
  )
}

async function applyMobileOperation(connection, context) {
  const operation = isNormalizedPushOperation(context.operation)
    ? context.operation
    : normalizePushRequest({ operations: [context.operation] }).operations[0]
  const normalizedContext = { ...context, operation }
  const replay = await readStoredOperation(connection, normalizedContext)
  if (replay) return replay

  const currentRow = await readBirthday(connection, operation.entityId, { forUpdate: true })
  const currentVersion = currentRow ? String(currentRow.version) : '0'
  if (!currentRow && (operation.baseVersion !== '0' || operation.type !== 'upsert')) {
    const error = new Error('current birthday row missing for mobile mutation')
    error.code = 'mobile_sync_inconsistent_state'
    throw error
  }
  if (currentVersion !== operation.baseVersion) {
    return persistConflict(connection, normalizedContext, currentRow)
  }

  const version = nextVersion(currentVersion)
  if (operation.type === 'upsert') {
    await upsertBirthday(connection, operation, currentRow, version)
  } else {
    await softDeleteBirthday(connection, operation, version)
  }
  await appendChange(connection, operation, version)

  const storedRow = await readBirthday(connection, operation.entityId)
  if (!storedRow) {
    const error = new Error('birthday missing after mobile mutation')
    error.code = 'mobile_sync_inconsistent_state'
    throw error
  }
  const response = {
    operationId: operation.operationId,
    status: 'applied',
    record: serializeBirthdayRow(storedRow),
  }
  await storeOperationResponse(connection, { ...normalizedContext, response })
  return response
}

module.exports = {
  applyMobileOperation,
  readStoredOperation,
}
