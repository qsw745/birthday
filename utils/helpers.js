// utils/helpers.js
const { v4: uuidv4 } = require('uuid')
const moment = require('moment-timezone')
const { Lunar } = require('lunar-javascript')

const TZ = 'Asia/Shanghai'
const STORAGE_FMT = 'YYYY-MM-DD HH:mm:ss'

/** 生成UUID */
function generateUUID() {
  return uuidv4()
}

/** 统一格式化到 'YYYY-MM-DD HH:mm:ss'（上海时区） */
function formatDateForStorage(input) {
  // input 可为 Date | 时间戳 | 字符串(ISO/常规)
  const m = moment.tz(input, TZ)
  if (!m.isValid()) {
    throw new Error('无效的日期格式')
  }
  return m.format(STORAGE_FMT)
}

/** 解析日期字符串(或Date)为 moment.tz(TZ) */
function toMoment(input) {
  const m = moment.tz(input, TZ)
  if (!m.isValid()) throw new Error('无效的日期格式')
  return m
}

/** 解析 HH:mm 或 HH:mm:ss -> {h,m,s} */
function parseTimeOfDay(tod) {
  if (!tod || typeof tod !== 'string') return { h: 9, m: 0, s: 0 } // 默认 09:00:00
  const m = tod.match(/^(\d{2}):(\d{2})(?::(\d{2}))?$/)
  if (!m) return { h: 9, m: 0, s: 0 }
  return { h: +m[1], m: +m[2], s: m[3] ? +m[3] : 0 }
}

/**
 * 计算下一次阳历提醒时间（上海时区）
 * 入参字段：
 *   - lunarMonth: 1-12
 *   - lunarDay: 1-30
 *   - isLeapMonth: 0/1/true/false
 *   - remindTime: 'HH:mm' 或 'HH:mm:ss'
 * 返回：'YYYY-MM-DD HH:mm:ss'（Asia/Shanghai）
 */
function calculateNextSolarDate(item) {
  const now = moment.tz(TZ)

  const lunarMonth = Number(item.lunarMonth)
  const lunarDay = Number(item.lunarDay)
  const isLeap = !!item.isLeapMonth
  const { h, m, s } = parseTimeOfDay(item.remindTime)

  if (!lunarMonth || !lunarDay) {
    throw new Error('缺少 lunarMonth / lunarDay')
  }

  // 以当前阳历对应的农历年为基准
  let lunarYear = Lunar.fromDate(now.toDate()).getYear()

  // 当年农历 -> 阳历
  let solar = Lunar.fromYmd(lunarYear, lunarMonth, lunarDay, isLeap).getSolar()
  let solarYmd = solar.toYmd() // 'YYYY-MM-DD'

  // 组合每日提醒时刻，按上海时区
  let candidate = moment.tz(
    `${solarYmd} ${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`,
    STORAGE_FMT,
    TZ
  )

  // 若已过，则取下一年
  if (!candidate.isValid() || candidate.isSameOrBefore(now)) {
    solar = Lunar.fromYmd(lunarYear + 1, lunarMonth, lunarDay, isLeap).getSolar()
    solarYmd = solar.toYmd()
    candidate = moment.tz(
      `${solarYmd} ${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`,
      STORAGE_FMT,
      TZ
    )
  }

  if (!candidate.isValid()) {
    throw new Error('无法计算下一次阳历提醒日期')
  }

  return candidate.format(STORAGE_FMT)
}

module.exports = {
  generateUUID,
  formatDateForStorage,
  toMoment,
  calculateNextSolarDate,
  TZ,
  STORAGE_FMT,
}
