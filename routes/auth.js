const express = require('express')
const fs = require('fs')
const path = require('path')
const rateLimit = require('express-rate-limit')
const {
  clearSessionCookie,
  destroyAllSessions,
  destroySession,
  hashPassword,
  requireAuth,
  setSessionCookie,
  verifyPassword,
} = require('../utils/auth')

const router = express.Router()

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: Number(process.env.AUTH_LOGIN_LIMIT || 10),
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: '登录尝试过多，请稍后再试' },
})

function updateEnvValue(key, value) {
  const envPath = path.join(__dirname, '../.env')
  const current = fs.existsSync(envPath) ? fs.readFileSync(envPath, 'utf8').split(/\r?\n/) : []
  let found = false
  const next = current.map(line => {
    if (line.startsWith(`${key}=`)) {
      found = true
      return `${key}=${value}`
    }
    return line
  })
  if (!found) next.push(`${key}=${value}`)
  fs.writeFileSync(envPath, `${next.filter((line, index) => line || index < next.length - 1).join('\n')}\n`, {
    mode: 0o600,
  })
}

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

router.post('/password', requireAuth, async (req, res) => {
  const currentPassword = String(req.body.currentPassword || '')
  const newPassword = String(req.body.newPassword || '')
  const expectedHash = process.env.AUTH_PASSWORD_HASH

  if (newPassword.length < 8 || newPassword.length > 128) {
    return res.status(400).json({ error: '新密码长度需要在 8 到 128 位之间' })
  }

  const passwordMatches = await verifyPassword(currentPassword, expectedHash)
  if (!passwordMatches) {
    return res.status(401).json({ error: '当前密码不正确' })
  }

  const nextHash = await hashPassword(newPassword)
  updateEnvValue('AUTH_PASSWORD_HASH', nextHash)
  process.env.AUTH_PASSWORD_HASH = nextHash
  destroyAllSessions()
  clearSessionCookie(res)
  res.json({ success: true })
})

module.exports = router
