const test = require('node:test')
const assert = require('node:assert/strict')
const express = require('express')
const request = require('supertest')

const {
  applyWebDelete,
  applyWebReminderUpsert,
  applyWebUpsert,
} = require('../../services/birthdayMutationService')
const {
  DEFAULT_BIRTHDAY_ID,
  FakeConnection,
  FakeDatabase,
  FakePool,
  birthdayRow,
  reminderRow,
  validPayload,
} = require('../helpers/fakeConnection')

const REMINDER_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const NEW_REMINDER_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const FIXED_NOW = new Date('2026-08-22T04:00:00.000Z')

function auth(req, res, next) {
  if (req.get('x-test-auth') === 'yes') return next()
  return res.status(401).json({ error: '未登录或登录已过期' })
}

function appAt(path, router) {
  const app = express()
  app.use(express.json())
  app.use(path, router)
  return app
}

function webPayload(overrides = {}) {
  return {
    name: '妈妈',
    userEmail: 'mom@example.com',
    message: '生日快乐',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    remindTime: '09:00',
    ...overrides,
  }
}

function recordingLogger() {
  const entries = []
  return {
    entries,
    log(...args) { entries.push(['log', ...args]) },
    warn(...args) { entries.push(['warn', ...args]) },
    error(...args) { entries.push(['error', ...args]) },
  }
}

function loadEmailReminderModule() {
  return require('../../routes/emailReminders')
}

function loadEmailReminderFactory() {
  return loadEmailReminderModule().createEmailRemindersRouter
}

test('applyWebUpsert updates under the caller transaction, increments version, and appends exactly one change', async () => {
  const connection = FakeConnection.withBirthday({ version: '2', deleted_at: null })
  await connection.beginTransaction()

  const record = await applyWebUpsert(connection, {
    id: DEFAULT_BIRTHDAY_ID,
    payload: validPayload({ emailEnabled: true, emailAddress: 'new@example.com' }),
    dateOptions: { nowInput: FIXED_NOW },
    generateUUIDFn: () => NEW_REMINDER_ID,
  })

  assert.equal(record.version, '3')
  assert.equal(record.userEmail, 'new@example.com')
  assert.equal(connection.countSQL(/^SELECT .* FROM birthdays b .* FOR UPDATE$/), 1)
  assert.equal(connection.countSQL(/^INSERT INTO mobile_sync_changes/), 1)
  assert.deepEqual(connection.lifecycle, ['begin'])
})

test('applyWebUpsert creates version 1 and restores a tombstone with one later version', async () => {
  const created = new FakeConnection()
  await created.beginTransaction()
  const newRecord = await applyWebUpsert(created, {
    id: DEFAULT_BIRTHDAY_ID,
    payload: validPayload(),
    dateOptions: { nowInput: FIXED_NOW },
  })
  assert.equal(newRecord.version, '1')
  assert.equal(created.countSQL(/^INSERT INTO mobile_sync_changes/), 1)

  const restored = FakeConnection.withBirthday({ version: '7', deleted_at: '2026-08-21 00:00:00' })
  await restored.beginTransaction()
  const restoredRecord = await applyWebUpsert(restored, {
    id: DEFAULT_BIRTHDAY_ID,
    payload: validPayload(),
    dateOptions: { nowInput: FIXED_NOW },
  })
  assert.equal(restoredRecord.version, '8')
  assert.equal(restoredRecord.deletedAt, null)
  assert.equal(restored.countSQL(/^INSERT INTO mobile_sync_changes/), 1)
})

