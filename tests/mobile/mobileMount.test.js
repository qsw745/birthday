const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const express = require('express')
const request = require('supertest')
const { createTestApp } = require('../helpers/createTestApp')
const {
  MOBILE_API_CONTRACT,
  createMobileRouter,
  createProductionMobileRouter,
} = require('../../routes/mobile')
const { createApiRouter } = require('../../routes')

const DEVICE_ID = '11111111-1111-4111-8111-111111111111'
const NOW = new Date('2026-08-22T00:00:00.000Z')
const digest = token => crypto.createHash('sha256').update(token).digest('hex')

function emptyRouter() {
  return express.Router()
}

function apiAssemblyOptions(overrides = {}) {
  return {
    authRouter: emptyRouter(),
    birthdaysRouter: emptyRouter(),
    versionRouter: emptyRouter(),
    scheduleEmailRouter: emptyRouter(),
    createEmailRemindersRouterFn: emptyRouter,
    registerEmailReminderSchedulersFn: () => ({ ready: Promise.resolve() }),
    ...overrides,
  }
}

class ProductionPoolFake {
  constructor() {
    this.calls = []
    this.session = null
    this.getConnectionCalls = 0
  }

  async execute(sql, params) {
    this.calls.push({ sql, params })
    if (/INSERT INTO mobile_device_sessions/i.test(sql)) {
      this.session = {
        device_id: params[0],
        username: params[1],
        device_name: params[2],
        access_token_hash: params[3],
        refresh_token_hash: params[4],
        access_expires_at: params[5],
        refresh_expires_at: params[6],
        created_at: NOW,
        last_used_at: null,
      }
      return [{ affectedRows: 1 }]
    }
    if (/WHERE access_token_hash = \?/i.test(sql)) {
      const active = this.session && this.session.access_token_hash === params[0]
      return [[active ? this.session : null].filter(Boolean)]
    }
    throw new Error(`unexpected pool SQL: ${sql}`)
  }

  async getConnection() {
    this.getConnectionCalls += 1
    return {
      async query(sql) {
        if (/SET TRANSACTION ISOLATION LEVEL/i.test(sql)) return [[]]
        if (/MAX\(seq\)/i.test(sql)) return [[{ max_seq: '0' }]]
        if (/FROM birthdays b/i.test(sql)) return [[]]
        throw new Error(`unexpected connection SQL: ${sql}`)
      },
      async beginTransaction() {},
      async commit() {},
      release() {},
    }
  }
}

test('mobile router exposes auth and sync surfaces at the exported paths', async () => {
  const authRouter = express.Router().get('/health', (req, res) => res.json({ auth: true }))
  const syncRouter = express.Router().get('/health', (req, res) => res.json({ sync: true }))
  const router = createMobileRouter({ authRouter, syncRouter, logger: { error() {} } })
  const app = createTestApp({ path: MOBILE_API_CONTRACT.basePath, router })

  const auth = await request(app).get(`${MOBILE_API_CONTRACT.basePath}${MOBILE_API_CONTRACT.mounts.auth}/health`)
  const sync = await request(app).get(`${MOBILE_API_CONTRACT.basePath}${MOBILE_API_CONTRACT.mounts.sync}/health`)

  assert.deepEqual(auth.body, { auth: true })
  assert.deepEqual(sync.body, { sync: true })
})

test('mobile router converts rejected child handlers to sanitized stable JSON', async () => {
  const logs = []
  const privateError = Object.assign(new Error('token=secret password=hunter2 payload=private'), {
    code: 'ER_PRIVATE',
    token: 'secret-token',
    payload: { password: 'hunter2' },
  })
  const authRouter = express.Router().get('/boom', async () => { throw privateError })
  const router = createMobileRouter({
    authRouter,
    syncRouter: emptyRouter(),
    logger: { error: (...args) => logs.push(args) },
  })
  const app = createTestApp({ path: MOBILE_API_CONTRACT.basePath, router })

  const response = await request(app).get(`${MOBILE_API_CONTRACT.basePath}${MOBILE_API_CONTRACT.mounts.auth}/boom`)

  assert.equal(response.status, 500)
  assert.deepEqual(response.body, { error: 'server_error' })
  assert.deepEqual(logs, [['mobile request failed', { name: 'Error', code: 'ER_PRIVATE' }]])
  assert.doesNotMatch(JSON.stringify(logs), /secret|hunter2|payload|password|token/i)
})

