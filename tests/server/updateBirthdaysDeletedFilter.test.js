const test = require('node:test')
const assert = require('node:assert/strict')

function loadBirthdayJob() {
  return require('../../jobs/updateBirthdays')
}

test('update job filters tombstones from birthdays, self-heal, and derived reminder writes without version changes', async () => {
  const { runUpdateBirthdaysJob } = loadBirthdayJob()
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
          version: '4',
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
  assert.match(heal, /r\.delivered_remind_time = NULL/)
  assert.match(heal, /r\.generation = UUID\(\)/)
  assert.match(heal, /r\.claim_token = NULL/)
  assert.match(heal, /r\.claim_generation = NULL/)
  assert.match(heal, /r\.claim_remind_time = NULL/)
  assert.match(heal, /r\.claimed_at = NULL/)
  const birthdayUpdate = queries.find(sql => /^UPDATE birthdays SET nextSolarDate/.test(sql))
  assert.match(birthdayUpdate, /deleted_at IS NULL/)
  assert.match(birthdayUpdate, /version = \?/)
  assert.match(birthdayUpdate, /nextSolarDate <=> \?/)
  assert.doesNotMatch(birthdayUpdate, /SET nextSolarDate = \?, version|mobile_sync_changes|mobile_sync_operations/)
  const reminderQueries = queries.filter(sql => /email_reminders r JOIN birthdays b/.test(sql))
  assert.ok(reminderQueries.length >= 3)
  for (const sql of reminderQueries) assert.match(sql, /b\.deleted_at IS NULL/)
  const reminderUpdate = reminderQueries.find(sql => /SET r\.remind_time = \?/.test(sql))
  assert.match(reminderUpdate, /r\.schedule_mode = 'derived'/)
  assert.match(reminderUpdate, /r\.generation = UUID\(\)/)
  assert.doesNotMatch(reminderUpdate, /r\.remind_time <=>/)
  const blockingRead = queries.find(sql => /^SELECT r\.id FROM email_reminders/.test(sql))
  assert.match(blockingRead, /r\.status = 0 OR NOT \(r\.delivered_remind_time <=> r\.remind_time\)/)
  assert.match(reminderUpdate, /r\.claim_token = NULL/)
  assert.equal(queries.some(sql => /mobile_sync_changes|mobile_sync_operations/.test(sql)), false)
})

test('derived refresh advances only derived reminders and preserves future exact reminders', async () => {
  const { runUpdateBirthdaysJob } = loadBirthdayJob()
  const STANDARD_ID = '11111111-1111-4111-8111-111111111111'
  const LEGACY_ID = '22222222-2222-4222-8222-222222222222'
  const OLD_STANDARD = '2026-08-20 09:00:00'
  const OLD_LEGACY_BIRTHDAY = '2026-08-19 09:00:00'
  const LEGACY_EXACT = '2026-12-31 18:30:00'
  const NEW_NEXT = '2027-09-15 09:00:00'
  const reminders = new Map([
    [STANDARD_ID, { remind_time: OLD_STANDARD, status: 1, schedule_mode: 'derived' }],
    [LEGACY_ID, { remind_time: LEGACY_EXACT, status: 0, schedule_mode: 'exact' }],
  ])
  const birthdayRows = [
    {
      id: STANDARD_ID,
      version: '3',
      lunarMonth: 8,
      lunarDay: 15,
      isLeapMonth: 0,
      remindTime: '09:00:00',
      nextSolarDate: OLD_STANDARD,
    },
    {
      id: LEGACY_ID,
      version: '8',
      lunarMonth: 8,
      lunarDay: 15,
      isLeapMonth: 0,
      remindTime: '09:00:00',
      nextSolarDate: OLD_LEGACY_BIRTHDAY,
    },
  ]
  const connection = {
    async beginTransaction() {},
    async commit() {},
    async rollback() {},
    release() {},
    async query(sqlInput, params = []) {
      const sql = sqlInput.replace(/\s+/g, ' ').trim()
      if (/^UPDATE email_reminders r JOIN birthdays b/.test(sql) && /remind_time > NOW/.test(sql)) {
        return [{ affectedRows: 0 }]
      }
      if (/^SELECT \* FROM birthdays/.test(sql)) return [birthdayRows]
      if (/^SELECT r\.id FROM email_reminders/.test(sql)) return [[]]
      if (/^UPDATE birthdays SET nextSolarDate/.test(sql)) return [{ affectedRows: 1 }]
      if (/^UPDATE email_reminders r JOIN birthdays b/.test(sql)) {
        const [newNext, birthdayId] = params
        const reminder = reminders.get(birthdayId)
        const matched = reminder && reminder.schedule_mode === 'derived'
        if (matched) reminders.set(birthdayId, {
          remind_time: newNext,
          status: 0,
          schedule_mode: 'derived',
        })
        return [{ affectedRows: matched ? 1 : 0 }]
      }
      throw new Error(`unexpected SQL: ${sql}`)
    },
  }

  await runUpdateBirthdaysJob({
    poolRef: { getConnection: async () => connection },
    calculateNextSolarDateFn: () => NEW_NEXT,
    toMomentFn: () => ({ isSameOrBefore: () => true }),
  })

  assert.deepEqual(reminders.get(STANDARD_ID), {
    remind_time: NEW_NEXT,
    status: 0,
    schedule_mode: 'derived',
  })
  assert.deepEqual(reminders.get(LEGACY_ID), {
    remind_time: LEGACY_EXACT,
    status: 0,
    schedule_mode: 'exact',
  })
})