test('applyWebUpsert disables email by deleting its reminder while still producing one upsert change', async () => {
  const database = new FakeDatabase({
    birthdays: [birthdayRow({ version: '4' })],
    reminders: [reminderRow()],
  })
  const connection = database.createConnection()
  await connection.beginTransaction()

  const record = await applyWebUpsert(connection, {
    id: DEFAULT_BIRTHDAY_ID,
    payload: validPayload({ emailEnabled: false, emailAddress: '', emailMessage: '' }),
    dateOptions: { nowInput: FIXED_NOW },
  })

  assert.equal(record.version, '5')
  assert.equal(record.userEmail, '')
  assert.equal(connection.countSQL(/^DELETE FROM email_reminders WHERE birthday_id = \?$/), 1)
  assert.equal(connection.countSQL(/^INSERT INTO mobile_sync_changes/), 1)
})

test('applyWebDelete writes a versioned tombstone and removes the reminder without hard-deleting birthday', async () => {
  const database = new FakeDatabase({
    birthdays: [birthdayRow({ version: '2' })],
    reminders: [reminderRow()],
  })
  const connection = database.createConnection()
  await connection.beginTransaction()

  const record = await applyWebDelete(connection, { id: DEFAULT_BIRTHDAY_ID })

  assert.equal(record.version, '3')
  assert.ok(record.deletedAt)
  assert.equal(connection.countSQL(/^DELETE FROM birthdays/), 0)
  assert.equal(connection.countSQL(/^UPDATE birthdays SET deleted_at/), 1)
  assert.equal(connection.countSQL(/^DELETE FROM email_reminders WHERE birthday_id = \?$/), 1)
  assert.equal(connection.countSQL(/^INSERT INTO mobile_sync_changes/), 1)
})

test('birthday router keeps auth, list filtering, response shape, and routes all writes through versioned transactions', async () => {
  const { createBirthdaysRouter } = require('../../routes/birthdays')
  const database = new FakeDatabase()
  const pool = new FakePool(database)
  const listQueries = []
  const ids = [DEFAULT_BIRTHDAY_ID, NEW_REMINDER_ID]
  const router = createBirthdaysRouter({
    poolRef: pool,
    queryFn: async (sql, params) => {
      listQueries.push({ sql: sql.replace(/\s+/g, ' ').trim(), params })
      return []
    },
    requireAuthMiddleware: auth,
    generateUUIDFn: () => ids.shift(),
    now: () => FIXED_NOW,
  })
  const app = appAt('/api/birthdays', router)

  assert.equal((await request(app).get('/api/birthdays/list')).status, 401)
  const list = await request(app).get('/api/birthdays/list').set('x-test-auth', 'yes')
  assert.equal(list.status, 200)
  assert.match(listQueries[0].sql, /WHERE b\.deleted_at IS NULL$/)

  const created = await request(app)
    .post('/api/birthdays')
    .set('x-test-auth', 'yes')
    .send(webPayload())
  assert.equal(created.status, 200)
  assert.deepEqual(Object.keys(created.body).sort(), ['birthday', 'emailReminder', 'success'])
  assert.deepEqual(Object.keys(created.body.birthday).sort(), [
    'id', 'isLeapMonth', 'lunarDay', 'lunarMonth', 'name', 'nextSolarDate', 'remindTime',
  ])
  assert.deepEqual(Object.keys(created.body.emailReminder).sort(), [
    'email', 'id', 'message', 'remind_time', 'status',
  ])
  assert.equal(database.birthday(DEFAULT_BIRTHDAY_ID).version, '1')
  assert.equal(database.state.changes.length, 1)

  const updated = await request(app)
    .put(`/api/birthdays/${DEFAULT_BIRTHDAY_ID}`)
    .set('x-test-auth', 'yes')
    .send(webPayload({ name: '母亲', userEmail: 'mother@example.com' }))
  assert.equal(updated.status, 200)
  assert.deepEqual(Object.keys(updated.body).sort(), ['birthday', 'emailReminder', 'success'])
  assert.equal(database.birthday(DEFAULT_BIRTHDAY_ID).version, '2')
  assert.equal(database.state.changes.length, 2)

  const deleted = await request(app)
    .delete(`/api/birthdays/${DEFAULT_BIRTHDAY_ID}`)
    .set('x-test-auth', 'yes')
  assert.equal(deleted.status, 200)
  assert.deepEqual(deleted.body, { success: true, message: '删除成功' })
  assert.equal(database.birthday(DEFAULT_BIRTHDAY_ID).version, '3')
  assert.ok(database.birthday(DEFAULT_BIRTHDAY_ID).deleted_at)
  assert.equal(database.state.changes.length, 3)
  assert.equal(pool.database.connections.every(connection => connection.lifecycle.join(',') === 'begin,commit,release'), true)
})