test('production mobile factory is injectable and uses one bearer session path without cookies', async () => {
  const pool = new ProductionPoolFake()
  const passwordChecks = []
  const router = createProductionMobileRouter({
    pool,
    env: { AUTH_USERNAME: 'admin', AUTH_PASSWORD_HASH: 'stored-hash' },
    now: () => NOW,
    calculateNextSolarDateFn: () => '2026-09-25 09:00:00',
    verifyPassword: async (...args) => {
      passwordChecks.push(args)
      return true
    },
    logger: { error() {} },
  })
  const app = createTestApp({ path: MOBILE_API_CONTRACT.basePath, router })

  assert.equal(pool.calls.length, 0)
  assert.equal(pool.getConnectionCalls, 0)

  const login = await request(app)
    .post(`${MOBILE_API_CONTRACT.basePath}${MOBILE_API_CONTRACT.endpoints.login}`)
    .send({ username: 'admin', password: 'secret', deviceId: DEVICE_ID, deviceName: 'iPhone' })
  const bearerSnapshot = await request(app)
    .get(`${MOBILE_API_CONTRACT.basePath}${MOBILE_API_CONTRACT.endpoints.snapshot}`)
    .set('Authorization', `Bearer ${login.body.accessToken}`)
  const cookieSnapshot = await request(app)
    .get(`${MOBILE_API_CONTRACT.basePath}${MOBILE_API_CONTRACT.endpoints.snapshot}`)
    .set('Cookie', 'birthday_session=fake-cookie')

  assert.equal(login.status, 200)
  assert.deepEqual(passwordChecks, [['secret', 'stored-hash']])
  assert.equal(bearerSnapshot.status, 200)
  assert.deepEqual(bearerSnapshot.body, { cursor: '0', birthdays: [] })
  assert.equal(cookieSnapshot.status, 401)
  assert.deepEqual(cookieSnapshot.body, { error: 'mobile_auth_required' })
  assert.equal(pool.getConnectionCalls, 1)
  assert.ok(pool.calls.some(call => /INSERT INTO mobile_device_sessions/i.test(call.sql)))
  assert.ok(pool.calls.some(call => /WHERE access_token_hash = \?/i.test(call.sql)))
  assert.equal(pool.session.access_token_hash, digest(login.body.accessToken))
})

test('API router mounts the injectable production mobile factory outside cookie auth', async () => {
  const pool = new ProductionPoolFake()
  const routes = createApiRouter(apiAssemblyOptions({
    pool,
    env: { AUTH_USERNAME: 'admin', AUTH_PASSWORD_HASH: 'stored-hash' },
    now: () => NOW,
    calculateNextSolarDateFn: () => '2026-09-25 09:00:00',
    verifyPassword: async () => true,
    mobileLogger: { error() {} },
  }))
  const app = createTestApp({ path: '/api', router: routes })

  const login = await request(app)
    .post(`${MOBILE_API_CONTRACT.basePath}${MOBILE_API_CONTRACT.endpoints.login}`)
    .send({ username: 'admin', password: 'secret', deviceId: DEVICE_ID, deviceName: 'iPhone' })

  assert.equal(login.status, 200)
  assert.equal(pool.calls.length, 1)
})

test('mobile contract documents every exported endpoint and stable public code', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const docs = fs.readFileSync(path.join(__dirname, '../../docs/mobile-sync-api.md'), 'utf8')

  for (const endpoint of Object.values(MOBILE_API_CONTRACT.endpoints)) {
    assert.match(docs, new RegExp(`${MOBILE_API_CONTRACT.basePath}${endpoint.replaceAll('/', '\\/')}`))
  }
  for (const code of MOBILE_API_CONTRACT.errorCodes) {
    assert.match(docs, new RegExp(`\\b${code}\\b`))
  }
  assert.match(docs, /conflict/)
})
