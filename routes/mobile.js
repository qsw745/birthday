const express = require('express')
const { createApiErrorHandler } = require('../middleware/apiError')
const { createMobileAuth } = require('../middleware/mobileAuth')
const { createMobileSessionRepository } = require('../repositories/mobileSessionRepository')
const { createMobileSyncRepository } = require('../repositories/mobileSyncRepository')
const { MOBILE_API_CONTRACT } = require('../utils/mobileApiContract')
const { createMobileAuthRouter } = require('./mobileAuth')
const { createMobileSyncRouter } = require('./mobileSync')

function createMobileRouter({ authRouter, syncRouter, logger = console }) {
  const router = express.Router()
  router.use(MOBILE_API_CONTRACT.mounts.auth, authRouter)
  router.use(MOBILE_API_CONTRACT.mounts.sync, syncRouter)
  router.use(createApiErrorHandler({
    logger: {
      error(_event, metadata) {
        try {
          if (logger && typeof logger.error === 'function') {
            logger.error('mobile request failed', metadata)
          }
        } catch {
          // Logging must never replace the stable mobile response.
        }
      },
    },
  }))
  return router
}

function createProductionMobileRouter({
  pool = require('../utils/db').pool,
  env = process.env,
  now = () => new Date(),
  calculateNextSolarDateFn = require('../utils/helpers').calculateNextSolarDate,
  verifyPassword = require('../utils/auth').verifyPassword,
  logger = console,
} = {}) {
  const sessions = createMobileSessionRepository({ pool, now })
  const syncRepository = createMobileSyncRepository({ pool })
  const mobileAuth = createMobileAuth({ sessions, now })
  const authRouter = createMobileAuthRouter({ sessions, verifyPassword, env, now, mobileAuth })
  const syncRouter = createMobileSyncRouter({
    syncRepository,
    mobileAuth,
    now,
    calculateNextSolarDateFn,
  })
  return createMobileRouter({ authRouter, syncRouter, logger })
}

module.exports = {
  MOBILE_API_CONTRACT,
  createMobileRouter,
  createProductionMobileRouter,
}