test('birthday route destroys a tainted connection on rollback failure and does not expose the database payload', async () => {
  const { createBirthdaysRouter } = require('../../routes/birthdays')
  const secret = 'smtp-secret raw payload'
  const database = new FakeDatabase({ birthdays: [birthdayRow()] })
  const connection = database.createConnection()
  const databaseError = new Error(secret)
  database.failNext(/^UPDATE birthdays/, databaseError)
  connection.rollback = async function rollback() {
    this.lifecycle.push('rollback')
    throw new Error(`rollback ${secret}`)
  }
  const pool = { getConnection: async () => connection }
  const logger = recordingLogger()
  const router = createBirthdaysRouter({
    poolRef: pool,
    queryFn: async () => [],
    requireAuthMiddleware: auth,
    now: () => FIXED_NOW,
    logger,
  })

  const response = await request(appAt('/api/birthdays', router))
    .put(`/api/birthdays/${DEFAULT_BIRTHDAY_ID}`)
    .set('x-test-auth', 'yes')
    .send(webPayload())

  assert.equal(response.status, 500)
  assert.deepEqual(response.body, { error: '更新生日记录失败' })
  assert.doesNotMatch(JSON.stringify(response.body), /smtp-secret|raw payload/)
  assert.deepEqual(connection.lifecycle, ['begin', 'rollback', 'destroy'])
  const logged = JSON.stringify(logger.entries)
  assert.match(logged, /"name":"Error"/)
  assert.doesNotMatch(logged, /smtp-secret|raw payload|message|email|token/)
})

test('birthday PUT keeps the web email-required contract instead of treating an empty email as disable', async () => {
  const { createBirthdaysRouter } = require('../../routes/birthdays')
  const database = new FakeDatabase({
    birthdays: [birthdayRow()],
    reminders: [reminderRow()],
  })
  const pool = new FakePool(database)
  const router = createBirthdaysRouter({
    poolRef: pool,
    queryFn: async () => [],
    requireAuthMiddleware: auth,
    now: () => FIXED_NOW,
  })

  const response = await request(appAt('/api/birthdays', router))
    .put(`/api/birthdays/${DEFAULT_BIRTHDAY_ID}`)
    .set('x-test-auth', 'yes')
    .send(webPayload({ userEmail: '' }))

  assert.equal(response.status, 400)
  assert.deepEqual(response.body, { error: '必填字段缺失（name/userEmail/lunarMonth/lunarDay）' })
  assert.equal(pool.getConnectionCalls, 0)
  assert.equal(database.reminder(DEFAULT_BIRTHDAY_ID).email, 'mom@example.com')
  assert.equal(database.state.changes.length, 0)
})

