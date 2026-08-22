const { generateUUID } = require('../utils/helpers')
const {
  INT64_MAX_DECIMAL,
  assertAPIBirthdayChange,
  decimalString,
  invalidBirthdayPayload,
  isNormalizedPushOperation,
  normalizeBirthdayPayload,
  normalizePushRequest,
  serializeBirthdayRow,
} = require('../utils/mobileSyncContract')

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
            CAST(base_version AS CHAR) AS base_version,
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
    || decimalString(stored.base_version, 'stored base version') !== operation.baseVersion
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
  const normalizedCurrent = decimalString(currentVersion, 'birthday version')
  if (normalizedCurrent === INT64_MAX_DECIMAL) {
    const error = new RangeError('mobile sync birthday version overflow')
    error.code = 'mobile_sync_version_overflow'
    throw error
  }
  return (BigInt(normalizedCurrent) + 1n).toString(10)
}

async function storeOperationResponse(connection, { deviceId, operation, response }) {
  try {
    await connection.query(
      `INSERT INTO mobile_sync_operations (operation_id, device_id, base_version, response_json)
       VALUES (?, ?, ?, ?)`,
      [operation.operationId, deviceId, operation.baseVersion, JSON.stringify(response)],
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

async function appendChange(connection, operation, record) {
  assertAPIBirthdayChange({
    entityId: operation.entityId,
    operation: operation.type,
    entityVersion: record.version,
    record,
  })
  await connection.query(
    `INSERT INTO mobile_sync_changes
      (entity_type, entity_id, operation, entity_version, record_json)
     VALUES (?, ?, ?, ?, ?)`,
    ['birthday', operation.entityId, operation.type, record.version, JSON.stringify(record)],
  )
}

function birthdayNotFound(message = '没有找到对应的生日记录') {
  const error = new Error(message)
  error.code = 'birthday_not_found'
  return error
}

function databaseBoolean(value) {
  return value === true || value === 1 || value === '1'
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
  const entityId = String(id || '').toLowerCase()
  const currentRow = await readBirthday(connection, entityId, { forUpdate: true })
  const normalizedPayload = normalizeBirthdayPayload({
    ...payload,
    id: entityId,
    notifyDayBefore: typeof payload.notifyDayBefore === 'boolean'
      ? payload.notifyDayBefore
      : currentRow
        ? databaseBoolean(currentRow.notify_day_before)
        : true,
    notifySameDay: typeof payload.notifySameDay === 'boolean'
      ? payload.notifySameDay
      : currentRow
        ? databaseBoolean(currentRow.notify_same_day)
        : true,
  }, dateOptions)
  const operation = {
    entityId: normalizedPayload.id,
    type: 'upsert',
    payload: normalizedPayload,
  }
  const version = nextVersion(currentRow ? String(currentRow.version) : '0')

  await upsertBirthday(connection, operation, currentRow, version, { generateUUIDFn })
  const storedRow = await requireStoredBirthday(connection, operation.entityId)
  await appendChange(connection, operation, serializeBirthdayRow(storedRow))
  return serializeWebBirthdayRow(storedRow)
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
  const storedRow = await requireStoredBirthday(connection, entityId)
  await appendChange(connection, operation, serializeBirthdayRow(storedRow))
  return serializeWebBirthdayRow(storedRow)
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
  const storedRow = await requireStoredBirthday(connection, entityId)
  await appendChange(connection, { entityId, type: 'upsert' }, serializeBirthdayRow(storedRow))
  return serializeWebBirthdayRow(storedRow)
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
  const storedRow = await readBirthday(connection, operation.entityId)
  if (!storedRow) {
    const error = new Error('birthday missing after mobile mutation')
    error.code = 'mobile_sync_inconsistent_state'
    throw error
  }
  const record = serializeBirthdayRow(storedRow)
  await appendChange(connection, operation, record)
  const response = {
    operationId: operation.operationId,
    status: 'applied',
    record,
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
