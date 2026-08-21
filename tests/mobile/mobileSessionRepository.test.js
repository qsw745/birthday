const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const { createMobileSessionRepository } = require('../../repositories/mobileSessionRepository')

const digest = token => crypto.createHash('sha256').update(token).digest('hex')

function createPool(results = []) {
  const calls = []
  return {
    calls,
    async execute(sql, params) {
      calls.push({ sql, params })
      return [results.shift() || { affectedRows: 0 }]
    },
  }
}

function createRefreshPool(session) {
  const calls = []
  return {
    calls,
    async execute(sql, params) {
      calls.push({ sql, params })
      const suppliedRefreshHash = params[5]
      const currentTime = params[6]
      const checksRevocation = /revoked_at\s+IS\s+NULL/i.test(sql)
      const checksStrictExpiry = /refresh_expires_at\s*>\s*\?/i.test(sql)
      const tokenMatches = suppliedRefreshHash === session.refreshTokenHash
      const isUnrevoked = !checksRevocation || session.revokedAt === null
      const isUnexpired = !checksStrictExpiry || session.refreshExpiresAt > currentTime
      return [{ affectedRows: tokenMatches && isUnrevoked && isUnexpired ? 1 : 0 }]
    },
  }
}

const originalPair = {
  accessToken: 'access-token-that-must-not-be-stored',
  refreshToken: 'refresh-token-that-must-not-be-stored',
  accessExpiresAt: new Date('2026-08-21T00:15:00Z'),
  refreshExpiresAt: new Date('2027-02-17T00:00:00Z'),
}

test('createSession persists hashes and expiry timestamps, never presented tokens', async () => {
  const pool = createPool([{ affectedRows: 1 }])
  const sessions = createMobileSessionRepository({ pool })

  await sessions.createSession({
    deviceId: 'device-1',
    username: 'admin',
    deviceName: 'iPhone',
    pair: originalPair,
  })

  const [{ sql, params }] = pool.calls
  assert.match(sql, /INSERT INTO mobile_device_sessions/i)
  assert.deepEqual(params, [
    'device-1',
    'admin',
    'iPhone',
    digest(originalPair.accessToken),
    digest(originalPair.refreshToken),
    originalPair.accessExpiresAt,
    originalPair.refreshExpiresAt,
  ])
  assert.ok(params.every(value => value !== originalPair.accessToken && value !== originalPair.refreshToken))
})

test('findByAccessToken hashes before querying and requires an unrevoked unexpired access session', async () => {
  const now = new Date('2026-08-21T00:10:00Z')
  const storedSession = { device_id: 'device-1', username: 'admin' }
  const pool = createPool([[storedSession]])
  const sessions = createMobileSessionRepository({ pool })

  const result = await sessions.findByAccessToken(originalPair.accessToken, now)

  const [{ sql, params }] = pool.calls
  assert.deepEqual(result, storedSession)
  assert.match(sql, /access_token_hash\s*=\s*\?/i)
  assert.match(sql, /revoked_at\s+IS\s+NULL/i)
  assert.match(sql, /access_expires_at\s*>\s*\?/i)
  assert.deepEqual(params, [digest(originalPair.accessToken), now])
  assert.notEqual(params[0], originalPair.accessToken)
})

