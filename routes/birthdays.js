// routes/birthdays.js
const express = require('express')
const router = express.Router()
const { query, pool } = require('../utils/db')
const {
  formatDateForStorage,
  generateUUID,
  calculateNextSolarDate,
  toMoment,
  STORAGE_FMT,
  TZ,
} = require('../utils/helpers')

// 获取所有生日记录
router.get('/list', async (req, res) => {
  try {
    const rows = await query(
      `SELECT 
         b.*,
         r.email AS userEmail,
         r.message AS message
       FROM birthdays b
       LEFT JOIN email_reminders r ON r.birthday_id = b.id`,
      []
    )
    // 统一把 nextSolarDate 规范化为 'YYYY-MM-DD HH:mm:ss'
    const formatted = rows.map(item => {
      const out = { ...item }
      if (item.nextSolarDate) {
        try {
          out.nextSolarDate = formatDateForStorage(item.nextSolarDate)
        } catch {
          out.nextSolarDate = null
        }
      } else {
        out.nextSolarDate = null
      }
      return out
    })
    res.json(formatted)
  } catch (err) {
    return res.status(500).json({ error: err.message })
  }
})

// 新增生日 + 邮件提醒
router.post('/', async (req, res) => {
  const {
    name,
    lunarMonth,
    lunarDay,
    isLeapMonth,
    userEmail, // 收件人
    remindTime, // 'HH:mm' 或 'HH:mm:ss'
    message, // 邮件内容（不含名字）
  } = req.body

  if (!name || !userEmail || !lunarMonth || !lunarDay) {
    return res.status(400).json({ error: '必填字段缺失（name/userEmail/lunarMonth/lunarDay）' })
  }

  // 邮件文本：前缀名字
  const finalMessage = `${name}${message ?? ''}`

  const birthdayId = generateUUID()
  const emailReminderId = generateUUID()

  // 计算下一次阳历提醒时间
  let nextSolarDate
  try {
    nextSolarDate = calculateNextSolarDate({
      lunarMonth,
      lunarDay,
      isLeapMonth,
      remindTime,
    }) // 'YYYY-MM-DD HH:mm:ss'
  } catch (e) {
    return res.status(400).json({ error: '无法计算下一次提醒日期', details: e.message })
  }

  const connection = await pool.getConnection()
  try {
    await connection.beginTransaction()

    // 插入 birthdays（可选择把 remindTime 一并存下，方便后续重算）
    await connection.query(
      `INSERT INTO birthdays (id, name, lunarMonth, lunarDay, isLeapMonth, remindTime, nextSolarDate)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [birthdayId, name, lunarMonth, lunarDay, isLeapMonth ? 1 : 0, remindTime || null, nextSolarDate]
    )

    // 插入 email_reminders（status=0 待发）
    await connection.query(
      `INSERT INTO email_reminders (id, name, email, remind_time, message, status, birthday_id)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [emailReminderId, name, userEmail, nextSolarDate, finalMessage, 0, birthdayId]
    )

    await connection.commit()

    res.json({
      success: true,
      birthday: {
        id: birthdayId,
        name,
        lunarMonth,
        lunarDay,
        isLeapMonth: !!isLeapMonth,
        remindTime: remindTime || null,
        nextSolarDate, // 已是 'YYYY-MM-DD HH:mm:ss'
      },
      emailReminder: {
        id: emailReminderId,
        email: userEmail,
        remind_time: nextSolarDate,
        status: 0,
        message: finalMessage,
      },
    })
  } catch (err) {
    await connection.rollback()
    console.error('数据库事务失败:', err)
    res.status(500).json({ error: '数据库插入失败', details: err.message })
  } finally {
    connection.release()
  }
})

// 删除生日 + 级联删除其提醒
router.delete('/:id', async (req, res) => {
  const { id } = req.params

  const connection = await pool.getConnection()
  try {
    await connection.beginTransaction()

    // 删提醒
    await connection.query('DELETE FROM email_reminders WHERE birthday_id = ?', [id])
    // 删生日
    const [ret] = await connection.query('DELETE FROM birthdays WHERE id = ?', [id])
    if (!ret.affectedRows) {
      throw new Error('没有找到要删除的生日记录')
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

// 更新生日 + 同步其提醒
router.put('/:id', async (req, res) => {
  const { id } = req.params
  const { name, lunarMonth, lunarDay, isLeapMonth, userEmail, remindTime, message } = req.body

  const finalMessage = `${name ?? ''}${message ?? ''}`

  // 重新计算下一次提醒
  let nextSolarDate
  try {
    nextSolarDate = calculateNextSolarDate({
      lunarMonth,
      lunarDay,
      isLeapMonth,
      remindTime,
    })
  } catch (e) {
    return res.status(400).json({ error: '无法计算下一次提醒日期', details: e.message })
  }

  const connection = await pool.getConnection()
  try {
    await connection.beginTransaction()

    // 更新 birthdays
    await connection.query(
      `UPDATE birthdays
         SET name = ?, lunarMonth = ?, lunarDay = ?, isLeapMonth = ?, remindTime = ?, nextSolarDate = ?
       WHERE id = ?`,
      [name, lunarMonth, lunarDay, isLeapMonth ? 1 : 0, remindTime || null, nextSolarDate, id]
    )

    // 更新/同步 email_reminders（这里假定每个生日只有一条对应提醒）
    await connection.query(
      `UPDATE email_reminders
          SET name = ?, email = ?, remind_time = ?, message = ?, status = 0
        WHERE birthday_id = ?`,
      [name, userEmail, nextSolarDate, finalMessage, id]
    )

    // 返回最新记录
    const [rows] = await connection.query('SELECT * FROM birthdays WHERE id = ?', [id])
    const b = rows && rows[0] ? rows[0] : null

    await connection.commit()

    res.json({
      success: true,
      birthday: b
        ? {
            id: b.id,
            name: b.name,
            lunarMonth: b.lunarMonth,
            lunarDay: b.lunarDay,
            isLeapMonth: !!b.isLeapMonth,
            remindTime: b.remindTime,
            nextSolarDate: b.nextSolarDate ? formatDateForStorage(b.nextSolarDate) : null,
          }
        : null,
      emailReminder: {
        email: userEmail,
        remind_time: nextSolarDate,
        status: 0,
        message: finalMessage,
      },
    })
  } catch (err) {
    await connection.rollback()
    console.error('更新生日记录失败:', err)
    res.status(500).json({ error: err.message })
  } finally {
    connection.release()
  }
})

module.exports = router