test('stale birthday candidates cannot overwrite a concurrent versioned web or mobile update', async () => {
  const { runUpdateBirthdaysJob } = loadBirthdayJob()
  const BIRTHDAY_ID = '11111111-1111-4111-8111-111111111111'
  let reminderWrites = 0
  let optimisticParams
  const stale = {
    id: BIRTHDAY_ID,
    version: '4',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: 0,
    remindTime: '09:00:00',
    nextSolarDate: '2026-08-20 09:00:00',
  }
  const connection = {
    async beginTransaction() {},
    async commit() {},
    async rollback() {},
    release() {},
    async query(sqlInput, params = []) {
      const sql = sqlInput.replace(/\s+/g, ' ').trim()
      if (/^UPDATE email_reminders r JOIN birthdays b/.test(sql) && /remind_time > NOW/.test(sql)) {
        return [{ affectedRows: 0 }]
      }
      if (/^SELECT \* FROM birthdays/.test(sql)) return [[stale]]
      if (/^SELECT r\.id FROM email_reminders/.test(sql)) return [[]]
      if (/^UPDATE birthdays SET nextSolarDate/.test(sql)) {
        optimisticParams = params
        return [{ affectedRows: 0 }]
      }
      if (/^UPDATE email_reminders/.test(sql)) {
        reminderWrites += 1
        return [{ affectedRows: 1 }]
      }
      throw new Error(`unexpected SQL: ${sql}`)
    },
  }

  await runUpdateBirthdaysJob({
    poolRef: { getConnection: async () => connection },
    calculateNextSolarDateFn: () => '2027-09-15 09:00:00',
    toMomentFn: () => ({ isSameOrBefore: () => true }),
  })

  assert.deepEqual(optimisticParams, [
    '2027-09-15 09:00:00',
    BIRTHDAY_ID,
    '4',
    8,
    15,
    0,
    '09:00:00',
    '2026-08-20 09:00:00',
  ])
  assert.equal(reminderWrites, 0)
})

