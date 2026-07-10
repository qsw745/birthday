const crypto = require('crypto')
const { query } = require('./db')

const CHALLENGE_TTL_MS = 5 * 60 * 1000
const RP_ID = process.env.WEBAUTHN_RP_ID || 'qisw.top'
const RP_NAME = process.env.WEBAUTHN_RP_NAME || '生日提醒中心'
const EXPECTED_ORIGINS = (process.env.WEBAUTHN_ORIGINS || `https://${RP_ID},https://www.${RP_ID},https://${RP_ID}:3300`)
  .split(',')
  .map(origin => origin.trim())
  .filter(Boolean)

const pendingChallenges = new Map()

function pruneExpiredChallenges() {
  const now = Date.now()
  for (const [token, entry] of pendingChallenges) {
    if (entry.expiresAt <= now) pendingChallenges.delete(token)
  }
}

function storeChallenge(purpose, challenge, username) {
  pruneExpiredChallenges()
  const token = crypto.randomBytes(24).toString('base64url')
  pendingChallenges.set(token, {
    purpose,
    challenge,
    username,
    expiresAt: Date.now() + CHALLENGE_TTL_MS,
  })
  return token
}

function consumeChallenge(token, purpose) {
  pruneExpiredChallenges()
  const entry = pendingChallenges.get(String(token || ''))
  if (!entry) return null
  pendingChallenges.delete(String(token))
  if (entry.purpose !== purpose) return null
  return entry
}

function stableUserId(username) {
  return new Uint8Array(crypto.createHash('sha256').update(`birthday-admin:${username}`).digest())
}

function parseTransports(value) {
  try {
    const parsed = JSON.parse(value)
    return Array.isArray(parsed) ? parsed : undefined
  } catch {
    return undefined
  }
}

async function listCredentials(username) {
  return query(
    `SELECT credential_id, username, counter, transports, device_name, created_at, last_used_at
       FROM webauthn_credentials WHERE username = ? ORDER BY created_at ASC`,
    [username]
  )
}

async function getCredential(credentialId) {
  const rows = await query('SELECT * FROM webauthn_credentials WHERE credential_id = ?', [credentialId])
  return rows[0] || null
}

async function saveCredential({ credentialId, username, publicKey, counter, transports, deviceName }) {
  await query(
    `INSERT INTO webauthn_credentials (credential_id, username, public_key, counter, transports, device_name)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [
      credentialId,
      username,
      Buffer.from(publicKey),
      counter,
      transports && transports.length ? JSON.stringify(transports) : null,
      deviceName || null,
    ]
  )
}

async function updateCredentialUsage(credentialId, counter) {
  await query('UPDATE webauthn_credentials SET counter = ?, last_used_at = NOW() WHERE credential_id = ?', [
    counter,
    credentialId,
  ])
}

async function deleteCredential(credentialId, username) {
  const rows = await query('DELETE FROM webauthn_credentials WHERE credential_id = ? AND username = ?', [
    credentialId,
    username,
  ])
  return rows.affectedRows > 0
}

module.exports = {
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
}
