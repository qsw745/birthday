const express = require('express')
const schedule = require('node-schedule')
const { query, pool, formatDate } = require('../utils/db')
const { generateUUID } = require('../utils/helpers')
const { requireAuth } = require('../utils/auth')
const { buildBirthdayEmailHtml } = require('../utils/emailTemplate')
const {
  applyWebDelete,
  applyWebReminderUpsert,
} = require('../services/birthdayMutationService')

const ACTIVE_REMINDER_JOIN = 'JOIN birthdays b ON b.id = r.birthday_id'

function sanitizedError(error) {
  const details = { name: typeof error?.name === 'string' ? error.name : 'Error' }
  if (typeof error?.code === 'string') details.code = error.code
  return details
}

function logSafely(logger, method, ...args) {
  try {
    logger[method](...args)
  } catch {
    // 日志故障不能改变业务结果或连接处置。
  }
}

function logError(logger, ...args) {
  logSafely(logger, 'error', ...args)
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

function safeDetails(error, fallback = '内部错误') {
  if (error?.code === 'birthday_not_found') return error.message
  if (error?.code === 'email_reminder_not_found') return error.message
  return fallback
}

function createReminderRuntime({
  queryFn,
  formatDateFn,
  scheduleRef,
  transporterRef,
  buildBirthdayEmailHtmlFn,
  generateClaimTokenFn,
  now,
  logger,
}) {
  async function sendReminderEmail(
    reminder,
    expectedRemindTime = reminder.remind_time,
    expectedGeneration = reminder.generation,
  ) {
    const claimToken = generateClaimTokenFn()
    const claim = await queryFn(
      `UPDATE email_reminders r
       ${ACTIVE_REMINDER_JOIN}
          SET r.claim_token = ?,
              r.claim_generation = ?,
              r.claim_remind_time = ?,
              r.claimed_at = NOW()
        WHERE r.id = ?
          AND r.remind_time = ?
          AND r.generation = ?
          AND r.remind_time <= NOW()
          AND r.status = 0
          AND (
            r.claim_token IS NULL
            OR r.claimed_at IS NULL
            OR r.claimed_at < DATE_SUB(NOW(), INTERVAL 15 MINUTE)
          )
          AND b.deleted_at IS NULL`,
      [
        claimToken,
        expectedGeneration,
        expectedRemindTime,
        reminder.id,
        expectedRemindTime,
        expectedGeneration,
      ],
    )
    if (!claim.affectedRows) {
      return { sent: false, settled: false, reason: 'not_claimed' }
    }

    const mailOptions = {
      from: process.env.SMTP_FROM || process.env.SMTP_USER,
      to: reminder.email,
      subject: `🎂 ${reminder.name}的生日提醒`,
      text: reminder.message,
      html: buildBirthdayEmailHtmlFn(reminder),
    }

    try {
      await transporterRef.sendMail(mailOptions)
    } catch (error) {
      try {
        await queryFn(
          `UPDATE email_reminders r
           ${ACTIVE_REMINDER_JOIN}
              SET r.claim_token = NULL,
                  r.claim_generation = NULL,
                  r.claim_remind_time = NULL,
                  r.claimed_at = NULL
            WHERE r.id = ?
              AND r.claim_token = ?
              AND r.claim_generation = ?
              AND r.claim_remind_time = ?
              AND b.deleted_at IS NULL`,
          [reminder.id, claimToken, expectedGeneration, expectedRemindTime],
        )
      } catch (resetError) {
        logError(logger, '[email] reset status failed:', reminder.id, sanitizedError(resetError))
      }
      logError(logger, '[email] send failed:', reminder.id, sanitizedError(error))
      return { sent: false, settled: false, reason: 'smtp_failed' }
    }

    let settlement
    try {
      settlement = await queryFn(
        `UPDATE email_reminders r
         ${ACTIVE_REMINDER_JOIN}
            SET r.delivered_remind_time = ?,
                r.status = IF(r.remind_time = ?, 1, 0),
                r.claim_token = NULL,
                r.claim_generation = NULL,
                r.claim_remind_time = NULL,
                r.claimed_at = NULL
          WHERE r.id = ?
            AND r.claim_token = ?
            AND r.claim_generation = ?
            AND r.claim_remind_time = ?
            AND b.deleted_at IS NULL`,
        [
          expectedRemindTime,
          expectedRemindTime,
          reminder.id,
          claimToken,
          expectedGeneration,
          expectedRemindTime,
        ],
      )
    } catch (settleError) {
      logError(logger, '[email] success settlement failed:', reminder.id, sanitizedError(settleError))
      return { sent: true, settled: false }
    }
    if (settlement.affectedRows === 1) {
      logSafely(logger, 'log', '[email] SMTP 已完成并结算送达:', reminder.id)
      return { sent: true, settled: true }
    }
    logSafely(logger, 'warn', '[email] SMTP 已完成但 claim 已替换或未结算:', reminder.id)
    return { sent: true, settled: false }
  }

  function registerOneTimeJob(id, runAt, expectedRemindTime, expectedGeneration) {
    return scheduleRef.scheduleJob(runAt, async () => {
      try {
        const rows = await queryFn(
          `SELECT r.*
             FROM email_reminders r
             ${ACTIVE_REMINDER_JOIN}
            WHERE r.id = ?
              AND r.remind_time = ?
              AND r.generation = ?
              AND r.remind_time <= NOW()
              AND r.status = 0
              AND b.deleted_at IS NULL`,
          [id, expectedRemindTime, expectedGeneration],
        )
        const row = rows[0]
        if (!row) return
        await sendReminderEmail(row, expectedRemindTime, expectedGeneration)
      } catch (error) {
        logError(logger, '[schedule] reminder callback failed:', id, sanitizedError(error))
      }
    })
  }

  async function runDueReminderPoll() {
    try {
      const reminders = await queryFn(
        `SELECT r.*
           FROM email_reminders r
           ${ACTIVE_REMINDER_JOIN}
          WHERE r.status = 0
            AND r.remind_time <= NOW()
            AND b.deleted_at IS NULL`,
      )
      const results = []
      for (const reminder of reminders) {
        results.push(await sendReminderEmail(reminder, reminder.remind_time, reminder.generation))
      }
      return results
    } catch (error) {
      logError(logger, '[cron] batch send failed:', sanitizedError(error))
      return []
    }
  }

  async function reschedulePendingReminders() {
    try {
      const nowStr = formatDateFn(now())
      const reminders = await queryFn(
        `SELECT r.*
           FROM email_reminders r
           ${ACTIVE_REMINDER_JOIN}
          WHERE r.status = 0
            AND r.remind_time > ?
            AND b.deleted_at IS NULL`,
        [nowStr],
      )

      for (const reminder of reminders) {
        const runAt = new Date(reminder.remind_time)
        if (Number.isNaN(runAt.getTime())) {
          logSafely(logger, 'warn', '[reschedule] invalid remind_time, skip:', reminder.id, reminder.remind_time)
          continue
        }
        registerOneTimeJob(reminder.id, runAt, reminder.remind_time, reminder.generation)
        logSafely(logger, 'log', '[reschedule] job restored for', reminder.id, runAt.toISOString())
      }
    } catch (error) {
      logError(logger, '[reschedule] failed:', sanitizedError(error))
    }
  }

  return {
    registerOneTimeJob,
    reschedulePendingReminders,
    runDueReminderPoll,
  }
}

function runtimeOptions({
  queryFn = query,
  formatDateFn = formatDate,
  scheduleRef = schedule,
  transporterRef,
  buildBirthdayEmailHtmlFn = buildBirthdayEmailHtml,
  generateClaimTokenFn = generateUUID,
  now = () => new Date(),
  logger = console,
} = {}) {
  return {
    queryFn,
    formatDateFn,
    scheduleRef,
    transporterRef: transporterRef || require('../utils/emailConfig'),
    buildBirthdayEmailHtmlFn,
    generateClaimTokenFn,
    now,
    logger,
  }
}

function createEmailRemindersRouter({
  queryFn = query,
  poolRef = pool,
  formatDateFn = formatDate,
  generateUUIDFn = generateUUID,
  requireAuthMiddleware = requireAuth,
  scheduleRef = schedule,
  transporterRef,
  buildBirthdayEmailHtmlFn = buildBirthdayEmailHtml,
  generateClaimTokenFn = generateUUID,
  applyWebDeleteFn = applyWebDelete,
  applyWebReminderUpsertFn = applyWebReminderUpsert,
  now = () => new Date(),
  logger = console,
} = {}) {
  const router = express.Router()
  const runtime = createReminderRuntime(runtimeOptions({
    queryFn,
    formatDateFn,
    scheduleRef,
    transporterRef,
    buildBirthdayEmailHtmlFn,
    generateClaimTokenFn,
    now,
    logger,
  }))
  router.use(requireAuthMiddleware)

  router.post('/', async (req, res) => {
    const { name, email, remindTime, message, birthdayId } = req.body
    const remindAt = new Date(remindTime)
    if (Number.isNaN(remindAt.getTime())) {
      return res.status(400).json({ error: 'remindTime 无法解析为有效时间' })
    }

    const id = generateUUIDFn()
    const scheduleTimeStr = formatDateFn(remindAt)
    try {
      const record = await inTransaction(poolRef, connection => applyWebReminderUpsertFn(connection, {
        birthdayId,
        reminder: {
          id,
          name,
          email,
          remindTime: scheduleTimeStr,
          message,
        },
      }), logger)

      if (remindAt.getTime() > now().getTime()) {
        const reminderId = record.emailReminderId || id
        runtime.registerOneTimeJob(
          reminderId,
          remindAt,
          scheduleTimeStr,
          record.emailReminderGeneration,
        )
        logSafely(logger, 'log', '[schedule] job registered for', reminderId, remindAt.toISOString())
      } else {
        logSafely(logger, 'log', '[schedule] remindTime is in the past; will be handled by cron worker.')
      }
      return res.json({
        success: true,
        id: record.emailReminderId || id,
        scheduledTime: scheduleTimeStr,
      })
    } catch (error) {
      logError(logger, '[create reminder] failed', sanitizedError(error))
      return res.status(500).json({ error: '数据库错误', details: safeDetails(error) })
    }
  })

  router.delete('/:id', async (req, res) => {
    try {
      await inTransaction(poolRef, async connection => {
        const [rows] = await connection.query(
          'SELECT birthday_id FROM email_reminders WHERE id = ?',
          [req.params.id],
        )
        const reminder = rows[0]
        if (!reminder) {
          const error = new Error('没有找到要删除的邮件提醒')
          error.code = 'email_reminder_not_found'
          throw error
        }
        await applyWebDeleteFn(connection, { id: reminder.birthday_id })
      }, logger)
      return res.json({ success: true, message: '删除成功' })
    } catch (error) {
      logError(logger, '删除操作失败:', sanitizedError(error))
      return res.status(500).json({ error: '删除失败', details: safeDetails(error) })
    }
  })

  return router
}

function registerEmailReminderSchedulers(options = {}) {
  const resolved = runtimeOptions(options)
  const runtime = createReminderRuntime(resolved)
  const pollJob = resolved.scheduleRef.scheduleJob('*/1 * * * *', runtime.runDueReminderPoll)
  return {
    pollJob,
    ready: runtime.reschedulePendingReminders(),
  }
}

module.exports = {
  createEmailRemindersRouter,
  registerEmailReminderSchedulers,
}
