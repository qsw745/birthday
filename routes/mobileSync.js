const express = require('express')
const { createMobileAuth } = require('../middleware/mobileAuth')
const {
  MobileSyncValidationError,
  normalizeCursor,
  normalizeLimit,
  normalizePushRequest,
} = require('../utils/mobileSyncContract')
const { SYNC_ROUTE_PATHS } = require('../utils/mobileApiContract')

function createMobileSyncRouter({
  syncRepository,
  mobileAuth,
  sessions,
  now = () => new Date(),
  calculateNextSolarDateFn,
}) {
  const router = express.Router()
  const requireMobileAuth = mobileAuth || createMobileAuth({ sessions, now })

  router.use(requireMobileAuth)

  router.get(SYNC_ROUTE_PATHS.snapshot, async (req, res) => {
    const result = await syncRepository.snapshot(req.mobileSession.username)
    return res.json(result)
  })

  router.get(SYNC_ROUTE_PATHS.pull, async (req, res) => {
    let cursor
    let limit
    try {
      cursor = normalizeCursor(req.query.cursor)
      limit = normalizeLimit(req.query.limit)
    } catch (error) {
      if (error instanceof MobileSyncValidationError) {
        return res.status(400).json({ error: error.code })
      }
      throw error
    }

    const result = await syncRepository.pull(cursor, limit)
    return res.json(result)
  })

  router.post(SYNC_ROUTE_PATHS.push, async (req, res) => {
    try {
      const { operations } = normalizePushRequest(req.body, {
        calculateNextSolarDateFn,
        nowInput: now(),
      })
      const deviceId = req.mobileSession.device_id || req.mobileSession.deviceId
      const results = []
      for (const operation of operations) {
        results.push(await syncRepository.applyOperation(deviceId, operation))
      }
      return res.json({ results })
    } catch (error) {
      if (error instanceof MobileSyncValidationError) {
        return res.status(400).json({ error: error.code })
      }
      throw error
    }
  })

  return router
}

module.exports = { createMobileSyncRouter }
