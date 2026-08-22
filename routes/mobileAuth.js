const express = require('express')
const rateLimit = require('express-rate-limit')
const { createMobileAuth } = require('../middleware/mobileAuth')
const { issueTokenPair } = require('../utils/mobileTokens')
const {
  AUTH_ROUTE_PATHS,
  MOBILE_ERROR_CODES,
} = require('../utils/mobileApiContract')

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
    revokedAt: dateOrNull(row.revoked_at),
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
    message: { error: MOBILE_ERROR_CODES.loginRateLimited },
  })
  const requireMobileAuth = mobileAuth || createMobileAuth({ sessions, now })

  router.post(AUTH_ROUTE_PATHS.login, loginLimiter, async (req, res) => {
    const body = req.body || {}
    if (!isLoginPayload(body)) {
      return res.status(400).json({ error: MOBILE_ERROR_CODES.invalidLogin })
    }

    const expectedUsername = env.AUTH_USERNAME
    const expectedHash = env.AUTH_PASSWORD_HASH
    if (!expectedUsername || !expectedHash) {
      return res.status(503).json({ error: MOBILE_ERROR_CODES.authUnconfigured })
    }

    const username = body.username.trim()
    const passwordMatches = await verifyPassword(body.password, expectedHash)
    if (username !== expectedUsername || !passwordMatches) {
      return res.status(401).json({ error: MOBILE_ERROR_CODES.loginInvalid })
    }

    const currentTime = now()
    const pair = issueTokenPair(currentTime)
    const bindSession = sessions.bindSession || sessions.createSession
    await bindSession.call(sessions, {
      deviceId: body.deviceId,
      username: expectedUsername,
      deviceName: body.deviceName.trim(),
      pair,
    })
    return res.json({ deviceId: body.deviceId, ...tokenResponse(pair) })
  })

  router.post(AUTH_ROUTE_PATHS.refresh, async (req, res) => {
    const refreshToken = req.body && req.body.refreshToken
    if (typeof refreshToken !== 'string' || !OPAQUE_TOKEN_PATTERN.test(refreshToken)) {
      return res.status(400).json({ error: MOBILE_ERROR_CODES.invalidRefresh })
    }

    const currentTime = now()
    const pair = issueTokenPair(currentTime)
    const rotated = await sessions.rotateByRefreshToken(refreshToken, pair, currentTime)
    if (!rotated) {
      return res.status(401).json({ error: MOBILE_ERROR_CODES.refreshInvalid })
    }
    return res.json({ deviceId: rotated.deviceId, ...tokenResponse(pair) })
  })

  router.post(AUTH_ROUTE_PATHS.revoke, requireMobileAuth, async (req, res) => {
    const deviceId = req.body && req.body.deviceId
    if (!isUuid(deviceId)) {
      return res.status(400).json({ error: MOBILE_ERROR_CODES.invalidDevice })
    }

    const revoked = await sessions.revoke(deviceId, req.mobileSession.username)
    if (!revoked) {
      return res.status(404).json({ error: MOBILE_ERROR_CODES.deviceNotFound })
    }
    return res.json({ success: true })
  })

  router.get(AUTH_ROUTE_PATHS.devices, requireMobileAuth, async (req, res) => {
    const devices = await sessions.list(req.mobileSession.username)
    return res.json({ devices: devices.map(serializeDevice) })
  })

  return router
}

module.exports = { createMobileAuthRouter }
