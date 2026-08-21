const test = require('node:test')
const assert = require('node:assert/strict')
const { createMobileAuth } = require('../../middleware/mobileAuth')

function createResponse() {
  return {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this },
    json(body) { this.body = body; return this },
  }
}

for (const authorization of [undefined, '', 'Bearer', 'Bearer ', 'bearer opaque', 'BEARER opaque', 'Bearer  opaque', ' Bearer opaque', 'Bearer opaque ']) {
  test(`mobile auth rejects malformed bearer authorization ${JSON.stringify(authorization)}`, async () => {
    const middleware = createMobileAuth({ sessions: { findByAccessToken: async () => assert.fail('session lookup must not run') } })
    const req = { headers: authorization === undefined ? {} : { authorization } }
    const res = createResponse()
    let nextCalled = false

    await middleware(req, res, () => { nextCalled = true })

    assert.equal(res.statusCode, 401)
    assert.deepEqual(res.body, { error: 'mobile_auth_required' })
    assert.equal(nextCalled, false)
  })
}

test('mobile auth reports a valid-but-unmatched bearer token as expired', async () => {
  const now = new Date('2026-08-21T00:10:00Z')
  let lookup
  const middleware = createMobileAuth({
    sessions: { findByAccessToken: async (...args) => { lookup = args; return null } },
    now: () => now,
  })
  const req = { headers: { authorization: 'Bearer opaque-token' } }
  const res = createResponse()

  await middleware(req, res, () => assert.fail('next must not run'))

  assert.deepEqual(lookup, ['opaque-token', now])
  assert.equal(res.statusCode, 401)
  assert.deepEqual(res.body, { error: 'mobile_access_expired' })
})

test('mobile auth propagates repository failures without returning 401 or calling next', async () => {
  const failure = new Error('database unavailable')
  const middleware = createMobileAuth({
    sessions: { findByAccessToken: async () => { throw failure } },
  })
  const req = { headers: { authorization: 'Bearer opaque-token' } }
  const res = createResponse()
  let nextCalled = false

  await assert.rejects(
    middleware(req, res, () => { nextCalled = true }),
    error => error === failure,
  )

  assert.equal(res.statusCode, 200)
  assert.equal(res.body, null)
  assert.equal(nextCalled, false)
  assert.equal(req.mobileSession, undefined)
})

test('mobile auth attaches the resolved session and calls next for exactly formatted bearer input', async () => {
  const session = { device_id: 'device-1', username: 'admin' }
  const middleware = createMobileAuth({ sessions: { findByAccessToken: async () => session } })
  const req = { headers: { authorization: 'Bearer opaque-token' } }
  const res = createResponse()
  let nextCalled = false

  await middleware(req, res, () => { nextCalled = true })

  assert.equal(nextCalled, true)
  assert.equal(res.statusCode, 200)
  assert.equal(res.body, null)
  assert.equal(req.mobileSession, session)
})
