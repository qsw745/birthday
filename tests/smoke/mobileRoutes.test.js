const test = require('node:test')
const assert = require('node:assert/strict')
const express = require('express')
const request = require('supertest')
const { createTestApp } = require('../helpers/createTestApp')

test('test app mounts an injected router', async () => {
  const router = express.Router()
  router.get('/health', (req, res) => res.json({ ok: true }))
  const response = await request(createTestApp({ path: '/api/mobile', router })).get('/api/mobile/health')
  assert.equal(response.status, 200)
  assert.deepEqual(response.body, { ok: true })
})
