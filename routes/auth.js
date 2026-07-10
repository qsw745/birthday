const express = require('express')
const fs = require('fs')
const path = require('path')
const rateLimit = require('express-rate-limit')
const {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} = require('@simplewebauthn/server')
const {
  clearSessionCookie,
  destroyAllSessions,
  destroySession,
  hashPassword,
  requireAuth,
  setSessionCookie,
  verifyPassword,
} = require('../utils/auth')
const {
  EXPECTED_ORIGINS,
  RP_ID,
  RP_NAME,
  consumeChallenge,
  deleteCredential,
  getCredential,
  listCredentials,
  parseTransports,
  saveCredential,
  stableUserId,
  storeChallenge,
  updateCredentialUsage,
} = require('../utils/webauthn')

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

router.post('/webauthn/register/options', requireAuth, async (req, res) => {
  try {
    const username = req.session.sub
    const existing = await listCredentials(username)
    const options = await generateRegistrationOptions({
      rpName: RP_NAME,
      rpID: RP_ID,
      userName: username,
      userID: stableUserId(username),
      attestationType: 'none',
      excludeCredentials: existing.map(row => ({
        id: row.credential_id,
        transports: parseTransports(row.transports),
      })),
      authenticatorSelection: {
        residentKey: 'preferred',
        userVerification: 'required',
      },
    })
    const token = storeChallenge('register', options.challenge, username)
    res.json({ token, options })
  } catch (error) {
    console.error('[webauthn] register options failed:', error)
    res.status(500).json({ error: '生成注册参数失败' })
  }
})

router.post('/webauthn/register/verify', requireAuth, async (req, res) => {
  const entry = consumeChallenge(req.body.token, 'register')
  if (!entry || entry.username !== req.session.sub) {
    return res.status(400).json({ error: '注册请求已过期，请重试' })
  }

  try {
    const { verified, registrationInfo } = await verifyRegistrationResponse({
      response: req.body.response,
      expectedChallenge: entry.challenge,
      expectedOrigin: EXPECTED_ORIGINS,
      expectedRPID: RP_ID,
      requireUserVerification: true,
    })
    if (!verified || !registrationInfo) {
      return res.status(400).json({ error: '通行密钥验证未通过' })
    }

    const { credential } = registrationInfo
    const deviceName = String(req.body.deviceName || '').trim().slice(0, 100) || '通行密钥'
    await saveCredential({
      credentialId: credential.id,
      username: entry.username,
      publicKey: credential.publicKey,
      counter: credential.counter,
      transports: credential.transports,
      deviceName,
    })
    res.json({ success: true })
  } catch (error) {
    console.error('[webauthn] register verify failed:', error)
    res.status(400).json({ error: '通行密钥注册失败' })
  }
})

router.get('/webauthn/credentials', requireAuth, async (req, res) => {
  try {
    const rows = await listCredentials(req.session.sub)
    res.json(
      rows.map(row => ({
        id: row.credential_id,
        deviceName: row.device_name || '通行密钥',
        createdAt: row.created_at,
        lastUsedAt: row.last_used_at,
      }))
    )
  } catch (error) {
    console.error('[webauthn] list credentials failed:', error)
    res.status(500).json({ error: '获取通行密钥列表失败' })
  }
})

router.delete('/webauthn/credentials/:id', requireAuth, async (req, res) => {
  try {
    const removed = await deleteCredential(String(req.params.id || ''), req.session.sub)
    if (!removed) {
      return res.status(404).json({ error: '未找到该通行密钥' })
    }
    res.json({ success: true })
  } catch (error) {
    console.error('[webauthn] delete credential failed:', error)
    res.status(500).json({ error: '删除通行密钥失败' })
  }
})

router.post('/webauthn/login/options', loginLimiter, async (req, res) => {
  const username = process.env.AUTH_USERNAME
  if (!username) {
    return res.status(503).json({ error: '登录未配置' })
  }

  try {
    const credentials = await listCredentials(username)
    if (!credentials.length) {
      return res.status(400).json({ error: '尚未注册通行密钥，请先用密码登录后添加' })
    }
    const options = await generateAuthenticationOptions({
      rpID: RP_ID,
      userVerification: 'required',
      allowCredentials: credentials.map(row => ({
        id: row.credential_id,
        transports: parseTransports(row.transports),
      })),
    })
    const token = storeChallenge('login', options.challenge, username)
    res.json({ token, options })
  } catch (error) {
    console.error('[webauthn] login options failed:', error)
    res.status(500).json({ error: '生成登录参数失败' })
  }
})

router.post('/webauthn/login/verify', loginLimiter, async (req, res) => {
  const entry = consumeChallenge(req.body.token, 'login')
  if (!entry) {
    return res.status(400).json({ error: '登录请求已过期，请重试' })
  }

  try {
    const response = req.body.response
    const credential = await getCredential(String((response && response.id) || ''))
    if (!credential || credential.username !== entry.username) {
      return res.status(401).json({ error: '通行密钥无效' })
    }

    const { verified, authenticationInfo } = await verifyAuthenticationResponse({
      response,
      expectedChallenge: entry.challenge,
      expectedOrigin: EXPECTED_ORIGINS,
      expectedRPID: RP_ID,
      requireUserVerification: true,
      credential: {
        id: credential.credential_id,
        publicKey: new Uint8Array(credential.public_key),
        counter: Number(credential.counter),
        transports: parseTransports(credential.transports),
      },
    })
    if (!verified) {
      return res.status(401).json({ error: '通行密钥验证失败' })
    }

    await updateCredentialUsage(credential.credential_id, authenticationInfo.newCounter)
    setSessionCookie(res, credential.username)
    res.json({ success: true, username: credential.username })
  } catch (error) {
    console.error('[webauthn] login verify failed:', error)
    res.status(401).json({ error: '通行密钥登录失败' })
  }
})

module.exports = router
