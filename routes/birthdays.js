const express = require('express')
const { query, pool } = require('../utils/db')
const { requireAuth } = require('../utils/auth')
const {
  formatDateForStorage,
  generateUUID,
  calculateNextSolarDate,
} = require('../utils/helpers')
const { timeToMinutes } = require('../utils/mobileSyncContract')
const {
  applyWebDelete,
  applyWebUpsert,
} = require('../services/birthdayMutationService')

function sanitizedError(error) {
  const details = {
    name: typeof error?.name === 'string' ? error.name : 'Error',
  }
  if (typeof error?.code === 'string') details.code = error.code
  return details
}

function logError(logger, ...args) {
  try {
    logger.error(...args)
  } catch {
    // 日志故障不能改变业务结果或连接处置。
  }
}

async function rollbackAndDispose(connection, primaryError, logger) {
  try {
    await connection.rollback()
    return false
  } catch (rollbackError) {
    const rollbackDetails = sanitizedError(rollbackError)
    try {
      Object.defineProperty(primaryError, 'rollbackFailure', {
        enumerable: false,
        value: rollbackDetails,
      })
    } catch {
      // 保留原始业务错误。
    }
    try {
      if (typeof connection.destroy === 'function') connection.destroy()
    } catch {
      // 已污染连接不得再放回连接池。
    }
    logError(logger, '回滚失败:', rollbackDetails)
    return true
  }
}

async function inTransaction(poolRef, work, logger) {
  const connection = await poolRef.getConnection()
  let destroyed = false
  try {
    await connection.beginTransaction()
    const result = await work(connection)
    await connection.commit()
    return result
  } catch (error) {
    destroyed = await rollbackAndDispose(connection, error, logger)
    throw error
  } finally {
    if (!destroyed) connection.release()
  }
}

function toSharedPayload(id, body) {
  return {
    id,
    name: body.name,
    lunarMonth: body.lunarMonth,
    lunarDay: body.lunarDay,
    isLeapMonth: body.isLeapMonth === true,
    reminderTimeMinutes: timeToMinutes(body.remindTime),
    notifyDayBefore: true,
    notifySameDay: true,
    emailEnabled: Boolean(body.userEmail),
    emailAddress: body.userEmail || '',
    emailMessage: body.message == null ? '' : String(body.message),
  }
}

function birthdayResponse(record, formatDateForStorageFn) {
  return {
    id: record.id,
    name: record.name,
    lunarMonth: record.lunarMonth,
    lunarDay: record.lunarDay,
    isLeapMonth: record.isLeapMonth,
    remindTime: record.remindTime,
    nextSolarDate: record.nextSolarDate
      ? formatDateForStorageFn(record.nextSolarDate)
      : null,
  }
}

function reminderResponse(record, formatDateForStorageFn, { includeId }) {
  const response = {
    email: record.userEmail,
    remind_time: record.emailReminderTime
      ? formatDateForStorageFn(record.emailReminderTime)
      : null,
    status: record.emailReminderStatus == null ? 0 : record.emailReminderStatus,
    message: record.message,
  }
  if (includeId) response.id = record.emailReminderId
  return response
}

function safeMutationDetails(error, fallback) {
  return error?.code === 'birthday_not_found' ? error.message : fallback
}

function hasRequiredWebFields(body) {
  return Boolean(body.name && body.userEmail && body.lunarMonth && body.lunarDay)
}

