const express = require('express')
const { createMobileAuth } = require('../middleware/mobileAuth')
const {
  MobileSyncValidationError,
  normalizeCursor,
  normalizeLimit,
} = require('../utils/mobileSyncContract')

function createMobileSyncRouter({
  syncRepository,
  mobileAuth,
  sessions,
  now = () => new Date(),
}) {
  const router = express.Router()
  const requireMobileAuth = mobileAuth || createMobileAuth({ sessions, now })

  router.use(requireMobileAuth)

  router.get('/snapshot', async (req, res) => {
    const result = await syncRepository.snapshot(req.mobileSession.username)
    return res.json(result)
  })

  router.get('/pull', async (req, res) => {
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

  return router
}

module.exports = { createMobileSyncRouter }