test('legacy reminder POST keeps exact schedule and response shape while versioning the birthday DTO', async () => {
  const createEmailRemindersRouter = loadEmailReminderFactory()
  const database = new FakeDatabase({ birthdays: [birthdayRow({ version: '9' })] })
  const pool = new FakePool(database)
  const scheduled = []
  const scheduleRef = { scheduleJob(spec, callback) { scheduled.push({ spec, callback }); return {} } }
  const router = createEmailRemindersRouter({
    poolRef: pool,
    queryFn: async () => [],
    scheduleRef,
    transporterRef: { sendMail: async () => assert.fail('must not send during route test') },
    requireAuthMiddleware: auth,
    generateUUIDFn: () => REMINDER_ID,
    formatDateFn: () => '2027-01-02 03:04:05',
    now: () => new Date('2026-08-22T00:00:00Z'),
    startSchedulers: false,
  })

  const response = await request(appAt('/api/email-reminders', router))
    .post('/api/email-reminders')
    .set('x-test-auth', 'yes')
    .send({
      birthdayId: DEFAULT_BIRTHDAY_ID,
      name: '妈妈',
      email: 'legacy@example.com',
      remindTime: '2027-01-02T03:04:05+08:00',
      message: '旧版精确时间提醒',
    })

  assert.equal(response.status, 200)
  assert.deepEqual(response.body, {
    success: true,
    id: REMINDER_ID,
    scheduledTime: '2027-01-02 03:04:05',
  })
  assert.equal(database.birthday(DEFAULT_BIRTHDAY_ID).version, '10')
  assert.equal(database.reminder(DEFAULT_BIRTHDAY_ID).remind_time, '2027-01-02 03:04:05')
  assert.equal(database.state.changes.length, 1)
  assert.equal(scheduled.length, 1)
  assert.deepEqual(pool.database.connections[0].lifecycle, ['begin', 'commit', 'release'])
})

test('legacy reminder POST rejects missing birthdays without creating an orphan', async () => {
  const createEmailRemindersRouter = loadEmailReminderFactory()
  const database = new FakeDatabase()
  const pool = new FakePool(database)
  const router = createEmailRemindersRouter({
    poolRef: pool,
    queryFn: async () => [],
    scheduleRef: { scheduleJob() { assert.fail('orphan must not be scheduled') } },
    transporterRef: { sendMail: async () => {} },
    requireAuthMiddleware: auth,
    generateUUIDFn: () => REMINDER_ID,
    formatDateFn: () => '2027-01-02 03:04:05',
    startSchedulers: false,
  })

  const response = await request(appAt('/api/email-reminders', router))
    .post('/api/email-reminders')
    .set('x-test-auth', 'yes')
    .send({
      birthdayId: DEFAULT_BIRTHDAY_ID,
      name: '孤儿',
      email: 'orphan@example.com',
      remindTime: '2027-01-02T03:04:05+08:00',
      message: '不得创建',
    })

  assert.equal(response.status, 500)
  assert.deepEqual(response.body, { error: '数据库错误', details: '没有找到对应的生日记录' })
  assert.equal(database.state.reminders.size, 0)
  assert.equal(database.state.changes.length, 0)
  assert.deepEqual(pool.database.connections[0].lifecycle, ['begin', 'rollback', 'release'])
})

test('legacy reminder rollback failure destroys the connection and logs only safe metadata', async () => {
  const createEmailRemindersRouter = loadEmailReminderFactory()
  const database = new FakeDatabase()
  const connection = database.createConnection()
  connection.rollback = async function rollback() {
    this.lifecycle.push('rollback')
    const error = new Error('rollback leaked@example.com token raw payload')
    error.code = 'ER_ROLLBACK_SECRET'
    throw error
  }
  const logger = recordingLogger()
  const router = createEmailRemindersRouter({
    poolRef: { getConnection: async () => connection },
    queryFn: async () => [],
    scheduleRef: { scheduleJob() { return {} } },
    transporterRef: { sendMail: async () => {} },
    requireAuthMiddleware: auth,
    generateUUIDFn: () => REMINDER_ID,
    formatDateFn: () => '2027-01-02 03:04:05',
    logger,
  })

  const response = await request(appAt('/api/email-reminders', router))
    .post('/api/email-reminders')
    .set('x-test-auth', 'yes')
    .send({
      birthdayId: DEFAULT_BIRTHDAY_ID,
      name: 'raw payload',
      email: 'leaked@example.com',
      remindTime: '2027-01-02T03:04:05+08:00',
      message: 'token',
    })

  assert.equal(response.status, 500)
  assert.deepEqual(connection.lifecycle, ['begin', 'rollback', 'destroy'])
  const logged = JSON.stringify(logger.entries)
  assert.match(logged, /"name":"Error"/)
  assert.match(logged, /"code":"ER_ROLLBACK_SECRET"/)
  assert.doesNotMatch(logged, /rollback leaked|leaked@example|raw payload|message|email|token/)
})

