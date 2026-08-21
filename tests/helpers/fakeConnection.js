const assert = require('node:assert/strict')

const DEFAULT_BIRTHDAY_ID = '11111111-1111-4111-8111-111111111111'
const DEFAULT_DEVICE_ID = '22222222-2222-4222-8222-222222222222'
const FIXED_CREATED_AT = '2026-01-01 00:00:00'
const FIXED_UPDATED_AT = '2026-08-22 12:00:00'

function clone(value) {
  return structuredClone(value)
}

function operationEntityId(response) {
  return response && (response.record?.id || response.remote?.id || null)
}

function normalizeSQL(sql) {
  return String(sql).trim().replace(/\s+/g, ' ')
}

function birthdayRow(overrides = {}) {
  return {
    id: DEFAULT_BIRTHDAY_ID,
    name: '妈妈',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: 0,
    remindTime: '09:00:00',
    nextSolarDate: '2026-09-25 09:00:00',
    version: '1',
    deleted_at: null,
    notify_day_before: 1,
    notify_same_day: 1,
    created_at: FIXED_CREATED_AT,
    updated_at: FIXED_UPDATED_AT,
    ...overrides,
  }
}

function reminderRow(overrides = {}) {
  return {
    id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    birthday_id: DEFAULT_BIRTHDAY_ID,
    name: '妈妈',
    email: 'mom@example.com',
    remind_time: '2026-09-25 09:00:00',
    message: '妈妈生日快乐',
    status: 0,
    ...overrides,
  }
}

function validPayload(overrides = {}) {
  return {
    id: DEFAULT_BIRTHDAY_ID,
    name: '妈妈',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    reminderTimeMinutes: 540,
    notifyDayBefore: true,
    notifySameDay: true,
    emailEnabled: false,
    emailAddress: '',
    emailMessage: '生日快乐',
    ...overrides,
  }
}

class FakeDatabase {
  constructor({ birthdays = [], reminders = [], operations = [], changes = [] } = {}) {
    this.state = {
      birthdays: new Map(birthdays.map(row => [String(row.id), clone(row)])),
      reminders: new Map(reminders.map(row => [String(row.birthday_id), clone(row)])),
      operations: new Map(operations.map(row => [String(row.operation_id), clone(row)])),
      changes: clone(changes),
    }
    this.connections = []
    this.failures = []
    this.operationInsertRace = null
    this.birthdayInsertRace = null
    this.birthdayLocks = new Map()
    this.birthdayInsertReservations = new Map()
  }

  failNext(matcher, error) {
    this.failures.push({ matcher, error })
  }

  createConnection() {
    const connection = new FakeConnection({ database: this })
    this.connections.push(connection)
    return connection
  }

  async acquireBirthdayLock(id, connection) {
    const key = String(id)
    const current = this.birthdayLocks.get(key)
    if (!current) {
      this.birthdayLocks.set(key, { owner: connection, waiters: [] })
      return
    }
    if (current.owner === connection) return

    await new Promise(resolve => {
      current.waiters.push({ connection, resolve })
    })
  }

  releaseBirthdayLock(id, connection) {
    const key = String(id)
    const current = this.birthdayLocks.get(key)
    assert.equal(current?.owner, connection, `birthday lock not owned: ${key}`)
    const next = current.waiters.shift()
    if (!next) {
      this.birthdayLocks.delete(key)
      return
    }
    current.owner = next.connection
    next.resolve()
  }

  async reserveBirthdayInsert(id, connection) {
    const key = String(id)
    while (true) {
      if (this.state.birthdays.has(key)) {
        const error = new Error('duplicate birthday id')
        error.code = 'ER_DUP_ENTRY'
        throw error
      }
      const current = this.birthdayInsertReservations.get(key)
      if (!current) {
        this.birthdayInsertReservations.set(key, { owner: connection, waiters: [] })
        return
      }
      if (current.owner === connection) return
      await new Promise(resolve => current.waiters.push(resolve))
    }
  }

  releaseBirthdayInsertReservation(id, connection) {
    const key = String(id)
    const current = this.birthdayInsertReservations.get(key)
    assert.equal(current?.owner, connection, `birthday insert reservation not owned: ${key}`)
    this.birthdayInsertReservations.delete(key)
    for (const resolve of current.waiters) resolve()
  }

