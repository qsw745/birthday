const test = require('node:test')
const assert = require('node:assert/strict')
const request = require('supertest')
const { createTestApp } = require('../helpers/createTestApp')
const { createMobileAuthRouter } = require('../../routes/mobileAuth')

const ADMIN_ENV = { AUTH_USERNAME: 'admin', AUTH_PASSWORD_HASH: 'stored-hash' }
const DEVICE_ID = '11111111-1111-4111-8111-111111111111'
const NOW = new Date('2026-08-21T00:00:00.000Z')

function createRouter({ sessions, verifyPassword = async () => true, env = ADMIN_ENV, now = () => NOW, mobileAuth } = {}) {
  return createMobileAuthRouter({ sessions, verifyPassword, env, now, mobileAuth })
}

function createApp(router) {
  return createTestApp({ path: '/api/mobile/auth', router })
}

function createErrorApp(router) {
  const app = createApp(router)
  app.use((error, req, res, next) => {
    res.status(503).json({ error: 'server_error' })
  })
  return app
}

function authenticateAs(username) {
  return (req, res, next) => {
    req.mobileSession = { device_id: DEVICE_ID, username }
    next()
  }
}

function loginPayload(overrides = {}) {
  return {
    username: 'admin',
    password: 'secret',
    deviceId: DEVICE_ID,
    deviceName: 'iPhone',
    ...overrides,
  }
}

test('login binds the trimmed device name and returns the original opaque token pair exactly once', async () => {
  let stored
  const sessions = {
    createSession: async input => { stored = input },
  }
  const response = await request(createApp(createRouter({ sessions })))
    .post('/api/mobile/auth/login')
    .send(loginPayload({ deviceName: '  iPhone  ' }))

  assert.equal(response.status, 200)
  assert.deepEqual(Object.keys(response.body).sort(), [
    'accessExpiresAt',
    'accessToken',
    'deviceId',
    'refreshExpiresAt',
    'refreshToken',
  ])
  assert.deepEqual(stored, {
    deviceId: DEVICE_ID,
    username: 'admin',
    deviceName: 'iPhone',
    pair: {
      accessToken: response.body.accessToken,
      accessExpiresAt: new Date(response.body.accessExpiresAt),
      refreshToken: response.body.refreshToken,
      refreshExpiresAt: new Date(response.body.refreshExpiresAt),
    },
  })
  assert.equal(response.body.deviceId, DEVICE_ID)
  assert.equal(response.body.accessExpiresAt, '2026-08-21T00:15:00.000Z')
  assert.equal(response.body.refreshExpiresAt, '2027-02-17T00:00:00.000Z')
  assert.notEqual(response.body.accessToken, response.body.refreshToken)
})

test('same-device login retry uses the rebind boundary and returns a fresh usable pair both times', async () => {
  const bindings = []
  const sessions = {
    bindSession: async input => { bindings.push(input) },
    createSession: async () => assert.fail('login must prefer atomic bindSession'),
  }
  const app = createApp(createRouter({ sessions }))

  const first = await request(app)
    .post('/api/mobile/auth/login')
    .send(loginPayload({ deviceName: 'Old Name' }))
  const retry = await request(app)
    .post('/api/mobile/auth/login')
    .send(loginPayload({ deviceName: 'New Name' }))

  assert.equal(first.status, 200)
  assert.equal(retry.status, 200)
  assert.equal(first.body.deviceId, DEVICE_ID)
  assert.equal(retry.body.deviceId, DEVICE_ID)
  assert.notEqual(first.body.accessToken, retry.body.accessToken)
  assert.notEqual(first.body.refreshToken, retry.body.refreshToken)
  assert.deepEqual(bindings.map(binding => ({
    deviceId: binding.deviceId,
    username: binding.username,
    deviceName: binding.deviceName,
    accessToken: binding.pair.accessToken,
    refreshToken: binding.pair.refreshToken,
  })), [
    {
      deviceId: DEVICE_ID,
      username: 'admin',
      deviceName: 'Old Name',
      accessToken: first.body.accessToken,
      refreshToken: first.body.refreshToken,
    },
    {
      deviceId: DEVICE_ID,
      username: 'admin',
      deviceName: 'New Name',
      accessToken: retry.body.accessToken,
      refreshToken: retry.body.refreshToken,
    },
  ])
})

