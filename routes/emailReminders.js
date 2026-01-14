// routes/emailReminders.js
const express = require('express')
const router = express.Router()
const schedule = require('node-schedule')
const { query, pool, formatDate } = require('../utils/db')
const { generateUUID } = require('../utils/helpers')
const transporter = require('../utils/emailConfig') // 邮件服务配置

// 统一的发送逻辑：发邮件 -> 成功则更新状态
async function sendReminderEmail(reminder) {
  const mailOptions = {
    from: 'qishiwei745@163.com',
    to: reminder.email,
    subject: `${reminder.name}的生日提醒`,
    text: reminder.message,
  }

  try {
    await transporter.sendMail(mailOptions)
    await query('UPDATE email_reminders SET status = 1 WHERE id = ?', [reminder.id])
    console.log('[email] sent & marked delivered:', reminder.id)
  } catch (err) {
    console.error('[email] send failed:', reminder.id, err)
    // 失败不抛出，以免把调度器打挂；可以在此记录失败原因到表里（可选）
  }
}

// 创建邮件提醒
router.post('/', async (req, res) => {
  const { name, email, remindTime, message, birthdayId } = req.body

  // 后端强制把提醒时间解析为 Date（用于调度）；写库时仍可用 formatDate
  const remindAt = new Date(remindTime)
  if (Number.isNaN(remindAt.getTime())) {
    return res.status(400).json({ error: 'remindTime 无法解析为有效时间' })
  }

  const id = generateUUID()
  const scheduleTimeStr = formatDate(remindAt) // 存库用的 'yyyy-MM-dd HH:mm:ss'

  const reminderData = {
    id,
    name,
    email,
    remind_time: scheduleTimeStr,
    message,
    status: 0,
    birthday_id: birthdayId,
  }

  try {
    // 1) 入库
    await query('INSERT INTO email_reminders SET ?', [reminderData])

    // 2) 调度（未来时间才调度；过去时间交给每分钟轮询）
    const now = new Date()
    if (remindAt.getTime() > now.getTime()) {
      schedule.scheduleJob(remindAt, async () => {
        // 最新化读取（防止状态早被轮询发掉）
        const [row] = await query('SELECT * FROM email_reminders WHERE id = ?', [id])
        if (!row || row.status === 1) return // 已处理
        await sendReminderEmail(row)
      })
      console.log('[schedule] job registered for', id, remindAt.toISOString())
    } else {
      console.log('[schedule] remindTime is in the past; will be handled by cron worker.')
    }

    res.json({ success: true, id, scheduledTime: scheduleTimeStr })
  } catch (err) {
    console.error('[create reminder] failed', err)
    res.status(500).json({ error: '数据库错误', details: err.message })
  }
})

// 删除邮件提醒和生日记录
router.delete('/:id', async (req, res) => {
  const { id } = req.params
  const connection = await pool.getConnection()

  try {
    await connection.beginTransaction()

    // 删除邮件提醒
    const [emailResult] = await connection.query('DELETE FROM email_reminders WHERE id = ?', [id])
    if (!emailResult.affectedRows) throw new Error('没有找到要删除的邮件提醒')

    // ⚠️ 注意：只有当 birthdays.id == email_reminders.id 才会成功
    // 现实中更常见是 email_reminders.birthday_id -> birthdays.id
    // 如果你的表结构是这样，请把这里改成按 birthday_id 删除或仅删除提醒：
    const [birthdayResult] = await connection.query('DELETE FROM birthdays WHERE id = ?', [id])
    if (!birthdayResult.affectedRows) {
      console.warn('没有找到要删除的生日记录（可能不是同一个ID，检查表结构与外键关系）')
      // 不抛错也可，根据你的业务需要决定
    }

    await connection.commit()
    res.json({ success: true, message: '删除成功' })
  } catch (err) {
    await connection.rollback()
    console.error('删除操作失败:', err)
    res.status(500).json({ error: '删除失败', details: err.message })
  } finally {
    connection.release()
  }
})

// 每分钟轮询未发送且到期的提醒（用 MySQL NOW() 避免时区/格式问题）
schedule.scheduleJob('*/1 * * * *', async () => {
  try {
    const reminders = await query('SELECT * FROM email_reminders WHERE status = 0 AND remind_time <= NOW()')

    if (!reminders.length) return

    for (const r of reminders) {
      await sendReminderEmail(r)
    }
  } catch (err) {
    console.error('[cron] batch send failed:', err)
  }
})

// 服务启动时把将来的未发送提醒重新挂到调度器
async function reschedulePendingReminders() {
  try {
    const nowStr = formatDate(new Date())
    const reminders = await query('SELECT * FROM email_reminders WHERE status = 0 AND remind_time > ?', [nowStr])

    for (const r of reminders) {
      const runAt = new Date(r.remind_time) // 确保是 JS Date
      if (Number.isNaN(runAt.getTime())) {
        console.warn('[reschedule] invalid remind_time, skip:', r.id, r.remind_time)
        continue
      }
      schedule.scheduleJob(runAt, async () => {
        // 再查一遍，避免重复
        const [row] = await query('SELECT * FROM email_reminders WHERE id = ?', [r.id])
        if (!row || row.status === 1) return
        await sendReminderEmail(row)
      })
      console.log('[reschedule] job restored for', r.id, runAt.toISOString())
    }
  } catch (err) {
    console.error('[reschedule] failed:', err)
  }
}
reschedulePendingReminders()

module.exports = router
