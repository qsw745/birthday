const test = require('node:test')
const assert = require('node:assert/strict')

function loadJobWithHarmlessDefaults() {
  const schedulePath = require.resolve('node-schedule')
  const dbPath = require.resolve('../../utils/db')
  const jobPath = require.resolve('../../jobs/updateBirthdays')
  const prior = new Map([
    [schedulePath, require.cache[schedulePath]],
    [dbPath, require.cache[dbPath]],
    [jobPath, require.cache[jobPath]],
  ])
  require.cache[schedulePath] = {
    id: schedulePath,
    filename: schedulePath,
    loaded: true,
    exports: { scheduleJob() { return {} } },
  }
  require.cache[dbPath] = {
    id: dbPath,
    filename: dbPath,
    loaded: true,
    exports: { pool: {}, query: async () => [] },
  }
  delete require.cache[jobPath]
  const loaded = require('../../jobs/updateBirthdays')
  for (const [modulePath, cached] of prior) {
    if (cached) require.cache[modulePath] = cached
    else delete require.cache[modulePath]
  }
  return loaded
}

test('update job filters tombstones from birthdays, self-heal, and derived reminder writes without version changes', async () => {
  const { runUpdateBirthdaysJob } = loadJobWithHarmlessDefaults()
  const queries = []
  const connection = {
    lifecycle: [],
    async beginTransaction() { this.lifecycle.push('begin') },
    async commit() { this.lifecycle.push('commit') },
    async rollback() { this.lifecycle.push('rollback') },
    release() { this.lifecycle.push('release') },
    async query(sqlInput) {
      const sql = sqlInput.replace(/\s+/g, ' ').trim()
      queries.push(sql)
      if (/^UPDATE email_reminders r JOIN birthdays b/.test(sql) && /remind_time > NOW/.test(sql)) {
        return [{ affectedRows: 1 }]
      }
      if (/^SELECT \* FROM birthdays WHERE deleted_at IS NULL$/.test(sql)) {
        return [[{
          id: '11111111-1111-4111-8111-111111111111',
          lunarMonth: 8,
          lunarDay: 15,
          isLeapMonth: 0,
          remindTime: '09:00:00',
          nextSolarDate: null,
        }]]
      }
      if (/^SELECT r\.id FROM email_reminders r JOIN birthdays b/.test(sql)) return [[]]
      if (/^UPDATE birthdays SET nextSolarDate/.test(sql)) return [{ affectedRows: 1 }]
      if (/^UPDATE email_reminders r JOIN birthdays b/.test(sql)) return [{ affectedRows: 1 }]
      throw new Error(`unexpected SQL: ${sql}`)
    },
  }

  await runUpdateBirthdaysJob({
    poolRef: { getConnection: async () => connection },
    calculateNextSolarDateFn: () => '2027-09-15 09:00:00',
    toMomentFn: value => ({
      isSameOrBefore: () => value !== undefined,
    }),
  })

  assert.deepEqual(connection.lifecycle, ['begin', 'commit', 'release'])
  assert.equal(queries.includes('SELECT * FROM birthdays WHERE deleted_at IS NULL'), true)
  const heal = queries.find(sql => /remind_time > NOW/.test(sql))
  assert.match(heal, /JOIN birthdays b ON b\.id = r\.birthday_id/)
  assert.match(heal, /b\.deleted_at IS NULL/)
  const birthdayUpdate = queries.find(sql => /^UPDATE birthdays SET nextSolarDate/.test(sql))
  assert.match(birthdayUpdate, /deleted_at IS NULL/)
  assert.doesNotMatch(birthdayUpdate, /version|mobile_sync_changes|mobile_sync_operations/)
  const reminderQueries = queries.filter(sql => /email_reminders r JOIN birthdays b/.test(sql))
  assert.ok(reminderQueries.length >= 3)
  for (const sql of reminderQueries) assert.match(sql, /b\.deleted_at IS NULL/)
  assert.equal(queries.some(sql => /mobile_sync_changes|mobile_sync_operations/.test(sql)), false)
})
