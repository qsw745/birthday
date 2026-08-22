const express = require('express')
const rateLimit = require('express-rate-limit')
const { MOBILE_API_CONTRACT, MOBILE_ERROR_CODES } = require('../utils/mobileApiContract')

const API_JSON_BODY_LIMIT = MOBILE_API_CONTRACT.limits.jsonBodyLimit
const DEFAULT_API_RATE_LIMIT = 300
const DEFAULT_API_RATE_WINDOW_MS = 15 * 60 * 1000
const MAX_API_RATE_LIMIT = 10000
const MAX_API_RATE_WINDOW_MS = 2147483647

function parseBoundedApiInteger(value, fallback, maximum) {
  if (typeof value === 'string' && !/^[1-9]\d*$/.test(value)) return fallback
  if (typeof value !== 'string' && typeof value !== 'number') return fallback
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= 1 && parsed <= maximum
    ? parsed
    : fallback
}

function resolveApiJsonBodyLimit(env = process.env) {
  const configured = env.JSON_BODY_LIMIT
  if (configured && configured !== API_JSON_BODY_LIMIT) {
    const error = new Error('JSON_BODY_LIMIT must be 64kb')
    error.code = 'invalid_json_body_limit'
    throw error
  }
  return API_JSON_BODY_LIMIT
}

function createApiLimiter({ env = process.env } = {}) {
  return rateLimit({
    windowMs: parseBoundedApiInteger(
      env.API_RATE_WINDOW_MS,
      DEFAULT_API_RATE_WINDOW_MS,
      MAX_API_RATE_WINDOW_MS,
    ),
    limit: parseBoundedApiInteger(
      env.API_RATE_LIMIT,
      DEFAULT_API_RATE_LIMIT,
      MAX_API_RATE_LIMIT,
    ),
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: MOBILE_ERROR_CODES.apiRateLimited },
  })
}

function installApiSurface({
  app,
  env = process.env,
  jsonParser,
  attachAuthMiddleware,
  apiLimiter,
  sameOriginMiddleware,
  apiRouter,
  apiErrorHandler,
}) {
  const jsonBodyLimit = resolveApiJsonBodyLimit(env)
  const parser = jsonParser || express.json({ limit: jsonBodyLimit })

  app.use(parser)
  app.use(attachAuthMiddleware)
  app.use('/api', apiLimiter, sameOriginMiddleware)
  app.use('/api', apiRouter)
  app.use('/api', apiErrorHandler)
  return app
}

module.exports = {
  API_JSON_BODY_LIMIT,
  createApiLimiter,
  installApiSurface,
  resolveApiJsonBodyLimit,
}
