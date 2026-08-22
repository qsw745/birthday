const { hashToken } = require('../utils/mobileTokens')
const { MOBILE_ERROR_CODES } = require('../utils/mobileApiContract')

function safeErrorMetadata(error) {
  const metadata = {
    name: typeof error?.name === 'string' ? error.name : 'Error',
  }
  if (typeof error?.code === 'string') metadata.code = error.code
  return metadata
}

function attachRollbackFailure(primaryError, rollbackError) {
  if (!primaryError || (typeof primaryError !== 'object' && typeof primaryError !== 'function')) {
    return
  }
  try {
    Object.defineProperty(primaryError, 'rollbackFailure', {
      configurable: true,
      enumerable: false,
      value: safeErrorMetadata(rollbackError),
    })
  } catch {
    // Preserve a frozen third-party error as the primary failure.
  }
}

async function rollbackAfterFailure(connection, primaryError) {
  try {
    await connection.rollback()
    return false
  } catch (rollbackError) {
    attachRollbackFailure(primaryError, rollbackError)
    try {
      if (typeof connection.destroy === 'function') connection.destroy()
    } catch {
      // A tainted connection must never be returned to the pool.
    }
    return true
  }
}

function deviceOwnershipConflict() {
  const error = new Error('mobile device ownership conflict')
  error.name = 'MobileDeviceOwnershipConflictError'
  error.code = MOBILE_ERROR_CODES.deviceOwnershipConflict
  return error
}

function createMobileSessionRepository({ pool, now = () => new Date() }) {
  async function bindSession({ deviceId, username, deviceName, pair }) {
    const connection = await pool.getConnection()
    let destroyed = false
    let transactionStarted = false
    try {
      await connection.beginTransaction()
      transactionStarted = true
      const [rows] = await connection.execute(
        `SELECT username
         FROM mobile_device_sessions
         WHERE device_id = ?
         FOR UPDATE`,
        [deviceId],
      )
      const current = rows[0]
      if (current && current.username !== username) throw deviceOwnershipConflict()

      const accessTokenHash = hashToken(pair.accessToken)
      const refreshTokenHash = hashToken(pair.refreshToken)
      if (current) {
        const [result] = await connection.execute(
          `UPDATE mobile_device_sessions
           SET device_name = ?,
               access_token_hash = ?,
               refresh_token_hash = ?,
               access_expires_at = ?,
               refresh_expires_at = ?,
               revoked_at = NULL,
               last_used_at = NULL
           WHERE device_id = ?
             AND username = ?`,
          [
            deviceName,
            accessTokenHash,
            refreshTokenHash,
            pair.accessExpiresAt,
            pair.refreshExpiresAt,
            deviceId,
            username,
          ],
        )
        if (result.affectedRows !== 1) {
          const error = new Error('mobile session rebind failed')
          error.code = 'mobile_session_rebind_failed'
          throw error
        }
      } else {
        await connection.execute(
          `INSERT INTO mobile_device_sessions (
            device_id, username, device_name, access_token_hash, refresh_token_hash,
            access_expires_at, refresh_expires_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
          [
            deviceId,
            username,
            deviceName,
            accessTokenHash,
            refreshTokenHash,
            pair.accessExpiresAt,
            pair.refreshExpiresAt,
          ],
        )
      }

      await connection.commit()
      transactionStarted = false
    } catch (error) {
      if (transactionStarted) destroyed = await rollbackAfterFailure(connection, error)
      throw error
    } finally {
      if (!destroyed) connection.release()
    }
  }

  const createSession = bindSession

  async function findByAccessToken(accessToken, currentTime = now()) {
    const [rows] = await pool.execute(
      `SELECT device_id, username, device_name, access_expires_at, refresh_expires_at,
              created_at, last_used_at
       FROM mobile_device_sessions
       WHERE access_token_hash = ?
         AND revoked_at IS NULL
         AND access_expires_at > ?`,
      [hashToken(accessToken), currentTime],
    )
    return rows[0] || null
  }

  async function rotateByRefreshToken(refreshToken, nextPair, currentTime = now()) {
    const refreshTokenHash = hashToken(refreshToken)
    const [rows] = await pool.execute(
      `SELECT device_id
       FROM mobile_device_sessions
       WHERE refresh_token_hash = ?
         AND revoked_at IS NULL
         AND refresh_expires_at > ?`,
      [refreshTokenHash, currentTime],
    )
    const session = rows[0]
    if (!session) return null

    const [result] = await pool.execute(
      `UPDATE mobile_device_sessions
       SET access_token_hash = ?, refresh_token_hash = ?, access_expires_at = ?,
           refresh_expires_at = ?, last_used_at = ?
       WHERE refresh_token_hash = ?
         AND device_id = ?
         AND revoked_at IS NULL
         AND refresh_expires_at > ?`,
      [
        hashToken(nextPair.accessToken),
        hashToken(nextPair.refreshToken),
        nextPair.accessExpiresAt,
        nextPair.refreshExpiresAt,
        currentTime,
        refreshTokenHash,
        session.device_id,
        currentTime,
      ],
    )
    return result.affectedRows > 0
      ? { rotated: true, deviceId: session.device_id }
      : null
  }

  async function revoke(deviceId, username) {
    const [result] = await pool.execute(
      `UPDATE mobile_device_sessions
       SET revoked_at = ?
       WHERE device_id = ?
         AND username = ?
         AND revoked_at IS NULL`,
      [now(), deviceId, username],
    )
    return result.affectedRows > 0
  }

  async function list(username) {
    const [rows] = await pool.execute(
      `SELECT device_id, username, device_name, created_at, last_used_at,
              revoked_at
       FROM mobile_device_sessions
       WHERE username = ?
         AND revoked_at IS NULL
       ORDER BY created_at DESC`,
      [username],
    )
    return rows
  }

  return { bindSession, createSession, findByAccessToken, rotateByRefreshToken, revoke, list }
}

module.exports = { createMobileSessionRepository }
