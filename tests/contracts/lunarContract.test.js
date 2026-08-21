const test = require('node:test')
const assert = require('node:assert/strict')
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