test('rotateByRefreshToken atomically replaces both hashes and both expiry timestamps', async () => {
  const now = new Date('2026-08-21T00:10:00Z')
  const nextPair = {
    accessToken: 'replacement-access-token',
    refreshToken: 'replacement-refresh-token',
    accessExpiresAt: new Date('2026-08-21T00:25:00Z'),
    refreshExpiresAt: new Date('2027-02-17T00:10:00Z'),
  }
  const pool = createPool([{ affectedRows: 1 }])
  const sessions = createMobileSessionRepository({ pool })

  const result = await sessions.rotateByRefreshToken(originalPair.refreshToken, nextPair, now)

  const [{ sql, params }] = pool.calls
  assert.notEqual(result, null)
  assert.match(sql, /UPDATE mobile_device_sessions/i)
  assert.match(sql, /access_token_hash\s*=\s*\?/i)
  assert.match(sql, /refresh_token_hash\s*=\s*\?/i)
  assert.match(sql, /access_expires_at\s*=\s*\?/i)
  assert.match(sql, /refresh_expires_at\s*=\s*\?/i)
  assert.match(sql, /WHERE refresh_token_hash\s*=\s*\?/i)
  assert.match(sql, /revoked_at\s+IS\s+NULL/i)
  assert.match(sql, /refresh_expires_at\s*>\s*\?/i)
  assert.deepEqual(params, [
    digest(nextPair.accessToken),
    digest(nextPair.refreshToken),
    nextPair.accessExpiresAt,
    nextPair.refreshExpiresAt,
    now,
    digest(originalPair.refreshToken),
    now,
  ])
  assert.ok(params.every(value => value !== originalPair.refreshToken && value !== nextPair.accessToken && value !== nextPair.refreshToken))
})

const refreshNow = new Date('2026-08-21T00:10:00Z')
const validRefreshSession = {
  refreshTokenHash: digest(originalPair.refreshToken),
  revokedAt: null,
  refreshExpiresAt: new Date('2026-08-21T00:10:01Z'),
}

test('rotateByRefreshToken rotates a matching unrevoked unexpired refresh credential', async () => {
  const sessions = createMobileSessionRepository({ pool: createRefreshPool(validRefreshSession) })

  const result = await sessions.rotateByRefreshToken(originalPair.refreshToken, originalPair, refreshNow)

  assert.notEqual(result, null)
})

test('rotateByRefreshToken returns null for an unknown refresh credential', async () => {
  const sessions = createMobileSessionRepository({ pool: createRefreshPool(validRefreshSession) })

  const result = await sessions.rotateByRefreshToken('unknown-refresh-token', originalPair, refreshNow)

  assert.equal(result, null)
})

test('rotateByRefreshToken returns null for a revoked refresh credential', async () => {
  const sessions = createMobileSessionRepository({
    pool: createRefreshPool({ ...validRefreshSession, revokedAt: new Date('2026-08-01T00:00:00Z') }),
  })

  const result = await sessions.rotateByRefreshToken(originalPair.refreshToken, originalPair, refreshNow)

  assert.equal(result, null)
})

test('rotateByRefreshToken returns null when refresh expiry equals the current time', async () => {
  const sessions = createMobileSessionRepository({
    pool: createRefreshPool({ ...validRefreshSession, refreshExpiresAt: refreshNow }),
  })

  const result = await sessions.rotateByRefreshToken(originalPair.refreshToken, originalPair, refreshNow)

  assert.equal(result, null)
})

test('revoke scopes the device update to its owning username', async () => {
  const now = new Date('2026-08-21T00:10:00Z')
  const pool = createPool([{ affectedRows: 1 }])
  const sessions = createMobileSessionRepository({ pool, now: () => now })

  const revoked = await sessions.revoke('device-1', 'admin')

  const [{ sql, params }] = pool.calls
  assert.equal(revoked, true)
  assert.match(sql, /UPDATE mobile_device_sessions/i)
  assert.match(sql, /device_id\s*=\s*\?/i)
  assert.match(sql, /username\s*=\s*\?/i)
  assert.match(sql, /revoked_at\s+IS\s+NULL/i)
  assert.deepEqual(params, [now, 'device-1', 'admin'])
})

test('list limits device sessions to the requested username and omits token hashes', async () => {
  const device = { device_id: 'device-1', username: 'admin', device_name: 'iPhone' }
  const pool = createPool([[device]])
  const sessions = createMobileSessionRepository({ pool })

  const result = await sessions.list('admin')

  const [{ sql, params }] = pool.calls
  assert.deepEqual(result, [device])
  assert.match(sql, /WHERE username\s*=\s*\?/i)
  assert.match(sql, /revoked_at\s+IS\s+NULL/i)
  assert.doesNotMatch(sql, /token_hash/i)
  assert.deepEqual(params, ['admin'])
})
