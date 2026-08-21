const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const express = require('express')

test('requiring server router, repository, reminder, and birthday-job factories performs no scheduling or database work', async t => {
  const schedule = require('node-schedule')
  const database = require('../../utils/db')
  let scheduleCalls = 0
  let queryCalls = 0
  let connectionCalls = 0
  let warningCalls = 0
  t.mock.method(console, 'warn', () => {
    warningCalls += 1
  })
  t.mock.method(schedule, 'scheduleJob', () => {
    scheduleCalls += 1
    return {}
  })
  t.mock.method(database, 'query', async () => {
    queryCalls += 1
    return []
  })
  t.mock.method(database.pool, 'getConnection', async () => {
    connectionCalls += 1
    throw new Error('import must not get a connection')
  })

  const reminders = require('../../routes/emailReminders')
  const birthdayJob = require('../../jobs/updateBirthdays')
  const mobileRoutes = require('../../routes/mobile')
  const apiRoutes = require('../../routes')
  const apiSurface = require('../../middleware/apiSurface')
  await new Promise(resolve => setImmediate(resolve))

  assert.equal(typeof reminders.createEmailRemindersRouter, 'function')
  assert.equal(typeof reminders.registerEmailReminderSchedulers, 'function')
  assert.equal(typeof birthdayJob.runUpdateBirthdaysJob, 'function')
  assert.equal(typeof birthdayJob.scheduleUpdateBirthdaysJob, 'function')
  assert.equal(typeof mobileRoutes.createMobileRouter, 'function')
  assert.equal(typeof mobileRoutes.createProductionMobileRouter, 'function')
  assert.equal(typeof apiRoutes.createApiRouter, 'function')
  assert.equal(typeof apiSurface.installApiSurface, 'function')
  assert.equal(scheduleCalls, 0)
  assert.equal(queryCalls, 0)
  assert.equal(connectionCalls, 0)
  assert.equal(warningCalls, 0)
})

test('API router assembly creates and registers email reminders exactly once', () => {
  const { createApiRouter } = require('../../routes')
  let createCalls = 0
  let registerCalls = 0
  const emptyRouter = () => express.Router()

  const router = createApiRouter({
    authRouter: emptyRouter(),
    birthdaysRouter: emptyRouter(),
    versionRouter: emptyRouter(),
    scheduleEmailRouter: emptyRouter(),
    createEmailRemindersRouterFn() {
      createCalls += 1
      return emptyRouter()
    },
    registerEmailReminderSchedulersFn() {
      registerCalls += 1
      return { ready: Promise.resolve() }
    },
  })

  assert.equal(typeof router, 'function')
  assert.equal(createCalls, 1)
  assert.equal(registerCalls, 1)
})

test('production entrypoint creates API routes and installs the tested API surface once', () => {
  const source = fs.readFileSync(path.join(__dirname, '../../app.js'), 'utf8')
  assert.equal((source.match(/\bcreateApiRouter\(\)/g) || []).length, 1)
  assert.equal((source.match(/\binstallApiSurface\(/g) || []).length, 1)
  assert.equal((source.match(/\bscheduleUpdateBirthdaysJob\(\)/g) || []).length, 1)
})
