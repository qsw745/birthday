const crypto = require('crypto')

const COOKIE_NAME = process.env.AUTH_COOKIE_NAME || 'birthday_session'
const SESSION_TTL_SECONDS = Number(process.env.AUTH_SESSION_TTL_SECONDS || 60 * 60 * 12)
const SCRYPT_KEYLEN = 64
const sessions = new Map()

function getSessionSecret() {
  const secret = process.env.AUTH_SESSION_SECRET
  if (!secret || secret.length < 32) {
    throw new Error('AUTH_SESSION_SECRET must be set to at least 32 characters')
  }
  return secret
}

function parseCookies(header = '') {
  return header.split(';').reduce((cookies, pair) => {
    const index = pair.indexOf('=')
    if (index === -1) return cookies
    const key = pair.slice(0, index).trim()
    const value = pair.slice(index + 1).trim()
    if (!key) return cookies
    cookies[key] = decodeURIComponent(value)
    return cookies
  }, {})
}

function base64url(input) {
  return Buffer.from(input).toString('base64url')
}

function sign(value) {
  return crypto.createHmac('sha256', getSessionSecret()).update(value).digest('base64url')
}

function timingSafeEqualString(a, b) {
  const left = Buffer.from(String(a))
  const right = Buffer.from(String(b))
  if (left.length !== right.length) return false
  return crypto.timingSafeEqual(left, right)
}

function createSessionCookie(username) {
  const now = Math.floor(Date.now() / 1000)
  const sid = crypto.randomBytes(32).toString('base64url')
  const session = {
    sid,
    sub: username,
    iat: now,
    exp: now + SESSION_TTL_SECONDS,
  }
  sessions.set(sid, session)
  const payload = base64url(
    JSON.stringify(session)
  )
  return `${payload}.${sign(payload)}`
}

function readSession(req) {
  const cookie = parseCookies(req.headers.cookie || '')[COOKIE_NAME]
  if (!cookie) return null

  const [payload, signature] = cookie.split('.')
  if (!payload || !signature || !timingSafeEqualString(signature, sign(payload))) {
    return null
  }

  try {
    const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'))
    if (!data || !data.sid || !data.sub || !data.exp || data.exp <= Math.floor(Date.now() / 1000)) {
      if (data && data.sid) sessions.delete(data.sid)
      return null
    }
    const session = sessions.get(data.sid)
    if (!session || session.exp !== data.exp || session.sub !== data.sub) return null
    return session
  } catch {
    return null
  }
}

function setSessionCookie(res, username) {
  const secure = process.env.AUTH_COOKIE_SECURE !== 'false'
  const attributes = [
    `${COOKIE_NAME}=${encodeURIComponent(createSessionCookie(username))}`,
    'HttpOnly',
    'SameSite=Lax',
    'Path=/',
    `Max-Age=${SESSION_TTL_SECONDS}`,
  ]
  if (secure) attributes.push('Secure')
  res.setHeader('Set-Cookie', attributes.join('; '))
}

function clearSessionCookie(res) {
  const secure = process.env.AUTH_COOKIE_SECURE !== 'false'
  const attributes = [`${COOKIE_NAME}=`, 'HttpOnly', 'SameSite=Lax', 'Path=/', 'Max-Age=0']
  if (secure) attributes.push('Secure')
  res.setHeader('Set-Cookie', attributes.join('; '))
}

function destroySession(session) {
  if (session && session.sid) {
    sessions.delete(session.sid)
  }
}

function hashPassword(password, salt = crypto.randomBytes(16).toString('base64url')) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, SCRYPT_KEYLEN, (err, derivedKey) => {
      if (err) return reject(err)
      resolve(`scrypt$${salt}$${derivedKey.toString('base64url')}`)
    })
  })
}

function verifyPassword(password, storedHash) {
  return new Promise(resolve => {
    if (!password || !storedHash) return resolve(false)
    const [scheme, salt, expected] = storedHash.split('$')
    if (scheme !== 'scrypt' || !salt || !expected) return resolve(false)

    crypto.scrypt(password, salt, SCRYPT_KEYLEN, (err, derivedKey) => {
      if (err) return resolve(false)
      const actual = derivedKey.toString('base64url')
      resolve(timingSafeEqualString(actual, expected))
    })
  })
}

function attachAuth(req, res, next) {
  req.session = readSession(req)
  next()
}

function requireAuth(req, res, next) {
  if (req.session) return next()
  res.status(401).json({ error: '需要登录' })
}

function requirePageAuth(req, res, next) {
  if (req.session) return next()
  const basePath = process.env.APP_BASE_PATH || '/birthday'
  res.redirect(`${basePath}/login`)
}

module.exports = {
  COOKIE_NAME,
  SESSION_TTL_SECONDS,
  attachAuth,
  clearSessionCookie,
  destroySession,
  hashPassword,
  requireAuth,
  requirePageAuth,
  setSessionCookie,
  verifyPassword,
}
