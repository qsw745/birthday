const express = require('express')
const rateLimit = require('express-rate-limit')
const { createMobileAuth } = require('../middleware/mobileAuth')
const { issueTokenPair } = require('../utils/mobileTokens')

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const OPAQUE_TOKEN_PATTERN = /^[A-Za-z0-9_-]+$/
const DEFAULT_LOGIN_WINDOW_MS = 15 * 60 * 1000
const DEFAULT_LOGIN_LIMIT = 10
const MAX_LOGIN_LIMIT = 10000
const MAX_LOGIN_WINDOW_MS = 2147483647

function parseBoundedSafeInteger(value, fallback, maximum) {
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= 1 && parsed <= maximum ? parsed : fallback
}

function parseLoginLimit(value) {
  return parseBoundedSafeInteger(value, DEFAULT_LOGIN_LIMIT, MAX_LOGIN_LIMIT)
}

function parseLoginWindowMs(value) {
  return parseBoundedSafeInteger(value, DEFAULT_LOGIN_WINDOW_MS, MAX_LOGIN_WINDOW_MS)
}

function isUuid(value) {
  return typeof value === 'string' && UUID_PATTERN.test(value)
}

function isLoginPayload(body) {
  return typeof body.username === 'string'
    && body.username.trim().length > 0
    && typeof body.password === 'string'
    && body.password.length > 0
    && isUuid(body.deviceId)
    && typeof body.deviceName === 'string'
    && body.deviceName.trim().length >= 1
    && body.deviceName.trim().length <= 100
}

function tokenResponse(pair) {
  return {
    accessToken: pair.accessToken,
    accessExpiresAt: pair.accessExpiresAt.toISOString(),
    refreshToken: pair.refreshToken,
    refreshExpiresAt: pair.refreshExpiresAt.toISOString(),
  }
}

function dateOrNull(value) {
  if (value == null) return null
  return new Date(value).toISOString()
}

function serializeDevice(row) {
  return {
    deviceId: row.device_id,
    deviceName: row.device_name,
    createdAt: dateOrNull(row.created_at),
    lastUsedAt: dateOrNull(row.last_used_at),
    accessExpiresAt: dateOrNull(row.access_expires_at),
    refreshExpiresAt: dateOrNull(row.refresh_expires_at),
  }
}

function createMobileAuthRouter({
  sessions,
  verifyPassword,
  env = process.env,
  now = () => new Date(),
  mobileAuth,
}) {
  const router = express.Router()
  const loginLimiter = rateLimit({
    windowMs: parseLoginWindowMs(env.AUTH_LOGIN_WINDOW_MS),
    limit: parseLoginLimit(env.AUTH_LOGIN_LIMIT),
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: '登录尝试过多，请稍后再试' },
  })
  const requireMobileAuth = mobileAuth || createMobileAuth({ sessions, now })

  router.post('/login', loginLimiter, async (req, res) => {
    const body = req.body || {}
    if (!isLoginPayload(body)) {
      return res.status(400).json({ error: 'invalid_mobile_login' })
    }

    const expectedUsername = env.AUTH_USERNAME
    const expectedHash = env.AUTH_PASSWORD_HASH
    if (!expectedUsername || !expectedHash) {
      return res.status(503).json({ error: 'mobile_auth_unconfigured' })
    }

    const username = body.username.trim()
    const passwordMatches = await verifyPassword(body.password, expectedHash)
    if (username !== expectedUsername || !passwordMatches) {
      return res.status(401).json({ error: 'mobile_login_invalid' })
    }

    const currentTime = now()
    const pair = issueTokenPair(currentTime)
    await sessions.createSession({
      deviceId: body.deviceId,
      username: expectedUsername,
      deviceName: body.deviceName.trim(),
      pair,
    })
    return res.json({ deviceId: body.deviceId, ...tokenResponse(pair) })
  })

  router.post('/refresh', async (req, res) => {
    const refreshToken = req.body && req.body.refreshToken
    if (typeof refreshToken !== 'string' || !OPAQUE_TOKEN_PATTERN.test(refreshToken)) {
      return res.status(400).json({ error: 'invalid_mobile_refresh' })
    }

    const currentTime = now()
    const pair = issueTokenPair(currentTime)
    const rotated = await sessions.rotateByRefreshToken(refreshToken, pair, currentTime)
    if (!rotated) {
      return res.status(401).json({ error: 'mobile_refresh_invalid' })
    }
    return res.json(tokenResponse(pair))
  })

  router.post('/revoke', requireMobileAuth, async (req, res) => {
    const deviceId = req.body && req.body.deviceId
    if (!isUuid(deviceId)) {
      return res.status(400).json({ error: 'invalid_mobile_device' })
    }

    const revoked = await sessions.revoke(deviceId, req.mobileSession.username)
    if (!revoked) {
      return res.status(404).json({ error: 'mobile_device_not_found' })
    }
    return res.json({ success: true })
  })

  router.get('/devices', requireMobileAuth, async (req, res) => {
    const devices = await sessions.list(req.mobileSession.username)
    return res.json({ devices: devices.map(serializeDevice) })
  })

  return router
}

module.exports = { createMobileAuthRouter }
