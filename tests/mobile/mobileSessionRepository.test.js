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
      if (/SELECT device_id/i.test(sql)) {
        const suppliedRefreshHash = params[0]
        const currentTime = params[1]
        const tokenMatches = suppliedRefreshHash === session.refreshTokenHash
        const isUnrevoked = session.revokedAt === null
        const isUnexpired = session.refreshExpiresAt > currentTime
        return [[tokenMatches && isUnrevoked && isUnexpired
          ? { device_id: session.deviceId }
          : null].filter(Boolean)]
      }
      const suppliedRefreshHash = params[5]
      const suppliedDeviceId = params[6]
      const currentTime = params[7]
      const checksRevocation = /revoked_at\s+IS\s+NULL/i.test(sql)
      const checksStrictExpiry = /refresh_expires_at\s*>\s*\?/i.test(sql)
      const tokenMatches = suppliedRefreshHash === session.refreshTokenHash
      const deviceMatches = suppliedDeviceId === session.deviceId
      const isUnrevoked = !checksRevocation || session.revokedAt === null
      const isUnexpired = !checksStrictExpiry || session.refreshExpiresAt > currentTime
      return [{ affectedRows: tokenMatches && deviceMatches && isUnrevoked && isUnexpired ? 1 : 0 }]
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

test('bindSession atomically rebinds the same username and device while rejecting unique-hash cross-device collisions', async () => {
  const pool = createPool([{ affectedRows: 2 }])
  const sessions = createMobileSessionRepository({ pool })

  await sessions.bindSession({
    deviceId: 'device-1',
    username: 'admin',
    deviceName: 'Renamed iPhone',
    pair: originalPair,
  })

  const [{ sql, params }] = pool.calls
  assert.match(sql, /INSERT INTO mobile_device_sessions/i)
  assert.match(sql, /ON DUPLICATE KEY UPDATE/i)
  assert.match(sql, /device_id\s*=\s*IF\(\s*device_id\s*=\s*VALUES\(device_id\)\s+AND\s+username\s*=\s*VALUES\(username\),\s*device_id,\s*NULL\s*\)/i)
  assert.match(sql, /device_name\s*=\s*VALUES\(device_name\)/i)
  assert.match(sql, /access_token_hash\s*=\s*VALUES\(access_token_hash\)/i)
  assert.match(sql, /refresh_token_hash\s*=\s*VALUES\(refresh_token_hash\)/i)
  assert.match(sql, /access_expires_at\s*=\s*VALUES\(access_expires_at\)/i)
  assert.match(sql, /refresh_expires_at\s*=\s*VALUES\(refresh_expires_at\)/i)
  assert.match(sql, /revoked_at\s*=\s*NULL/i)
  assert.match(sql, /last_used_at\s*=\s*NULL/i)
  assert.deepEqual(params, [
    'device-1',
    'admin',
    'Renamed iPhone',
    digest(originalPair.accessToken),
    digest(originalPair.refreshToken),
    originalPair.accessExpiresAt,
    originalPair.refreshExpiresAt,
  ])
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

test('rotateByRefreshToken atomically replaces both hashes and both expiry timestamps and returns the device ID', async () => {
  const now = new Date('2026-08-21T00:10:00Z')
  const nextPair = {
    accessToken: 'replacement-access-token',
    refreshToken: 'replacement-refresh-token',
    accessExpiresAt: new Date('2026-08-21T00:25:00Z'),
    refreshExpiresAt: new Date('2027-02-17T00:10:00Z'),
  }
  const pool = createPool([[{ device_id: 'device-1' }], { affectedRows: 1 }])
  const sessions = createMobileSessionRepository({ pool })

  const result = await sessions.rotateByRefreshToken(originalPair.refreshToken, nextPair, now)

  const [{ sql: selectSQL, params: selectParams }, { sql, params }] = pool.calls
  assert.deepEqual(result, { rotated: true, deviceId: 'device-1' })
  assert.match(selectSQL, /SELECT device_id/i)
  assert.match(selectSQL, /WHERE refresh_token_hash\s*=\s*\?/i)
  assert.deepEqual(selectParams, [digest(originalPair.refreshToken), now])
  assert.match(sql, /UPDATE mobile_device_sessions/i)
  assert.match(sql, /access_token_hash\s*=\s*\?/i)
  assert.match(sql, /refresh_token_hash\s*=\s*\?/i)
  assert.match(sql, /access_expires_at\s*=\s*\?/i)
  assert.match(sql, /refresh_expires_at\s*=\s*\?/i)
  assert.match(sql, /WHERE refresh_token_hash\s*=\s*\?/i)
  assert.match(sql, /device_id\s*=\s*\?/i)
  assert.match(sql, /revoked_at\s+IS\s+NULL/i)
  assert.match(sql, /refresh_expires_at\s*>\s*\?/i)
  assert.deepEqual(params, [
    digest(nextPair.accessToken),
    digest(nextPair.refreshToken),
    nextPair.accessExpiresAt,
    nextPair.refreshExpiresAt,
    now,
    digest(originalPair.refreshToken),
    'device-1',
    now,
  ])
  assert.ok(params.every(value => value !== originalPair.refreshToken && value !== nextPair.accessToken && value !== nextPair.refreshToken))
})

const refreshNow = new Date('2026-08-21T00:10:00Z')
const validRefreshSession = {
  deviceId: 'device-1',
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