test('login returns one generic credential error and never creates a session for an unknown username or bad password', async () => {
  const created = []
  const checked = []
  const sessions = { createSession: async input => created.push(input) }
  const verifyPassword = async password => {
    checked.push(password)
    return password === 'secret'
  }
  const app = createApp(createRouter({ sessions, verifyPassword }))

  const unknownUser = await request(app)
    .post('/api/mobile/auth/login')
    .send(loginPayload({ username: 'nobody', password: 'secret' }))
  const badPassword = await request(app)
    .post('/api/mobile/auth/login')
    .send(loginPayload({ password: 'wrong' }))

  assert.equal(unknownUser.status, 401)
  assert.equal(badPassword.status, 401)
  assert.deepEqual(unknownUser.body, { error: 'mobile_login_invalid' })
  assert.deepEqual(badPassword.body, unknownUser.body)
  assert.deepEqual(checked, ['secret', 'wrong'])
  assert.deepEqual(created, [])
})

test('login rejects malformed credentials and device binding input without creating a session', async () => {
  const created = []
  const sessions = { createSession: async input => created.push(input) }
  const app = createApp(createRouter({ sessions }))
  const invalidPayloads = [
    loginPayload({ username: '' }),
    loginPayload({ password: '' }),
    loginPayload({ deviceId: 'not-a-uuid' }),
    loginPayload({ deviceName: '   ' }),
    loginPayload({ deviceName: 'a'.repeat(101) }),
  ]

  for (const payload of invalidPayloads) {
    const response = await request(app).post('/api/mobile/auth/login').send(payload)
    assert.equal(response.status, 400)
    assert.deepEqual(response.body, { error: 'invalid_mobile_login' })
  }

  assert.deepEqual(created, [])
})

const repositoryErrorCases = [
  {
    name: 'createSession',
    createRequest: () => {
      const sessions = { createSession: async () => { throw new Error('database unavailable') } }
      const app = createErrorApp(createRouter({ sessions }))
      return request(app).post('/api/mobile/auth/login').send(loginPayload())
    },
  },
  {
    name: 'rotateByRefreshToken',
    createRequest: () => {
      const sessions = { rotateByRefreshToken: async () => { throw new Error('database unavailable') } }
      const app = createErrorApp(createRouter({ sessions }))
      return request(app).post('/api/mobile/auth/refresh').send({ refreshToken: 'valid-refresh-token' })
    },
  },
  {
    name: 'revoke',
    createRequest: () => {
      const sessions = { revoke: async () => { throw new Error('database unavailable') } }
      const app = createErrorApp(createRouter({ sessions, mobileAuth: authenticateAs('admin') }))
      return request(app).post('/api/mobile/auth/revoke').send({ deviceId: DEVICE_ID })
    },
  },
  {
    name: 'list',
    createRequest: () => {
      const sessions = { list: async () => { throw new Error('database unavailable') } }
      const app = createErrorApp(createRouter({ sessions, mobileAuth: authenticateAs('admin') }))
      return request(app).get('/api/mobile/auth/devices')
    },
  },
  {
    name: 'default Bearer findByAccessToken',
    createRequest: () => {
      const sessions = {
        findByAccessToken: async () => { throw new Error('database unavailable') },
        list: async () => assert.fail('list must not run after bearer lookup failure'),
      }
      const app = createErrorApp(createRouter({ sessions }))
      return request(app).get('/api/mobile/auth/devices').set('Authorization', 'Bearer opaque-token')
    },
  },
]

for (const { name, createRequest } of repositoryErrorCases) {
  test(`${name} failure propagates through the Express error path without a fallback response`, async () => {
    const response = await createRequest()

    assert.equal(response.status, 503)
    assert.deepEqual(response.body, { error: 'server_error' })
  })
}

test('refresh rotates both raw tokens and never echoes the old refresh token', async () => {
  let rotated
  const sessions = {
    rotateByRefreshToken: async (...args) => {
      rotated = args
      return { rotated: true, deviceId: DEVICE_ID }
    },
  }
  const oldRefreshToken = 'old-refresh-token'
  const response = await request(createApp(createRouter({ sessions })))
    .post('/api/mobile/auth/refresh')
    .send({ refreshToken: oldRefreshToken })

  assert.equal(response.status, 200)
  assert.deepEqual(Object.keys(response.body).sort(), [
    'accessExpiresAt',
    'accessToken',
    'deviceId',
    'refreshExpiresAt',
    'refreshToken',
  ])
  assert.equal(response.body.deviceId, DEVICE_ID)
  assert.equal(rotated[0], oldRefreshToken)
  assert.equal(rotated[2], NOW)
  assert.equal(response.body.accessToken, rotated[1].accessToken)
  assert.equal(response.body.refreshToken, rotated[1].refreshToken)
  assert.equal(response.body.accessExpiresAt, '2026-08-21T00:15:00.000Z')
  assert.equal(response.body.refreshExpiresAt, '2027-02-17T00:00:00.000Z')
  assert.notEqual(response.body.refreshToken, oldRefreshToken)
})

