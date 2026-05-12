const express = require('express')
const rateLimit = require('express-rate-limit')
const { clearSessionCookie, destroySession, requireAuth, setSessionCookie, verifyPassword } = require('../utils/auth')

const router = express.Router()

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: Number(process.env.AUTH_LOGIN_LIMIT || 10),
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: '登录尝试过多，请稍后再试' },
})

router.get('/status', (req, res) => {
  res.json({
    authenticated: !!req.session,
    username: req.session ? req.session.sub : null,
  })
})

router.post('/login', loginLimiter, async (req, res) => {
  const username = String(req.body.username || '').trim()
  const password = String(req.body.password || '')
  const expectedUsername = process.env.AUTH_USERNAME
  const expectedHash = process.env.AUTH_PASSWORD_HASH

  if (!expectedUsername || !expectedHash) {
    return res.status(503).json({ error: '登录未配置' })
  }

  const usernameMatches = username === expectedUsername
  const passwordMatches = await verifyPassword(password, expectedHash)
  if (!usernameMatches || !passwordMatches) {
    return res.status(401).json({ error: '用户名或密码错误' })
  }

  setSessionCookie(res, expectedUsername)
  res.json({ success: true, username: expectedUsername })
})

router.post('/logout', requireAuth, (req, res) => {
  destroySession(req.session)
  clearSessionCookie(res)
  res.json({ success: true })
})

module.exports = router
