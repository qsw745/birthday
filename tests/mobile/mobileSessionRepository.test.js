const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const { createMobileSessionRepository } = require('../../repositories/mobileSessionRepository')
const {
  StatefulMobileSessionPool,
  sessionRow,
} = require('../helpers/statefulMobileSessionPool')

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

test('createSession compatibility alias uses the transactional binding path and stores only token hashes', async () => {
  const pool = new StatefulMobileSessionPool()
  const sessions = createMobileSessionRepository({ pool })

  await sessions.createSession({
    deviceId: 'device-1',
    username: 'admin',
    deviceName: 'iPhone',
    pair: originalPair,
  })

  const [stored] = pool.snapshot()
  assert.equal(stored.device_id, 'device-1')
  assert.equal(stored.username, 'admin')
  assert.equal(stored.device_name, 'iPhone')
  assert.equal(stored.access_token_hash, digest(originalPair.accessToken))
  assert.equal(stored.refresh_token_hash, digest(originalPair.refreshToken))
  assert.deepEqual(stored.access_expires_at, originalPair.accessExpiresAt)
  assert.deepEqual(stored.refresh_expires_at, originalPair.refreshExpiresAt)
  assert.deepEqual(pool.lifecycle, [
    'getConnection',
    'begin',
    'select-owner-for-update',
    'insert-session',
    'commit',
    'release',
  ])
})

test('bindSession revives the same owner atomically and invalidates both previous credentials', async () => {
  const createdAt = new Date('2026-08-01T00:00:00.000Z')
  const oldAccess = 'old-access-token'
  const oldRefresh = 'old-refresh-token'
  const pool = new StatefulMobileSessionPool([sessionRow({
    deviceId: 'device-1',
    accessToken: oldAccess,
    refreshToken: oldRefresh,
    deviceName: 'Old iPhone',
    createdAt,
    lastUsedAt: new Date('2026-08-20T12:00:00.000Z'),
    revokedAt: new Date('2026-08-20T13:00:00.000Z'),
  })])
  const sessions = createMobileSessionRepository({ pool })

  await sessions.bindSession({
    deviceId: 'device-1',
    username: 'admin',
    deviceName: 'Renamed iPhone',
    pair: originalPair,
  })

  const lookupTime = new Date('2026-08-21T00:10:00.000Z')
  const oldAccessLookup = await sessions.findByAccessToken(oldAccess, lookupTime)
  const oldRefreshLookup = await sessions.rotateByRefreshToken(oldRefresh, originalPair, lookupTime)
  const newAccessLookup = await sessions.findByAccessToken(originalPair.accessToken, lookupTime)
  const [stored] = pool.snapshot()
  assert.equal(oldAccessLookup, null)
  assert.equal(oldRefreshLookup, null)
  assert.equal(newAccessLookup.device_id, 'device-1')
  assert.equal(stored.device_id, 'device-1')
  assert.equal(stored.username, 'admin')
  assert.equal(stored.device_name, 'Renamed iPhone')
  assert.equal(stored.access_token_hash, digest(originalPair.accessToken))
  assert.equal(stored.refresh_token_hash, digest(originalPair.refreshToken))
  assert.deepEqual(stored.access_expires_at, originalPair.accessExpiresAt)
  assert.deepEqual(stored.refresh_expires_at, originalPair.refreshExpiresAt)
  assert.deepEqual(stored.created_at, createdAt)
  assert.equal(stored.revoked_at, null)
  assert.equal(stored.last_used_at, null)
  assert.deepEqual(pool.lifecycle.slice(0, 6), [
    'getConnection',
    'begin',
    'select-owner-for-update',
    'update-session',
    'commit',
    'release',
  ])
})

test('bindSession rejects another username without changing the locked device row', async () => {
  const initial = sessionRow({
    deviceId: 'device-1',
    username: 'previous-admin',
    accessToken: 'previous-access',
    refreshToken: 'previous-refresh',
  })
  const pool = new StatefulMobileSessionPool([initial])
  const sessions = createMobileSessionRepository({ pool })

  await assert.rejects(
    sessions.bindSession({
      deviceId: 'device-1',
      username: 'admin',
      deviceName: 'Takeover Attempt',
      pair: originalPair,
    }),
    error => (
      error.code === 'mobile_device_ownership_conflict'
      && !/previous-admin|admin|token|hash/i.test(error.message)
    ),
  )

  assert.deepEqual(pool.snapshot(), [initial])
  assert.deepEqual(pool.lifecycle, [
    'getConnection',
    'begin',
    'select-owner-for-update',
    'rollback',
    'release',
  ])
})

test('bindSession lets unique token-hash collisions fail naturally and rolls back both device rows', async () => {
  const first = sessionRow({
    deviceId: 'device-1',
    accessToken: 'first-access',
    refreshToken: 'first-refresh',
  })
  const second = sessionRow({
    deviceId: 'device-2',
    accessToken: originalPair.accessToken,
    refreshToken: originalPair.refreshToken,
  })
  const pool = new StatefulMobileSessionPool([first, second])
  const before = pool.snapshot()
  const sessions = createMobileSessionRepository({ pool })

  await assert.rejects(
    sessions.bindSession({
      deviceId: 'device-1',
      username: 'admin',
      deviceName: 'Collision',
      pair: originalPair,
    }),
    error => error.code === 'ER_DUP_ENTRY',
  )

  assert.deepEqual(pool.snapshot(), before)
  assert.deepEqual(pool.lifecycle, [
    'getConnection',
    'begin',
    'select-owner-for-update',
    'update-session',
    'rollback',
    'release',
  ])
})

test('bindSession destroys a tainted connection when rollback fails and keeps the primary safe error', async () => {
  const rollbackError = Object.assign(new Error('rollback leaked private hash'), {
    code: 'ER_ROLLBACK_PRIVATE',
  })
  const pool = new StatefulMobileSessionPool([sessionRow({
    deviceId: 'device-1',
    username: 'previous-admin',
    accessToken: 'previous-access',
    refreshToken: 'previous-refresh',
  })], { rollbackError })
  const sessions = createMobileSessionRepository({ pool })

  const error = await sessions.bindSession({
    deviceId: 'device-1',
    username: 'admin',
    deviceName: 'Takeover Attempt',
    pair: originalPair,
  }).catch(caught => caught)

  assert.equal(error.code, 'mobile_device_ownership_conflict')
  assert.doesNotMatch(error.message, /previous-admin|admin|token|hash/i)
  assert.deepEqual(error.rollbackFailure, { name: 'Error', code: 'ER_ROLLBACK_PRIVATE' })
  assert.deepEqual(pool.lifecycle, [
    'getConnection',
    'begin',
    'select-owner-for-update',
    'rollback',
    'destroy',
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
