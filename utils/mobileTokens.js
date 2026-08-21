const crypto = require('node:crypto')

const ACCESS_TTL_MS = 15 * 60 * 1000
const REFRESH_TTL_MS = 180 * 24 * 60 * 60 * 1000

const randomToken = () => crypto.randomBytes(32).toString('base64url')
const hashToken = token => crypto.createHash('sha256').update(String(token)).digest('hex')

function issueTokenPair(now = new Date()) {
  return {
    accessToken: randomToken(),
    refreshToken: randomToken(),
    accessExpiresAt: new Date(now.getTime() + ACCESS_TTL_MS),
    refreshExpiresAt: new Date(now.getTime() + REFRESH_TTL_MS),
  }
}

module.exports = { ACCESS_TTL_MS, REFRESH_TTL_MS, hashToken, issueTokenPair }
