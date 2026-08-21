const { MOBILE_ERROR_CODES } = require('../utils/mobileApiContract')

const SAFE_ERROR_FIELD = /^[A-Za-z0-9_.-]{1,100}$/

function safeErrorMetadata(error) {
  const metadata = {}
  const name = typeof error?.name === 'string' ? error.name : 'Error'
  metadata.name = SAFE_ERROR_FIELD.test(name) ? name : 'Error'
  if (typeof error?.code === 'string' && SAFE_ERROR_FIELD.test(error.code)) {
    metadata.code = error.code
  }
  return metadata
}

function logSafeError(logger, event, error) {
  try {
    if (logger && typeof logger.error === 'function') {
      logger.error(event, safeErrorMetadata(error))
    }
  } catch {
    // Logging must never replace the stable API response.
  }
}

function createApiErrorHandler({ logger = console } = {}) {
  return function apiErrorHandler(error, req, res, next) {
    if (res.headersSent) return next(error)
    logSafeError(logger, 'api request failed', error)
    if (error?.type === 'entity.too.large') {
      return res.status(413).json({ error: MOBILE_ERROR_CODES.payloadTooLarge })
    }
    return res.status(500).json({ error: MOBILE_ERROR_CODES.serverError })
  }
}

module.exports = { createApiErrorHandler, logSafeError, safeErrorMetadata }
