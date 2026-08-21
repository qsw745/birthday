const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const { hashToken, issueTokenPair } = require('../../utils/mobileTokens')

test('token pair uses independent 32-byte base64url values and exact lifetimes', () => {
  const now = new Date('2026-08-21T00:00:00Z')
  const pair = issueTokenPair(now)

  assert.match(pair.accessToken, /^[A-Za-z0-9_-]{43}$/)
  assert.match(pair.refreshToken, /^[A-Za-z0-9_-]{43}$/)
  assert.notEqual(pair.accessToken, pair.refreshToken)
  assert.equal(pair.accessExpiresAt.toISOString(), '2026-08-21T00:15:00.000Z')
  assert.equal(pair.refreshExpiresAt.toISOString(), '2027-02-17T00:00:00.000Z')
})

test('hashToken produces the SHA-256 hexadecimal digest used for storage', () => {
  const token = 'a-mobile-token-that-must-never-reach-the-database'
  const expected = crypto.createHash('sha256').update(token).digest('hex')

  assert.equal(hashToken(token), expected)
  assert.match(hashToken(token), /^[a-f0-9]{64}$/)
})