test('legacy reminder DELETE resolves birthday_id and uses the shared tombstone path', async () => {
  const createEmailRemindersRouter = loadEmailReminderFactory()
  const database = new FakeDatabase({
    birthdays: [birthdayRow({ version: '5' })],
    reminders: [reminderRow({ id: REMINDER_ID })],
  })
  const pool = new FakePool(database)
  const router = createEmailRemindersRouter({
    poolRef: pool,
    queryFn: async () => [],
    scheduleRef: { scheduleJob() { return {} } },
    transporterRef: { sendMail: async () => {} },
    requireAuthMiddleware: auth,
    startSchedulers: false,
  })

  const response = await request(appAt('/api/email-reminders', router))
    .delete(`/api/email-reminders/${REMINDER_ID}`)
    .set('x-test-auth', 'yes')

  assert.equal(response.status, 200)
  assert.deepEqual(response.body, { success: true, message: '删除成功' })
  assert.equal(database.birthday(DEFAULT_BIRTHDAY_ID).version, '6')
  assert.ok(database.birthday(DEFAULT_BIRTHDAY_ID).deleted_at)
  assert.equal(database.state.reminders.size, 0)
  assert.equal(database.state.changes.length, 1)
  const queries = pool.database.connections[0].queries.map(entry => entry.sql)
  assert.equal(queries.some(sql => /^SELECT birthday_id FROM email_reminders WHERE id = \?$/.test(sql)), true)
  assert.equal(queries.some(sql => /^DELETE FROM birthdays/.test(sql)), false)
})

test('legacy reminder DELETE does not silently succeed for a missing reminder', async () => {
  const createEmailRemindersRouter = loadEmailReminderFactory()
  const database = new FakeDatabase({ birthdays: [birthdayRow()] })
  const pool = new FakePool(database)
  const router = createEmailRemindersRouter({
    poolRef: pool,
    queryFn: async () => [],
    scheduleRef: { scheduleJob() { return {} } },
    transporterRef: { sendMail: async () => {} },
    requireAuthMiddleware: auth,
    startSchedulers: false,
  })

  const response = await request(appAt('/api/email-reminders', router))
    .delete(`/api/email-reminders/${REMINDER_ID}`)
    .set('x-test-auth', 'yes')

  assert.equal(response.status, 500)
  assert.deepEqual(response.body, { error: '删除失败', details: '没有找到要删除的邮件提醒' })
  assert.equal(database.birthday(DEFAULT_BIRTHDAY_ID).deleted_at, null)
  assert.equal(database.state.changes.length, 0)
})

