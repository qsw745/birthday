const schedule = require('node-schedule')
const { pool } = require('../utils/db')
const { calculateNextSolarDate, toMoment, TZ } = require('../utils/helpers')

function sanitizedError(error) {
  const details = { name: typeof error?.name === 'string' ? error.name : 'Error' }
  if (typeof error?.code === 'string') details.code = error.code
  return details
}

async function rollbackAndDispose(connection, primaryError, logger) {
  try {
    await connection.rollback()
    return false
  } catch (rollbackError) {
    logger.error('回滚失败:', sanitizedError(rollbackError))
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

async function runUpdateBirthdaysJob({
  poolRef = pool,
  calculateNextSolarDateFn = calculateNextSolarDate,
  toMomentFn = toMoment,
  logger = console,
} = {}) {
  logger.log('更新过期生日提醒')
  let connection
  let destroyed = false
  try {
    connection = await poolRef.getConnection()
    await connection.beginTransaction()

    const [healed] = await connection.query(
      `UPDATE email_reminders r
       JOIN birthdays b ON b.id = r.birthday_id
          SET r.status = 0
        WHERE r.status = 1
          AND r.remind_time > NOW()
          AND b.deleted_at IS NULL`,
    )
    if (healed.affectedRows) {
      logger.log(`[heal] 重新置为待发的提醒条数: ${healed.affectedRows}`)
    }

    const [birthdays] = await connection.query(
      'SELECT * FROM birthdays WHERE deleted_at IS NULL',
    )
    const currentMoment = toMomentFn(new Date())

    for (const item of birthdays) {
      try {
        let needUpdate = !item.nextSolarDate
        if (!needUpdate) {
          needUpdate = toMomentFn(item.nextSolarDate).isSameOrBefore(currentMoment)
        }
        if (!needUpdate) continue

        const [pending] = await connection.query(
          `SELECT r.id
             FROM email_reminders r
             JOIN birthdays b ON b.id = r.birthday_id
            WHERE r.birthday_id = ?
              AND r.status = 0
              AND r.remind_time <= NOW()
              AND b.deleted_at IS NULL`,
          [item.id],
        )
        if (pending.length) {
          logger.log(`birthday ${item.id} 有待发提醒，本次跳过推进`)
          continue
        }

        const newNext = calculateNextSolarDateFn({
          lunarMonth: item.lunarMonth,
          lunarDay: item.lunarDay,
          isLeapMonth: item.isLeapMonth,
          remindTime: item.remindTime,
        })

        const [birthdayUpdate] = await connection.query(
          `UPDATE birthdays
              SET nextSolarDate = ?
            WHERE id = ?
              AND version = ?
              AND lunarMonth = ?
              AND lunarDay = ?
              AND isLeapMonth = ?
              AND (remindTime <=> ?)
              AND (nextSolarDate <=> ?)
              AND deleted_at IS NULL`,
          [
            newNext,
            item.id,
            String(item.version),
            item.lunarMonth,
            item.lunarDay,
            item.isLeapMonth,
            item.remindTime,
            item.nextSolarDate,
          ],
        )
        if (!birthdayUpdate.affectedRows) {
          logger.log(`birthday ${item.id} 已并发变更，本次跳过推进`)
          continue
        }
        logger.log(`birthday ${item.id} → ${newNext}`)

        const [reminderUpdate] = await connection.query(
          `UPDATE email_reminders r
           JOIN birthdays b ON b.id = r.birthday_id
              SET r.remind_time = ?, r.status = 0
            WHERE r.birthday_id = ?
              AND (r.remind_time <=> ?)
              AND b.deleted_at IS NULL`,
          [newNext, item.id, item.nextSolarDate],
        )
        if (reminderUpdate.affectedRows) {
          logger.log(`email_reminder for birthday ${item.id} 重置提醒 → ${newNext}`)
        }
      } catch (error) {
        logger.error('计算下一次提醒日期失败:', sanitizedError(error))
      }
    }

    await connection.commit()
    logger.log('✅ 更新完成')
  } catch (error) {
    if (connection) destroyed = await rollbackAndDispose(connection, error, logger)
    logger.error('更新失败:', sanitizedError(error))
  } finally {
    if (connection && !destroyed) connection.release()
  }
}

function scheduleUpdateBirthdaysJob({
  scheduleRef = schedule,
  poolRef = pool,
  calculateNextSolarDateFn = calculateNextSolarDate,
  toMomentFn = toMoment,
  logger = console,
} = {}) {
  return scheduleRef.scheduleJob({ rule: '0 0 * * *', tz: TZ }, () => runUpdateBirthdaysJob({
    poolRef,
    calculateNextSolarDateFn,
    toMomentFn,
    logger,
  }))
}

module.exports = {
  runUpdateBirthdaysJob,
  scheduleUpdateBirthdaysJob,
}
