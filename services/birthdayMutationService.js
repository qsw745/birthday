const { generateUUID } = require('../utils/helpers')
const {
  invalidBirthdayPayload,
  isNormalizedPushOperation,
  normalizeBirthdayPayload,
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
  r.message AS message,
  r.id AS emailReminderId,
  r.remind_time AS emailReminderTime,
  r.status AS emailReminderStatus,
  r.generation AS emailReminderGeneration
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

async function upsertEmailReminder(connection, {
  id,
  birthdayId,
  name,
  email,
  remindTime,
  message,
  scheduleMode,
}) {
  await connection.query(
    `INSERT INTO email_reminders
      (id, birthday_id, name, email, remind_time, message, status, schedule_mode, generation)
     VALUES (?, ?, ?, ?, ?, ?, 0, ?, UUID())
     ON DUPLICATE KEY UPDATE
       name = VALUES(name), email = VALUES(email),
       remind_time = VALUES(remind_time), message = VALUES(message),
       status = IF(delivered_remind_time = VALUES(remind_time), 1, 0),
       schedule_mode = VALUES(schedule_mode), generation = UUID()`,
    [id, birthdayId, name, email, remindTime, message, scheduleMode],
  )
}

async function upsertBirthday(connection, operation, currentRow, version, {
  generateUUIDFn = generateUUID,
} = {}) {
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
    try {
      await connection.query(
        `INSERT INTO birthdays
          (id, name, lunarMonth, lunarDay, isLeapMonth, remindTime, nextSolarDate,
           version, deleted_at, notify_day_before, notify_same_day)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)`,
        [operation.entityId, ...birthdayParams],
      )
    } catch (error) {
      if (error && error.code === 'ER_DUP_ENTRY') {
        Object.defineProperty(error, 'mobileBirthdayInsertRace', { value: true })
      }
      throw error
    }
  }

  if (payload.emailEnabled) {
    await upsertEmailReminder(connection, {
      id: generateUUIDFn(),
      birthdayId: operation.entityId,
      name: payload.name,
      email: payload.emailAddress,
      remindTime: nextSolarDate,
      message: `${payload.name}${payload.emailMessage}`,
      scheduleMode: 'derived',
    })
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

function birthdayNotFound(message = '没有找到对应的生日记录') {
  const error = new Error(message)
  error.code = 'birthday_not_found'
  return error
}

function serializeWebBirthdayRow(row) {
  return {
    id: row.id,
    name: row.name,
    lunarMonth: Number(row.lunarMonth),
    lunarDay: Number(row.lunarDay),
    isLeapMonth: row.isLeapMonth === true || row.isLeapMonth === 1 || row.isLeapMonth === '1',
    remindTime: row.remindTime || null,
    nextSolarDate: row.nextSolarDate || null,
    version: String(row.version),
    deletedAt: row.deleted_at || null,
    userEmail: row.userEmail || '',
    message: row.message || '',
    emailReminderId: row.emailReminderId || null,
    emailReminderTime: row.emailReminderTime || null,
    emailReminderStatus: row.emailReminderStatus == null ? null : Number(row.emailReminderStatus),
    emailReminderGeneration: row.emailReminderGeneration || null,
  }
}

async function requireStoredBirthday(connection, entityId) {
  const storedRow = await readBirthday(connection, entityId)
  if (!storedRow) {
    const error = new Error('birthday missing after web mutation')
    error.code = 'mobile_sync_inconsistent_state'
    throw error
  }
  return storedRow
}

async function applyWebUpsert(connection, {
  id,
  payload,
  dateOptions,
  generateUUIDFn = generateUUID,
}) {
  const normalizedPayload = normalizeBirthdayPayload({ ...payload, id }, dateOptions)
  const operation = {
    entityId: normalizedPayload.id,
    type: 'upsert',
    payload: normalizedPayload,
  }
  const currentRow = await readBirthday(connection, operation.entityId, { forUpdate: true })
  const version = nextVersion(currentRow ? String(currentRow.version) : '0')

  await upsertBirthday(connection, operation, currentRow, version, { generateUUIDFn })
  await appendChange(connection, operation, version)
  return serializeWebBirthdayRow(await requireStoredBirthday(connection, operation.entityId))
}

async function applyWebDelete(connection, { id }) {
  const entityId = String(id || '').toLowerCase()
  const currentRow = await readBirthday(connection, entityId, { forUpdate: true })
  if (!currentRow || currentRow.deleted_at) {
    throw birthdayNotFound('没有找到要删除的生日记录')
  }

  const version = nextVersion(String(currentRow.version))
  const operation = { entityId, type: 'delete' }
  await softDeleteBirthday(connection, operation, version)
  await appendChange(connection, operation, version)
  return serializeWebBirthdayRow(await requireStoredBirthday(connection, entityId))
}

async function applyWebReminderUpsert(connection, {
  birthdayId,
  reminder,
}) {
  const entityId = String(birthdayId || '').toLowerCase()
  const currentRow = await readBirthday(connection, entityId, { forUpdate: true })
  if (!currentRow || currentRow.deleted_at) throw birthdayNotFound()

  const version = nextVersion(String(currentRow.version))
  await connection.query(
    'UPDATE birthdays SET version = ? WHERE id = ? AND deleted_at IS NULL',
    [version, entityId],
  )
  await upsertEmailReminder(connection, {
    id: reminder.id,
    birthdayId: entityId,
    name: reminder.name,
    email: reminder.email,
    remindTime: reminder.remindTime,
    message: reminder.message,
    scheduleMode: 'exact',
  })
  await appendChange(connection, { entityId, type: 'upsert' }, version)
  return serializeWebBirthdayRow(await requireStoredBirthday(connection, entityId))
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
  applyWebDelete,
  applyWebReminderUpsert,
  applyWebUpsert,
  readStoredOperation,
}
