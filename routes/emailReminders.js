const express = require('express')
const schedule = require('node-schedule')
const { query, pool, formatDate } = require('../utils/db')
const { generateUUID } = require('../utils/helpers')
const { requireAuth } = require('../utils/auth')
const transporter = require('../utils/emailConfig')
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

async function rollbackAndDispose(connection, primaryError) {
  try {
    await connection.rollback()
    return false
  } catch (rollbackError) {
    try {
      Object.defineProperty(primaryError, 'rollbackFailure', {
        enumerable: false,
        value: sanitizedError(rollbackError),
      })
    } catch {
      // 保留原始业务错误。
    }
    try {
      if (typeof connection.destroy === 'function') connection.destroy()
    } catch {
      // 已污染连接不得再放回连接池。
    }
    return true
  }
}

async function inTransaction(poolRef, work) {
  const connection = await poolRef.getConnection()
  let destroyed = false
  try {
    await connection.beginTransaction()
    const result = await work(connection)
    await connection.commit()
    return result
  } catch (error) {
    destroyed = await rollbackAndDispose(connection, error)
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

function createEmailRemindersRouter({
  queryFn = query,
  poolRef = pool,
  formatDateFn = formatDate,
  generateUUIDFn = generateUUID,
  requireAuthMiddleware = requireAuth,
  scheduleRef = schedule,
  transporterRef = transporter,
  buildBirthdayEmailHtmlFn = buildBirthdayEmailHtml,
  applyWebDeleteFn = applyWebDelete,
  applyWebReminderUpsertFn = applyWebReminderUpsert,
  now = () => new Date(),
  startSchedulers = true,
} = {}) {
  const router = express.Router()
  router.use(requireAuthMiddleware)

  async function sendReminderEmail(reminder) {
    const claim = await queryFn(
      `UPDATE email_reminders r
       ${ACTIVE_REMINDER_JOIN}
          SET r.status = 1
        WHERE r.id = ?
          AND r.status = 0
          AND b.deleted_at IS NULL`,
      [reminder.id],
    )
    if (!claim.affectedRows) return

    const mailOptions = {
      from: process.env.SMTP_FROM || process.env.SMTP_USER,
      to: reminder.email,
      subject: `🎂 ${reminder.name}的生日提醒`,
      text: reminder.message,
      html: buildBirthdayEmailHtmlFn(reminder),
    }

    try {
      await transporterRef.sendMail(mailOptions)
      console.log('[email] sent & marked delivered:', reminder.id)
    } catch (error) {
      console.error('[email] send failed:', reminder.id, sanitizedError(error))
      try {
        await queryFn(
          `UPDATE email_reminders r
           ${ACTIVE_REMINDER_JOIN}
              SET r.status = 0
            WHERE r.id = ?
              AND b.deleted_at IS NULL`,
          [reminder.id],
        )
      } catch (resetError) {
        console.error('[email] reset status failed:', reminder.id, sanitizedError(resetError))
      }
    }
  }

  function registerOneTimeJob(id, runAt) {
    scheduleRef.scheduleJob(runAt, async () => {
      try {
        const rows = await queryFn(
          `SELECT r.*
             FROM email_reminders r
             ${ACTIVE_REMINDER_JOIN}
            WHERE r.id = ?
              AND b.deleted_at IS NULL`,
          [id],
        )
        const row = rows[0]
        if (!row || row.status === 1) return
        await sendReminderEmail(row)
      } catch (error) {
        console.error('[schedule] reminder callback failed:', id, sanitizedError(error))
      }
    })
  }

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
      }))

      if (remindAt.getTime() > now().getTime()) {
        registerOneTimeJob(record.emailReminderId || id, remindAt)
        console.log('[schedule] job registered for', record.emailReminderId || id, remindAt.toISOString())
      } else {
        console.log('[schedule] remindTime is in the past; will be handled by cron worker.')
      }
      return res.json({
        success: true,
        id: record.emailReminderId || id,
        scheduledTime: scheduleTimeStr,
      })
    } catch (error) {
      console.error('[create reminder] failed', sanitizedError(error))
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
      })
      return res.json({ success: true, message: '删除成功' })
    } catch (error) {
      console.error('删除操作失败:', sanitizedError(error))
      return res.status(500).json({ error: '删除失败', details: safeDetails(error) })
    }
  })

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
      for (const reminder of reminders) await sendReminderEmail(reminder)
    } catch (error) {
      console.error('[cron] batch send failed:', sanitizedError(error))
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
          console.warn('[reschedule] invalid remind_time, skip:', reminder.id, reminder.remind_time)
          continue
        }
        registerOneTimeJob(reminder.id, runAt)
        console.log('[reschedule] job restored for', reminder.id, runAt.toISOString())
      }
    } catch (error) {
      console.error('[reschedule] failed:', sanitizedError(error))
    }
  }

  if (startSchedulers) {
    scheduleRef.scheduleJob('*/1 * * * *', runDueReminderPoll)
    router.schedulerReady = reschedulePendingReminders()
  } else {
    router.schedulerReady = Promise.resolve()
  }

  return router
}

const router = createEmailRemindersRouter()
module.exports = router
module.exports.createEmailRemindersRouter = createEmailRemindersRouter
