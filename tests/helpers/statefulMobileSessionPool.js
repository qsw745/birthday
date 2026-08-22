const crypto = require('node:crypto')

const digest = token => crypto.createHash('sha256').update(token).digest('hex')

function cloneRow(row) {
  return Object.fromEntries(Object.entries(row).map(([key, value]) => [
    key,
    value instanceof Date ? new Date(value) : value,
  ]))
}

function cloneRows(rows) {
  return new Map([...rows].map(([deviceId, row]) => [deviceId, cloneRow(row)]))
}

function sessionRow({
  deviceId,
  username = 'admin',
  deviceName = 'iPhone',
  accessToken,
  refreshToken,
  accessExpiresAt = new Date('2026-08-21T00:15:00.000Z'),
  refreshExpiresAt = new Date('2027-02-17T00:00:00.000Z'),
  createdAt = new Date('2026-08-20T00:00:00.000Z'),
  lastUsedAt = null,
  revokedAt = null,
}) {
  return {
    device_id: deviceId,
    username,
    device_name: deviceName,
    access_token_hash: digest(accessToken),
    refresh_token_hash: digest(refreshToken),
    access_expires_at: accessExpiresAt,
    refresh_expires_at: refreshExpiresAt,
    created_at: createdAt,
    last_used_at: lastUsedAt,
    revoked_at: revokedAt,
  }
}

function duplicateTokenError(hash) {
  const error = new Error(`Duplicate token hash ${hash} owned by private-user`)
  error.code = 'ER_DUP_ENTRY'
  return error
}

function assertUniqueHashes(rows, candidate, excludedDeviceId = null) {
  for (const row of rows.values()) {
    if (row.device_id === excludedDeviceId) continue
    if (row.access_token_hash === candidate.access_token_hash) {
      throw duplicateTokenError(candidate.access_token_hash)
    }
    if (row.refresh_token_hash === candidate.refresh_token_hash) {
      throw duplicateTokenError(candidate.refresh_token_hash)
    }
  }
}

class StatefulMobileSessionPool {
  constructor(rows = [], {
    rollbackError = null,
    now = new Date('2026-08-21T00:00:00.000Z'),
  } = {}) {
    this.rows = new Map(rows.map(row => [row.device_id, cloneRow(row)]))
    this.rollbackError = rollbackError
    this.now = now
    this.lifecycle = []
    this.connections = []
  }

  snapshot() {
    return [...this.rows.values()]
      .map(cloneRow)
      .sort((left, right) => left.device_id.localeCompare(right.device_id))
  }

  async getConnection() {
    this.lifecycle.push('getConnection')
    const connection = new StatefulMobileSessionConnection(this)
    this.connections.push(connection)
    return connection
  }

  async execute(sql, params) {
    if (/^\s*SELECT[\s\S]+WHERE access_token_hash = \?/i.test(sql)) {
      this.lifecycle.push('find-access')
      const [hash, currentTime] = params
      const row = [...this.rows.values()].find(candidate => (
        candidate.access_token_hash === hash
        && candidate.revoked_at === null
        && candidate.access_expires_at > currentTime
      ))
      return [[row ? cloneRow(row) : null].filter(Boolean)]
    }

    if (/^\s*SELECT device_id[\s\S]+WHERE refresh_token_hash = \?/i.test(sql)) {
      this.lifecycle.push('find-refresh')
      const [hash, currentTime] = params
      const row = [...this.rows.values()].find(candidate => (
        candidate.refresh_token_hash === hash
        && candidate.revoked_at === null
        && candidate.refresh_expires_at > currentTime
      ))
      return [[row ? { device_id: row.device_id } : null].filter(Boolean)]
    }

    if (/^\s*UPDATE mobile_device_sessions[\s\S]+WHERE refresh_token_hash = \?/i.test(sql)) {
      this.lifecycle.push('rotate-refresh')
      const [
        accessHash,
        refreshHash,
        accessExpiresAt,
        refreshExpiresAt,
        lastUsedAt,
        oldRefreshHash,
        deviceId,
        currentTime,
      ] = params
      const current = this.rows.get(deviceId)
      if (
        !current
        || current.refresh_token_hash !== oldRefreshHash
        || current.revoked_at !== null
        || current.refresh_expires_at <= currentTime
      ) {
        return [{ affectedRows: 0 }]
      }
      const next = {
        ...current,
        access_token_hash: accessHash,
        refresh_token_hash: refreshHash,
        access_expires_at: accessExpiresAt,
        refresh_expires_at: refreshExpiresAt,
        last_used_at: lastUsedAt,
      }
      assertUniqueHashes(this.rows, next, deviceId)
      this.rows.set(deviceId, next)
      return [{ affectedRows: 1 }]
    }

    throw new Error(`unexpected pool SQL: ${sql.replace(/\s+/g, ' ').trim()}`)
  }
}

