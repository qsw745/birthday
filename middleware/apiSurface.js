const express = require('express')
const rateLimit = require('express-rate-limit')
const { MOBILE_API_CONTRACT, MOBILE_ERROR_CODES } = require('../utils/mobileApiContract')

const API_JSON_BODY_LIMIT = MOBILE_API_CONTRACT.limits.jsonBodyLimit

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
    windowMs: 15 * 60 * 1000,
    limit: Number(env.API_RATE_LIMIT || 300),
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