test('refresh reports unknown, expired, and revoked refresh credentials with the same stable error', async () => {
  const sessions = { rotateByRefreshToken: async () => null }
  const app = createApp(createRouter({ sessions }))

  for (const refreshToken of ['unknown-token', 'expired-token', 'revoked-token']) {
    const response = await request(app)
      .post('/api/mobile/auth/refresh')
      .send({ refreshToken })
    assert.equal(response.status, 401)
    assert.deepEqual(response.body, { error: 'mobile_refresh_invalid' })
  }
})

test('refresh rejects missing or invalid request payload before rotating a session', async () => {
  let rotateCalls = 0
  const sessions = { rotateByRefreshToken: async () => { rotateCalls += 1; return null } }
  const app = createApp(createRouter({ sessions }))

  for (const payload of [{}, { refreshToken: '' }, { refreshToken: 123 }, { refreshToken: ' contains spaces ' }]) {
    const response = await request(app).post('/api/mobile/auth/refresh').send(payload)
    assert.equal(response.status, 400)
    assert.deepEqual(response.body, { error: 'invalid_mobile_refresh' })
  }

  assert.equal(rotateCalls, 0)
})

test('revoke passes the authenticated username to the repository so a user can revoke only their own device', async () => {
  const calls = []
  const sessions = {
    revoke: async (...args) => {
      calls.push(args)
      return args[1] === 'admin'
    },
  }
  const ownResponse = await request(createApp(createRouter({ sessions, mobileAuth: authenticateAs('admin') })))
    .post('/api/mobile/auth/revoke')
    .send({ deviceId: DEVICE_ID })
  const otherResponse = await request(createApp(createRouter({ sessions, mobileAuth: authenticateAs('other-user') })))
    .post('/api/mobile/auth/revoke')
    .send({ deviceId: DEVICE_ID })

  assert.equal(ownResponse.status, 200)
  assert.deepEqual(ownResponse.body, { success: true })
  assert.equal(otherResponse.status, 404)
  assert.deepEqual(otherResponse.body, { error: 'mobile_device_not_found' })
  assert.deepEqual(calls, [[DEVICE_ID, 'admin'], [DEVICE_ID, 'other-user']])
})

test('revoke and devices require mobile bearer authentication when no middleware is injected', async () => {
  const sessions = {
    findByAccessToken: async () => null,
    revoke: async () => assert.fail('revoke must not run'),
    list: async () => assert.fail('list must not run'),
  }
  const app = createApp(createRouter({ sessions }))

  const revoke = await request(app).post('/api/mobile/auth/revoke').send({ deviceId: DEVICE_ID })
  const devices = await request(app).get('/api/mobile/auth/devices')

  assert.equal(revoke.status, 401)
  assert.deepEqual(revoke.body, { error: 'mobile_auth_required' })
  assert.equal(devices.status, 401)
  assert.deepEqual(devices.body, { error: 'mobile_auth_required' })
})

test('devices lists only the authenticated username and strips all token material', async () => {
  let listedUsername
  const sessions = {
    list: async username => {
      listedUsername = username
      return [{
        device_id: DEVICE_ID,
        username,
        device_name: 'iPhone',
        created_at: new Date('2026-08-20T00:00:00.000Z'),
        last_used_at: null,
        access_expires_at: new Date('2026-08-21T00:15:00.000Z'),
        refresh_expires_at: new Date('2027-02-17T00:00:00.000Z'),
        revoked_at: null,
        access_token_hash: 'must-not-leak',
        refresh_token_hash: 'must-not-leak',
      }]
    },
  }
  const response = await request(createApp(createRouter({ sessions, mobileAuth: authenticateAs('admin') })))
    .get('/api/mobile/auth/devices')

  assert.equal(response.status, 200)
  assert.equal(listedUsername, 'admin')
  assert.deepEqual(response.body, {
    devices: [{
      deviceId: DEVICE_ID,
      deviceName: 'iPhone',
      createdAt: '2026-08-20T00:00:00.000Z',
      lastUsedAt: null,
      revokedAt: null,
    }],
  })
  assert.doesNotMatch(JSON.stringify(response.body), /token|hash/i)
})