class StatefulMobileSessionConnection {
  constructor(pool) {
    this.pool = pool
    this.transactionRows = null
    this.destroyed = false
  }

  async beginTransaction() {
    this.pool.lifecycle.push('begin')
    this.transactionRows = cloneRows(this.pool.rows)
  }

  async execute(sql, params) {
    if (/^\s*SELECT username[\s\S]+WHERE device_id = \?[\s\S]+FOR UPDATE\s*$/i.test(sql)) {
      this.pool.lifecycle.push('select-owner-for-update')
      const row = this.transactionRows.get(params[0])
      return [[row ? { username: row.username } : null].filter(Boolean)]
    }

    if (/^\s*UPDATE mobile_device_sessions/i.test(sql)) {
      this.pool.lifecycle.push('update-session')
      const [
        deviceName,
        accessHash,
        refreshHash,
        accessExpiresAt,
        refreshExpiresAt,
        deviceId,
        username,
      ] = params
      const current = this.transactionRows.get(deviceId)
      if (!current || current.username !== username) return [{ affectedRows: 0 }]
      const next = {
        ...current,
        device_name: deviceName,
        access_token_hash: accessHash,
        refresh_token_hash: refreshHash,
        access_expires_at: accessExpiresAt,
        refresh_expires_at: refreshExpiresAt,
        revoked_at: null,
        last_used_at: null,
      }
      assertUniqueHashes(this.transactionRows, next, deviceId)
      this.transactionRows.set(deviceId, next)
      return [{ affectedRows: 1 }]
    }

    if (/^\s*INSERT INTO mobile_device_sessions/i.test(sql)) {
      this.pool.lifecycle.push('insert-session')
      const [
        deviceId,
        username,
        deviceName,
        accessHash,
        refreshHash,
        accessExpiresAt,
        refreshExpiresAt,
      ] = params
      if (this.transactionRows.has(deviceId)) {
        const error = new Error('Duplicate device id')
        error.code = 'ER_DUP_ENTRY'
        throw error
      }
      const next = {
        device_id: deviceId,
        username,
        device_name: deviceName,
        access_token_hash: accessHash,
        refresh_token_hash: refreshHash,
        access_expires_at: accessExpiresAt,
        refresh_expires_at: refreshExpiresAt,
        created_at: new Date(this.pool.now),
        last_used_at: null,
        revoked_at: null,
      }
      assertUniqueHashes(this.transactionRows, next)
      this.transactionRows.set(deviceId, next)
      return [{ affectedRows: 1 }]
    }

    throw new Error(`unexpected connection SQL: ${sql.replace(/\s+/g, ' ').trim()}`)
  }

  async commit() {
    this.pool.lifecycle.push('commit')
    this.pool.rows = cloneRows(this.transactionRows)
    this.transactionRows = null
  }

  async rollback() {
    this.pool.lifecycle.push('rollback')
    if (this.pool.rollbackError) throw this.pool.rollbackError
    this.transactionRows = null
  }

  release() {
    this.pool.lifecycle.push('release')
  }

  destroy() {
    this.pool.lifecycle.push('destroy')
    this.destroyed = true
  }
}

module.exports = {
  StatefulMobileSessionPool,
  digest,
  sessionRow,
}
