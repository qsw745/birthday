const { MOBILE_ERROR_CODES } = require('../utils/mobileApiContract')

function createMobileAuth({ sessions, now = () => new Date() }) {
  return async function mobileAuth(req, res, next) {
    const match = String(req.headers.authorization || '').match(/^Bearer ([^\s]+)$/)
    if (!match) return res.status(401).json({ error: MOBILE_ERROR_CODES.authRequired })

    const session = await sessions.findByAccessToken(match[1], now())
    if (!session) return res.status(401).json({ error: MOBILE_ERROR_CODES.accessExpired })

    req.mobileSession = session
    return next()
  }
}

module.exports = { createMobileAuth }