test('all send-capable reminder reads and the atomic claim require an active birthday and select r.*', async () => {
  const { registerEmailReminderSchedulers } = loadEmailReminderModule()
  const queryLog = []
  const recurringJobs = []
  const datedJobs = []
  const dueReminder = reminderRow({ remind_time: '2026-08-22 11:00:00' })
  let claimCount = 0
  const queryFn = async (sqlInput) => {
    const sql = sqlInput.replace(/\s+/g, ' ').trim()
    queryLog.push(sql)
    if (/r\.status = 0 AND r\.remind_time <= NOW\(\)/.test(sql)) return [dueReminder]
    if (/r\.status = 0 AND r\.remind_time > \?/.test(sql)) return [dueReminder]
    if (/WHERE r\.id = \?/.test(sql) && /^SELECT r\.\*/.test(sql)) return [dueReminder]
    if (/^UPDATE email_reminders r JOIN birthdays b/.test(sql) && /SET r\.status = 1/.test(sql)) {
      claimCount += 1
      return { affectedRows: 1 }
    }
    if (/SET r\.status = 0/.test(sql)) return { affectedRows: 1 }
    return []
  }
  const scheduleRef = {
    scheduleJob(spec, callback) {
      if (typeof spec === 'string') recurringJobs.push(callback)
      else datedJobs.push(callback)
      return {}
    },
  }
  const sent = []
  const schedulers = registerEmailReminderSchedulers({
    queryFn,
    scheduleRef,
    transporterRef: { sendMail: async options => sent.push(options) },
    formatDateFn: () => '2026-08-22 12:00:00',
  })
  await schedulers.ready
  await recurringJobs[0]()
  for (const callback of datedJobs) await callback()

  const sendReads = queryLog.filter(sql => /^SELECT r\.\*/.test(sql))
  assert.ok(sendReads.length >= 3, `expected due, startup, and callback reads: ${queryLog.join('\n')}`)
  for (const sql of sendReads) {
    assert.match(sql, /JOIN birthdays b ON b\.id = r\.birthday_id/)
    assert.match(sql, /b\.deleted_at IS NULL/)
    assert.doesNotMatch(sql, /^SELECT \*/)
  }
  const claims = queryLog.filter(sql => /^UPDATE email_reminders r JOIN birthdays b/.test(sql))
  assert.ok(claims.length >= 1)
  for (const sql of claims) assert.match(sql, /b\.deleted_at IS NULL/)
  assert.equal(sent.length, claimCount)
})

test('a tombstone committed before the atomic claim makes claim=0 and sends no email', async () => {
  const { registerEmailReminderSchedulers } = loadEmailReminderModule()
  const recurringJobs = []
  const stale = reminderRow({ remind_time: '2026-08-22 11:00:00' })
  const queryLog = []
  const queryFn = async sqlInput => {
    const sql = sqlInput.replace(/\s+/g, ' ').trim()
    queryLog.push(sql)
    if (/r\.status = 0 AND r\.remind_time <= NOW\(\)/.test(sql)) return [stale]
    if (/r\.status = 0 AND r\.remind_time > \?/.test(sql)) return []
    if (/SET r\.status = 1/.test(sql)) return { affectedRows: 0 }
    return []
  }
  const sent = []
  const schedulers = registerEmailReminderSchedulers({
    queryFn,
    scheduleRef: {
      scheduleJob(spec, callback) {
        if (typeof spec === 'string') recurringJobs.push(callback)
        return {}
      },
    },
    transporterRef: { sendMail: async options => sent.push(options) },
    formatDateFn: () => '2026-08-22 12:00:00',
  })
  await schedulers.ready
  await recurringJobs[0]()

  assert.equal(queryLog.some(sql => /^UPDATE email_reminders r JOIN birthdays b/.test(sql)), true)
  assert.equal(sent.length, 0)
})

test('an old T1 callback neither reads nor claims a reminder rescheduled to T2', async () => {
  const { registerEmailReminderSchedulers } = loadEmailReminderModule()
  const T1 = '2026-08-22 11:00:00'
  const T2 = '2026-08-23 11:00:00'
  let current = reminderRow({ remind_time: T1 })
  const datedJobs = []
  const claims = []
  const queryFn = async (sqlInput, params = []) => {
    const sql = sqlInput.replace(/\s+/g, ' ').trim()
    if (/r\.status = 0 AND r\.remind_time > \?/.test(sql)) return [{ ...current }]
    if (/^SELECT r\.\*/.test(sql) && /WHERE r\.id = \?/.test(sql)) {
      if (params.length >= 2 && params[1] !== current.remind_time) return []
      return [{ ...current }]
    }
    if (/SET r\.status = 1/.test(sql)) {
      claims.push(params)
      return { affectedRows: params.length < 2 || params[1] === current.remind_time ? 1 : 0 }
    }
    return []
  }
  const sent = []
  const schedulers = registerEmailReminderSchedulers({
    queryFn,
    scheduleRef: {
      scheduleJob(spec, callback) {
        if (typeof spec !== 'string') datedJobs.push(callback)
        return {}
      },
    },
    transporterRef: { sendMail: async options => sent.push(options) },
    formatDateFn: () => '2026-08-22 10:00:00',
  })
  await schedulers.ready
  current = { ...current, remind_time: T2 }
  await datedJobs[0]()

  assert.deepEqual(claims, [])
  assert.deepEqual(sent, [])
})

