const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const fixtures = require('./lunar-contract.json')
const { calculateNextSolarDate } = require('../../utils/helpers')

for (const item of fixtures) {
  test(`lunar contract: ${item.name}`, () => {
    const actual = calculateNextSolarDate(
      {
        lunarMonth: item.month,
        lunarDay: item.day,
        isLeapMonth: item.leap,
        remindTime: '09:00',
      },
      item.after
    )
    assert.equal(actual.slice(0, 10), item.expectedDate)
  })
}

test('keeps the candidate on the same day when the reminder time is still ahead', () => {
  const actual = calculateNextSolarDate(
    { lunarMonth: 8, lunarDay: 15, isLeapMonth: false, remindTime: '09:00' },
    '2026-09-25T08:00:00+08:00'
  )
  assert.equal(actual, '2026-09-25 09:00:00')
})

test('rolls to the next lunar year after the same-day reminder time', () => {
  const actual = calculateNextSolarDate(
    { lunarMonth: 8, lunarDay: 15, isLeapMonth: false, remindTime: '09:00' },
    '2026-09-25T09:00:00+08:00'
  )
  assert.equal(actual, '2027-09-15 09:00:00')
})

test('keeps Shanghai lunar-year selection stable across host time zones', () => {
  const helperPath = path.resolve(__dirname, '../../utils/helpers')
  const script = `
    const { calculateNextSolarDate } = require(${JSON.stringify(helperPath)})
    process.stdout.write(calculateNextSolarDate(
      { lunarMonth: 1, lunarDay: 1, isLeapMonth: false, remindTime: '09:00' },
      '2026-02-17T10:00:00+08:00'
    ))
  `
  const outputs = ['UTC', 'America/Los_Angeles'].map((hostTimeZone) => execFileSync(
    process.execPath,
    ['-e', script],
    { env: { ...process.env, TZ: hostTimeZone }, encoding: 'utf8' }
  ))
  assert.deepEqual(outputs, ['2027-02-06 09:00:00', '2027-02-06 09:00:00'])
})

test('rejects an invalid lunar day instead of falling back', () => {
  assert.throws(
    () => calculateNextSolarDate(
      { lunarMonth: 2, lunarDay: 31, isLeapMonth: false, remindTime: '09:00' },
      '2026-01-01T00:00:00+08:00'
    ),
    /only 29 days/
  )
})
