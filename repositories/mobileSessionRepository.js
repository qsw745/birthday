const { hashToken } = require('../utils/mobileTokens')

function createMobileSessionRepository({ pool, now = () => new Date() }) {
  async function createSession({ deviceId, username, deviceName, pair }) {
    await pool.execute(
      `INSERT INTO mobile_device_sessions (
        device_id, username, device_name, access_token_hash, refresh_token_hash,
        access_expires_at, refresh_expires_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [
        deviceId,
        username,
        deviceName,
        hashToken(pair.accessToken),
        hashToken(pair.refreshToken),
        pair.accessExpiresAt,
        pair.refreshExpiresAt,
      ],
    )
  }

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

  return { createSession, findByAccessToken, rotateByRefreshToken, revoke, list }
}

module.exports = { createMobileSessionRepository }