test('each router has its own login rate-limit state and its short test window resets without a timeout', async () => {
  const env = { ...ADMIN_ENV, AUTH_LOGIN_LIMIT: '1', AUTH_LOGIN_WINDOW_MS: '20' }
  const makeSessions = () => ({ createSession: async () => {} })
  const firstApp = createApp(createRouter({ sessions: makeSessions(), env }))

  const first = await request(firstApp).post('/api/mobile/auth/login').send(loginPayload())
  const limited = await request(firstApp).post('/api/mobile/auth/login').send(loginPayload())
  const secondApp = createApp(createRouter({ sessions: makeSessions(), env }))
  const isolated = await request(secondApp).post('/api/mobile/auth/login').send(loginPayload())

  assert.equal(first.status, 200)
  assert.equal(limited.status, 429)
  assert.deepEqual(limited.body, { error: 'mobile_login_rate_limited' })
  assert.equal(isolated.status, 200)

  await new Promise(resolve => setTimeout(resolve, 35))
  const reset = await request(firstApp).post('/api/mobile/auth/login').send(loginPayload())
  assert.equal(reset.status, 200)
})

test('login limiter accepts only bounded safe-integer configuration and falls back to secure defaults', async () => {
  const cases = [
    {
      name: 'common safe values',
      env: { ...ADMIN_ENV, AUTH_LOGIN_LIMIT: '3', AUTH_LOGIN_WINDOW_MS: '60000' },
      expectedLimit: '3',
      expectedPolicy: '3;w=60',
    },
    {
      name: 'safe upper bounds',
      env: { ...ADMIN_ENV, AUTH_LOGIN_LIMIT: '10000', AUTH_LOGIN_WINDOW_MS: '2147483647' },
      expectedLimit: '10000',
      expectedPolicy: '10000;w=2147484',
    },
    {
      name: 'fractional limit and window',
      env: { ...ADMIN_ENV, AUTH_LOGIN_LIMIT: '0.5', AUTH_LOGIN_WINDOW_MS: '0.5' },
      expectedLimit: '10',
      expectedPolicy: '10;w=900',
    },
    {
      name: 'zero limit and window',
      env: { ...ADMIN_ENV, AUTH_LOGIN_LIMIT: '0', AUTH_LOGIN_WINDOW_MS: '0' },
      expectedLimit: '10',
      expectedPolicy: '10;w=900',
    },
    {
      name: 'negative limit and window',
      env: { ...ADMIN_ENV, AUTH_LOGIN_LIMIT: '-1', AUTH_LOGIN_WINDOW_MS: '-1' },
      expectedLimit: '10',
      expectedPolicy: '10;w=900',
    },
    {
      name: 'oversized limit and Node timer window',
      env: { ...ADMIN_ENV, AUTH_LOGIN_LIMIT: '10001', AUTH_LOGIN_WINDOW_MS: '2147483648' },
      expectedLimit: '10',
      expectedPolicy: '10;w=900',
    },
    {
      name: 'non-numeric values',
      env: { ...ADMIN_ENV, AUTH_LOGIN_LIMIT: 'NaN', AUTH_LOGIN_WINDOW_MS: 'NaN' },
      expectedLimit: '10',
      expectedPolicy: '10;w=900',
    },
    {
      name: 'non-safe integers',
      env: { ...ADMIN_ENV, AUTH_LOGIN_LIMIT: '9007199254740992', AUTH_LOGIN_WINDOW_MS: '9007199254740992' },
      expectedLimit: '10',
      expectedPolicy: '10;w=900',
    },
  ]

  for (const config of cases) {
    const sessions = { createSession: async () => {} }
    const response = await request(createApp(createRouter({ sessions, env: config.env })))
      .post('/api/mobile/auth/login')
      .send(loginPayload())

    assert.equal(response.status, 200, config.name)
    assert.equal(response.headers['ratelimit-limit'], config.expectedLimit, config.name)
    assert.equal(response.headers['ratelimit-policy'], config.expectedPolicy, config.name)
  }
})