function createBirthdaysRouter({
  queryFn = query,
  poolRef = pool,
  requireAuthMiddleware = requireAuth,
  generateUUIDFn = generateUUID,
  formatDateForStorageFn = formatDateForStorage,
  calculateNextSolarDateFn = calculateNextSolarDate,
  applyWebUpsertFn = applyWebUpsert,
  applyWebDeleteFn = applyWebDelete,
  now = () => new Date(),
  logger = console,
} = {}) {
  const router = express.Router()
  router.use(requireAuthMiddleware)

  router.get('/list', async (req, res) => {
    try {
      const rows = await queryFn(
        `SELECT
           b.*,
           r.email AS userEmail,
           r.message AS message
         FROM birthdays b
         LEFT JOIN email_reminders r ON r.birthday_id = b.id
         WHERE b.deleted_at IS NULL`,
        [],
      )
      const formatted = rows.map(item => {
        const out = { ...item }
        if (item.nextSolarDate) {
          try {
            out.nextSolarDate = formatDateForStorageFn(item.nextSolarDate)
          } catch {
            out.nextSolarDate = null
          }
        } else {
          out.nextSolarDate = null
        }
        return out
      })
      return res.json(formatted)
    } catch (error) {
      logError(logger, '读取生日记录失败:', sanitizedError(error))
      return res.status(500).json({ error: '加载生日记录失败' })
    }
  })

  router.post('/', async (req, res) => {
    const { name, userEmail, lunarMonth, lunarDay } = req.body
    if (!hasRequiredWebFields({ name, userEmail, lunarMonth, lunarDay })) {
      return res.status(400).json({ error: '必填字段缺失（name/userEmail/lunarMonth/lunarDay）' })
    }

    const birthdayId = generateUUIDFn()
    const payload = toSharedPayload(birthdayId, req.body)
    let nextSolarDate
    try {
      nextSolarDate = calculateNextSolarDateFn({
        lunarMonth: req.body.lunarMonth,
        lunarDay: req.body.lunarDay,
        isLeapMonth: req.body.isLeapMonth,
        remindTime: req.body.remindTime,
      }, now())
    } catch (error) {
      return res.status(400).json({ error: '无法计算下一次提醒日期', details: error.message })
    }

    try {
      const record = await inTransaction(poolRef, connection => applyWebUpsertFn(connection, {
        id: birthdayId,
        payload,
        dateOptions: {
          nowInput: now(),
          calculateNextSolarDateFn: () => nextSolarDate,
        },
        generateUUIDFn,
      }), logger)
      return res.json({
        success: true,
        birthday: birthdayResponse(record, formatDateForStorageFn),
        emailReminder: reminderResponse(record, formatDateForStorageFn, { includeId: true }),
      })
    } catch (error) {
      logError(logger, '数据库事务失败:', sanitizedError(error))
      return res.status(500).json({ error: '数据库插入失败', details: '内部错误' })
    }
  })

  router.delete('/:id', async (req, res) => {
    try {
      await inTransaction(
        poolRef,
        connection => applyWebDeleteFn(connection, { id: req.params.id }),
        logger,
      )
      return res.json({ success: true, message: '删除成功' })
    } catch (error) {
      logError(logger, '删除操作失败:', sanitizedError(error))
      return res.status(500).json({
        error: '删除失败',
        details: safeMutationDetails(error, '内部错误'),
      })
    }
  })

  router.put('/:id', async (req, res) => {
    if (!hasRequiredWebFields(req.body)) {
      return res.status(400).json({ error: '必填字段缺失（name/userEmail/lunarMonth/lunarDay）' })
    }
    const payload = toSharedPayload(req.params.id, req.body)
    let nextSolarDate
    try {
      nextSolarDate = calculateNextSolarDateFn({
        lunarMonth: req.body.lunarMonth,
        lunarDay: req.body.lunarDay,
        isLeapMonth: req.body.isLeapMonth,
        remindTime: req.body.remindTime,
      }, now())
    } catch (error) {
      return res.status(400).json({ error: '无法计算下一次提醒日期', details: error.message })
    }

    try {
      const record = await inTransaction(poolRef, connection => applyWebUpsertFn(connection, {
        id: req.params.id,
        payload,
        dateOptions: {
          nowInput: now(),
          calculateNextSolarDateFn: () => nextSolarDate,
        },
        generateUUIDFn,
      }), logger)
      return res.json({
        success: true,
        birthday: birthdayResponse(record, formatDateForStorageFn),
        emailReminder: reminderResponse(record, formatDateForStorageFn, { includeId: false }),
      })
    } catch (error) {
      logError(logger, '更新生日记录失败:', sanitizedError(error))
      return res.status(500).json({ error: '更新生日记录失败' })
    }
  })

  return router
}

const router = createBirthdaysRouter()
module.exports = router
module.exports.createBirthdaysRouter = createBirthdaysRouter
