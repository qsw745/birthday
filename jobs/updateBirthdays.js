// jobs/updateBirthdays.js
console.log('✅ Loaded updateBirthdays job')

const schedule = require('node-schedule')
const { pool, query } = require('../utils/db')
const { calculateNextSolarDate, toMoment, TZ } = require('../utils/helpers')

/**
 * 每天 00:00（上海时区）执行：
 * - 查出所有 birthdays
 * - 对于 nextSolarDate <= 现在 的记录，重算下一次日期
 * - 同步 email_reminders.remind_time 并重置 status=0
 */
schedule.scheduleJob('0 0 * * *', { timezone: TZ }, async () => {
  console.log('更新过期生日提醒')
  let conn
  try {
    conn = await pool.getConnection()
    await conn.beginTransaction()

    const [birthdays] = await conn.query('SELECT * FROM birthdays')

    const now = toMoment(new Date()) // 上海时区
    for (const item of birthdays) {
      try {
        // 解析 nextSolarDate（可能为 null/空）
        const nextStr = item.nextSolarDate
        let needUpdate = false

        if (!nextStr) {
          needUpdate = true
        } else {
          const nextM = toMoment(nextStr)
          if (nextM.isSameOrBefore(now)) needUpdate = true
        }

        if (!needUpdate) continue

        // 计算下一次阳历提醒（使用表里的 remindTime，如无则默认 09:00）
        const newNext = calculateNextSolarDate({
          lunarMonth: item.lunarMonth,
          lunarDay: item.lunarDay,
          isLeapMonth: item.isLeapMonth,
          remindTime: item.remindTime, // 可能为空
        })

        // 更新 birthdays
        await conn.query('UPDATE birthdays SET nextSolarDate = ? WHERE id = ?', [newNext, item.id])
        console.log(`birthday ${item.id} → ${newNext}`)

        // 同步 email_reminders（置为待发）
        const [reminders] = await conn.query('SELECT id FROM email_reminders WHERE birthday_id = ?', [item.id])
        if (reminders.length) {
          await conn.query(
            `UPDATE email_reminders
               SET remind_time = ?, status = 0
             WHERE birthday_id = ?`,
            [newNext, item.id]
          )
          console.log(`email_reminder for birthday ${item.id} 重置提醒 → ${newNext}`)
        }
      } catch (e) {
        console.error('计算下一次提醒日期失败:', e)
        // 跳过该条，不影响其它
      }
    }

    await conn.commit()
    console.log('✅ 更新完成')
  } catch (e) {
    if (conn) {
      try {
        await conn.rollback()
      } catch (rollbackErr) {
        console.error('回滚失败:', rollbackErr)
      }
    }
    console.error('更新失败:', e)
  } finally {
    if (conn) conn.release()
  }
})