test('job blocks claimed and failed occurrences, then advances only an explicitly delivered occurrence', async () => {
  const BIRTHDAY_ID = '11111111-1111-4111-8111-111111111111'
  const OLD_NEXT = '2026-08-20 09:00:00'
  const NEW_NEXT = '2027-09-15 09:00:00'
  for (const scenario of [
    {
      name: 'claimed',
      reminder: {
        status: 0,
        delivered_remind_time: null,
        claim_token: 'claim-a',
      },
      expectedBirthdayWrites: 0,
    },
    {
      name: 'failed',
      reminder: {
        status: 0,
        delivered_remind_time: null,
        claim_token: null,
      },
      expectedBirthdayWrites: 0,
    },
    {
      name: 'delivered',
      reminder: {
        status: 1,
        delivered_remind_time: OLD_NEXT,
        claim_token: null,
      },
      expectedBirthdayWrites: 1,
    },
  ]) {
    const birthday = {
      id: BIRTHDAY_ID,
      version: '4',
      lunarMonth: 8,
      lunarDay: 15,
      isLeapMonth: 0,
      remindTime: '09:00:00',
      nextSolarDate: OLD_NEXT,
    }
    const reminder = {
      remind_time: OLD_NEXT,
      schedule_mode: 'derived',
      generation: 'generation-a',
      claim_generation: scenario.reminder.claim_token ? 'generation-a' : null,
      claim_remind_time: scenario.reminder.claim_token ? OLD_NEXT : null,
      claimed_at: scenario.reminder.claim_token ? '2026-08-20 09:00:00' : null,
      ...scenario.reminder,
    }
    let birthdayWrites = 0
    let reminderWrites = 0
    const connection = {
      async beginTransaction() {},
      async commit() {},
      async rollback() {},
      release() {},
      async query(sqlInput) {
        const sql = sqlInput.replace(/\s+/g, ' ').trim()
        if (/^UPDATE email_reminders r JOIN birthdays b/.test(sql) && /remind_time > NOW/.test(sql)) {
          return [{ affectedRows: 0 }]
        }
        if (/^SELECT \* FROM birthdays/.test(sql)) return [[birthday]]
        if (/^SELECT r\.id FROM email_reminders/.test(sql)) {
          const blocks = reminder.status === 0
            || reminder.delivered_remind_time !== reminder.remind_time
          return [blocks ? [{ id: 'reminder-1' }] : []]
        }
        if (/^UPDATE birthdays SET nextSolarDate/.test(sql)) {
          birthdayWrites += 1
          return [{ affectedRows: 1 }]
        }
        if (/^UPDATE email_reminders r JOIN birthdays b/.test(sql)) {
          reminderWrites += 1
          reminder.remind_time = NEW_NEXT
          reminder.status = 0
          reminder.generation = 'generation-job-new'
          reminder.claim_token = null
          return [{ affectedRows: 1 }]
        }
        throw new Error(`unexpected SQL for ${scenario.name}: ${sql}`)
      },
    }

    await loadBirthdayJob().runUpdateBirthdaysJob({
      poolRef: { getConnection: async () => connection },
      calculateNextSolarDateFn: () => NEW_NEXT,
      toMomentFn: () => ({ isSameOrBefore: () => true }),
      logger: { log() {}, warn() {}, error() {} },
    })

    assert.equal(birthdayWrites, scenario.expectedBirthdayWrites, scenario.name)
    assert.equal(reminderWrites, scenario.expectedBirthdayWrites, scenario.name)
    if (scenario.name === 'delivered') {
      assert.equal(reminder.status, 0)
      assert.equal(reminder.remind_time, NEW_NEXT)
      assert.equal(reminder.claim_token, null)
    }
  }
})

test('update job destroys on rollback failure and logs only safe error metadata', async () => {
  const { runUpdateBirthdaysJob } = loadBirthdayJob()
  const lifecycle = []
  const entries = []
  const primary = new Error('primary raw payload user@example.com token')
  primary.code = 'ER_PRIMARY_SECRET'
  const connection = {
    async beginTransaction() { lifecycle.push('begin') },
    async query() { throw primary },
    async rollback() {
      lifecycle.push('rollback')
      const error = new Error('rollback raw payload user@example.com token')
      error.code = 'ER_ROLLBACK_SECRET'
      throw error
    },
    destroy() { lifecycle.push('destroy') },
    release() { lifecycle.push('release') },
  }
  const logger = {
    log(...args) { entries.push(['log', ...args]) },
    warn(...args) { entries.push(['warn', ...args]) },
    error(...args) {
      entries.push(['error', ...args])
      throw new Error('logger unavailable')
    },
  }

  await runUpdateBirthdaysJob({
    poolRef: { getConnection: async () => connection },
    logger,
  })

  assert.deepEqual(lifecycle, ['begin', 'rollback', 'destroy'])
  const logged = JSON.stringify(entries)
  assert.match(logged, /"name":"Error"/)
  assert.match(logged, /"code":"ER_PRIMARY_SECRET"/)
  assert.match(logged, /"code":"ER_ROLLBACK_SECRET"/)
  assert.doesNotMatch(logged, /raw payload|user@example|message|email|token/)
})