  birthday(id) {
    const row = this.state.birthdays.get(String(id))
    return row ? clone(row) : null
  }

  reminder(id) {
    const row = this.state.reminders.get(String(id))
    return row ? clone(row) : null
  }

  operation(id) {
    const row = this.state.operations.get(String(id))
    return row ? clone(row) : null
  }
}

class FakePool {
  constructor(database = new FakeDatabase()) {
    this.database = database
    this.getConnectionCalls = 0
  }

  async getConnection() {
    this.getConnectionCalls += 1
    return this.database.createConnection()
  }
}

class FakeConnection {
  constructor({ database = new FakeDatabase() } = {}) {
    this.database = database
    this.queries = []
    this.lifecycle = []
    this.transactionState = null
    this.released = false
    this.destroyed = false
    this.lockedBirthdayIds = new Set()
    this.insertedBirthdayIds = new Set()
  }

  static withBirthday(row) {
    const database = new FakeDatabase({ birthdays: [birthdayRow(row)] })
    return database.createConnection()
  }

  static withProcessedOperation(operationId, response, {
    deviceId = DEFAULT_DEVICE_ID,
    entityId = operationEntityId(response),
  } = {}) {
    const database = new FakeDatabase({
      operations: [{
        operation_id: operationId,
        device_id: deviceId,
        entity_id: entityId,
        response_json: clone(response),
      }],
    })
    return database.createConnection()
  }

  state() {
    return this.transactionState || this.database.state
  }

  requireTransaction(sql) {
    assert.ok(this.transactionState, `write outside transaction: ${sql}`)
  }

  countSQL(pattern) {
    return this.queries.filter(entry => {
      pattern.lastIndex = 0
      return pattern.test(entry.sql)
    }).length
  }

  async beginTransaction() {
    assert.equal(this.transactionState, null, 'transaction already active')
    this.lifecycle.push('begin')
    this.transactionState = clone(this.database.state)
  }

  async commit() {
    assert.ok(this.transactionState, 'commit without transaction')
    this.lifecycle.push('commit')
    this.database.state = this.transactionState
    this.transactionState = null
    this.releaseBirthdayLocks()
    this.releaseBirthdayInsertReservations()
  }

  async rollback() {
    this.lifecycle.push('rollback')
    this.transactionState = null
    this.releaseBirthdayLocks()
    this.releaseBirthdayInsertReservations()
  }

  release() {
    assert.equal(this.released, false, 'connection released twice')
    assert.equal(this.destroyed, false, 'destroyed connection returned to pool')
    this.lifecycle.push('release')
    this.released = true
  }

  destroy() {
    assert.equal(this.released, false, 'released connection destroyed')
    assert.equal(this.destroyed, false, 'connection destroyed twice')
    this.lifecycle.push('destroy')
    this.destroyed = true
    this.transactionState = null
    this.releaseBirthdayLocks()
    this.releaseBirthdayInsertReservations()
  }

  releaseBirthdayLocks() {
    for (const id of this.lockedBirthdayIds) {
      this.database.releaseBirthdayLock(id, this)
    }
    this.lockedBirthdayIds.clear()
  }

  releaseBirthdayInsertReservations() {
    for (const id of this.insertedBirthdayIds) {
      this.database.releaseBirthdayInsertReservation(id, this)
    }
    this.insertedBirthdayIds.clear()
  }

  async lockBirthday(id) {
    this.requireTransaction('SELECT birthday FOR UPDATE')
    const key = String(id)
    if (this.lockedBirthdayIds.has(key)) return
    this.transactionState = clone(this.database.state)
    if (!this.database.state.birthdays.has(key)) return
    await this.database.acquireBirthdayLock(key, this)
    this.lockedBirthdayIds.add(key)
    // A locking read observes the latest state after any prior owner commits.
    this.transactionState = clone(this.database.state)
  }

  joinedBirthday(id) {
    const birthday = this.state().birthdays.get(String(id))
    if (!birthday) return null
    const reminder = this.state().reminders.get(String(id))
    return {
      ...clone(birthday),
      userEmail: reminder ? reminder.email : null,
      message: reminder ? reminder.message : null,
      emailReminderId: reminder ? reminder.id : null,
      emailReminderTime: reminder ? reminder.remind_time : null,
      emailReminderStatus: reminder ? reminder.status : null,
    }
  }