test('a callback-to-claim reschedule race makes the expected-time claim fail without sending', async () => {
  const { registerEmailReminderSchedulers } = loadEmailReminderModule()
  const T1 = '2026-08-22 11:00:00'
  const T2 = '2026-08-23 11:00:00'
  let current = reminderRow({ remind_time: T1 })
  const datedJobs = []
  const claims = []
  const queryFn = async (sqlInput, params = []) => {
    const sql = sqlInput.replace(/\s+/g, ' ').trim()
    if (/r\.status = 0 AND r\.remind_time > \?/.test(sql)) return [{ ...current }]
    if (/^SELECT r\.\*/.test(sql) && /WHERE r\.id = \?/.test(sql)) {
      const selected = { ...current }
      current = { ...current, remind_time: T2 }
      return [selected]
    }
    if (/SET r\.status = 1/.test(sql)) {
      claims.push(params)
      return { affectedRows: params[1] === current.remind_time ? 1 : 0 }
    }
    return []
  }
  const sent = []
  const schedulers = registerEmailReminderSchedulers({
    queryFn,
    scheduleRef: {
      scheduleJob(spec, callback) {
        if (typeof spec !== 'string') datedJobs.push(callback)
        return {}
      },
    },
    transporterRef: { sendMail: async options => sent.push(options) },
    formatDateFn: () => '2026-08-22 10:00:00',
  })
  await schedulers.ready
  await datedJobs[0]()

  assert.deepEqual(claims, [[REMINDER_ID, T1]])
  assert.deepEqual(sent, [])
})

test('SMTP failure reset cannot reset a newly rescheduled expected time', async () => {
  const { registerEmailReminderSchedulers } = loadEmailReminderModule()
  const T1 = '2026-08-22 11:00:00'
  const T2 = '2026-08-23 11:00:00'
  let current = reminderRow({ remind_time: T1 })
  const recurringJobs = []
  const resets = []
  const queryFn = async (sqlInput, params = []) => {
    const sql = sqlInput.replace(/\s+/g, ' ').trim()
    if (/r\.status = 0 AND r\.remind_time > \?/.test(sql)) return []
    if (/r\.status = 0 AND r\.remind_time <= NOW\(\)/.test(sql)) return [{ ...current }]
    if (/SET r\.status = 1/.test(sql)) return { affectedRows: 1 }
    if (/SET r\.status = 0/.test(sql)) {
      resets.push(params)
      if (params[1] === current.remind_time) current = { ...current, status: 0 }
      return { affectedRows: params[1] === current.remind_time ? 1 : 0 }
    }
    return []
  }
  const schedulers = registerEmailReminderSchedulers({
    queryFn,
    scheduleRef: {
      scheduleJob(spec, callback) {
        if (typeof spec === 'string') recurringJobs.push(callback)
        return {}
      },
    },
    transporterRef: {
      async sendMail() {
        current = { ...current, remind_time: T2, status: 0 }
        throw new Error('smtp secret payload@example.com token')
      },
    },
    formatDateFn: () => '2026-08-22 12:00:00',
  })
  await schedulers.ready
  await recurringJobs[0]()

  assert.deepEqual(resets, [[REMINDER_ID, T1]])
  assert.equal(current.remind_time, T2)
  assert.equal(current.status, 0)
})
