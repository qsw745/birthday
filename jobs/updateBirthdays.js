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
// 注意：timezone 必须作为 spec 对象的 tz 字段传入。
// 写成 scheduleJob('0 0 * * *', { timezone: TZ }, fn) 会被 node-schedule 解析成
// (name='0 0 * * *', spec={timezone}, method=fn)，退化为「每分钟第 0 秒」执行。
schedule.scheduleJob({ rule: '0 0 * * *', tz: TZ }, async () => {
  console.log('更新过期生日提醒')
  let conn
  try {
    conn = await pool.getConnection()
    await conn.beginTransaction()

    // 自愈：remind_time 还没到、却已被标记为已发(status=1) 是一种异常状态。
    // 正常流程里发送完成后 remind_time 仍指向刚过去的那次，要等本任务推进日期时才连带重置为 0；
    // 若发送与推进撞在同一分钟，就会留下「已发 + 未来时间」的记录——它既不会被轮询选中
    // （轮询要求 status=0），启动时也不会注册定点任务（同样要求 status=0），
    // 于是那一次提醒被静默跳过。这里把它重新置为待发。
    const [healed] = await conn.query(
      'UPDATE email_reminders SET status = 0 WHERE status = 1 AND remind_time > NOW()'
    )
    if (healed.affectedRows) {
      console.log(`[heal] 重新置为待发的提醒条数: ${healed.affectedRows}`)
    }

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

        // 若本次提醒还没发出去（status=0 且已到期），说明这封邮件仍然「欠着」，
        // 此时不能推进日期并重置状态，否则会把待发记录改成明年、或把已占位的发送重新放开导致重复发送。
        // 留给每分钟轮询发完（status=1）后，下一次每日任务再推进。
        const [pending] = await conn.query(
          'SELECT id FROM email_reminders WHERE birthday_id = ? AND status = 0 AND remind_time <= NOW()',
          [item.id]
        )
        if (pending.length) {
          console.log(`birthday ${item.id} 有待发提醒，本次跳过推进`)
          continue
        }

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