  maybeFail(sql) {
    const index = this.database.failures.findIndex(item => item.matcher.test(sql))
    if (index < 0) return
    const [{ error }] = this.database.failures.splice(index, 1)
    throw error
  }

  async query(sqlInput, params = []) {
    const sql = normalizeSQL(sqlInput)
    this.queries.push({ sql, params: clone(params) })
    this.maybeFail(sql)

    if (/^SET TRANSACTION ISOLATION LEVEL READ COMMITTED$/i.test(sql)) {
      return [{ affectedRows: 0 }]
    }

    if (/^SELECT operation_id, device_id,[\s\S]+FROM mobile_sync_operations WHERE operation_id = \?$/i.test(sql)) {
      assert.equal(params.length, 1)
      const stored = this.state().operations.get(String(params[0]))
      if (!stored) return [[]]
      return [[{
        ...clone(stored),
        entity_id: stored.entity_id || operationEntityId(stored.response_json),
      }]]
    }

    if (/^SELECT [\s\S]+ FROM birthdays b LEFT JOIN email_reminders r ON r\.birthday_id = b\.id WHERE b\.id = \?(?: FOR UPDATE)?$/i.test(sql)) {
      assert.equal(params.length, 1)
      const id = String(params[0])
      if (/ FOR UPDATE$/i.test(sql)) {
        await this.lockBirthday(id)
      } else {
        assert.ok(
          this.lockedBirthdayIds.has(id) || this.insertedBirthdayIds.has(id),
          'first birthday read must use FOR UPDATE',
        )
      }
      const row = this.joinedBirthday(params[0])
      return [[row].filter(Boolean)]
    }

    if (/^SELECT birthday_id FROM email_reminders WHERE id = \?$/i.test(sql)) {
      assert.equal(params.length, 1)
      const reminder = [...this.state().reminders.values()]
        .find(row => String(row.id) === String(params[0]))
      return [[reminder ? { birthday_id: reminder.birthday_id } : null].filter(Boolean)]
    }

    if (/^INSERT INTO birthdays \(id, name, lunarMonth, lunarDay, isLeapMonth, remindTime, nextSolarDate, version, deleted_at, notify_day_before, notify_same_day\) VALUES \(\?, \?, \?, \?, \?, \?, \?, \?, NULL, \?, \?\)$/i.test(sql)) {
      this.requireTransaction(sql)
      assert.equal(params.length, 10)
      const [id, name, lunarMonth, lunarDay, isLeapMonth, remindTime, nextSolarDate, version, notifyDayBefore, notifySameDay] = params
      if (this.database.birthdayInsertRace) {
        const race = this.database.birthdayInsertRace
        this.database.birthdayInsertRace = null
        race(this.database, { id, name })
      }
      await this.database.reserveBirthdayInsert(id, this)
      this.insertedBirthdayIds.add(String(id))
      this.state().birthdays.set(String(id), birthdayRow({
        id,
        name,
        lunarMonth,
        lunarDay,
        isLeapMonth,
        remindTime,
        nextSolarDate,
        version: String(version),
        notify_day_before: notifyDayBefore,
        notify_same_day: notifySameDay,
      }))
      return [{ affectedRows: 1 }]
    }

    if (/^UPDATE birthdays SET name = \?, lunarMonth = \?, lunarDay = \?, isLeapMonth = \?, remindTime = \?, nextSolarDate = \?, version = \?, deleted_at = NULL, notify_day_before = \?, notify_same_day = \? WHERE id = \?$/i.test(sql)) {
      this.requireTransaction(sql)
      assert.equal(params.length, 10)
      const [name, lunarMonth, lunarDay, isLeapMonth, remindTime, nextSolarDate, version, notifyDayBefore, notifySameDay, id] = params
      const current = this.state().birthdays.get(String(id))
      assert.ok(current, 'birthday update target missing')
      this.state().birthdays.set(String(id), {
        ...current,
        name,
        lunarMonth,
        lunarDay,
        isLeapMonth,
        remindTime,
        nextSolarDate,
        version: String(version),
        deleted_at: null,
        notify_day_before: notifyDayBefore,
        notify_same_day: notifySameDay,
        updated_at: FIXED_UPDATED_AT,
      })
      return [{ affectedRows: 1 }]
    }

    if (/^UPDATE birthdays SET deleted_at = CURRENT_TIMESTAMP, version = \? WHERE id = \?$/i.test(sql)) {
      this.requireTransaction(sql)
      assert.equal(params.length, 2)
      const [version, id] = params
      const current = this.state().birthdays.get(String(id))
      assert.ok(current, 'birthday delete target missing')
      this.state().birthdays.set(String(id), {
        ...current,
        version: String(version),
        deleted_at: FIXED_UPDATED_AT,
        updated_at: FIXED_UPDATED_AT,
      })
      return [{ affectedRows: 1 }]
    }

    if (/^UPDATE birthdays SET version = \? WHERE id = \? AND deleted_at IS NULL$/i.test(sql)) {
      this.requireTransaction(sql)
      assert.equal(params.length, 2)
      const [version, id] = params
      const current = this.state().birthdays.get(String(id))
      assert.ok(current && !current.deleted_at, 'active birthday update target missing')
      this.state().birthdays.set(String(id), {
        ...current,
        version: String(version),
        updated_at: FIXED_UPDATED_AT,
      })
      return [{ affectedRows: 1 }]
    }

    if (/^INSERT INTO email_reminders \(id, birthday_id, name, email, remind_time, message, status\) VALUES \(\?, \?, \?, \?, \?, \?, 0\) ON DUPLICATE KEY UPDATE name = VALUES\(name\), email = VALUES\(email\), remind_time = VALUES\(remind_time\), message = VALUES\(message\), status = 0$/i.test(sql)) {
      this.requireTransaction(sql)
      assert.equal(params.length, 6)
      const [id, birthdayId, name, email, remindTime, message] = params
      const current = this.state().reminders.get(String(birthdayId))
      this.state().reminders.set(String(birthdayId), reminderRow({
        id: current ? current.id : id,
        birthday_id: birthdayId,
        name,
        email,
        remind_time: remindTime,
        message,
        status: 0,
      }))
      return [{ affectedRows: current ? 2 : 1 }]
    }

    if (/^DELETE FROM email_reminders WHERE birthday_id = \?$/i.test(sql)) {
      this.requireTransaction(sql)
      assert.equal(params.length, 1)
      const deleted = this.state().reminders.delete(String(params[0]))
      return [{ affectedRows: deleted ? 1 : 0 }]
    }

    if (/^INSERT INTO mobile_sync_changes \(entity_type, entity_id, operation, version\) VALUES \(\?, \?, \?, \?\)$/i.test(sql)) {
      this.requireTransaction(sql)
      assert.deepEqual(params.slice(0, 1), ['birthday'])
      this.state().changes.push({
        seq: String(this.state().changes.length + 1),
        entity_type: params[0],
        entity_id: params[1],
        operation: params[2],
        version: String(params[3]),
      })
      return [{ affectedRows: 1, insertId: this.state().changes.length }]
    }

    if (/^INSERT INTO mobile_sync_operations \(operation_id, device_id, response_json\) VALUES \(\?, \?, \?\)$/i.test(sql)) {
      this.requireTransaction(sql)
      assert.equal(params.length, 3)
      const [operationId, deviceId, responseJSON] = params
      if (this.database.operationInsertRace) {
        const race = this.database.operationInsertRace
        this.database.operationInsertRace = null
        race(this.database, { operationId, deviceId, responseJSON })
      }
      if (this.database.state.operations.has(String(operationId))) {
        const error = new Error('duplicate operation id')
        error.code = 'ER_DUP_ENTRY'
        throw error
      }
      const response = JSON.parse(responseJSON)
      this.state().operations.set(String(operationId), {
        operation_id: operationId,
        device_id: deviceId,
        entity_id: operationEntityId(response),
        response_json: response,
      })
      return [{ affectedRows: 1 }]
    }

    assert.fail(`unexpected SQL: ${sql}`)
  }
}

module.exports = {
  DEFAULT_BIRTHDAY_ID,
  DEFAULT_DEVICE_ID,
  FakeConnection,
  FakeDatabase,
  FakePool,
  birthdayRow,
  reminderRow,
  validPayload,
}
