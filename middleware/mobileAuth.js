function createMobileAuth({ sessions, now = () => new Date() }) {
  return async function mobileAuth(req, res, next) {
    const match = String(req.headers.authorization || '').match(/^Bearer ([^\s]+)$/)
    if (!match) return res.status(401).json({ error: 'mobile_auth_required' })

    const session = await sessions.findByAccessToken(match[1], now())
    if (!session) return res.status(401).json({ error: 'mobile_access_expired' })

    req.mobileSession = session
    return next()
  }
}

module.exports = { createMobileAuth }
