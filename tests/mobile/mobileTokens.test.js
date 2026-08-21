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

test('token pair requests exactly two 32-byte values and serializes each canonically', t => {
  const requestedLengths = []
  t.mock.method(crypto, 'randomBytes', length => {
    requestedLengths.push(length)
    return Buffer.alloc(32, requestedLengths.length)
  })

  const pair = issueTokenPair(new Date('2026-08-21T00:00:00Z'))

  assert.deepEqual(requestedLengths, [32, 32])
  for (const token of [pair.accessToken, pair.refreshToken]) {
    const decoded = Buffer.from(token, 'base64url')
    assert.equal(decoded.length, 32)
    assert.equal(decoded.toString('base64url'), token)
  }
})

test('hashToken produces the SHA-256 hexadecimal digest used for storage', () => {
  const token = 'a-mobile-token-that-must-never-reach-the-database'
  const expected = crypto.createHash('sha256').update(token).digest('hex')

  assert.equal(hashToken(token), expected)
  assert.match(hashToken(token), /^[a-f0-9]{64}$/)
})
