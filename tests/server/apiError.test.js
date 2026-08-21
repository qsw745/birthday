const test = require('node:test')
const assert = require('node:assert/strict')
const express = require('express')
const request = require('supertest')
const { createApiErrorHandler } = require('../../middleware/apiError')

function createApp(logger = { error() {} }) {
  const app = express()
  app.use(express.json({ limit: '64kb' }))
  app.post('/api/boom', async () => {
    throw Object.assign(new Error('password=hunter2 token=secret payload=private'), {
      code: 'ER_PRIVATE',
      password: 'hunter2',
    })
  })
  app.post('/api/echo', (req, res) => res.json(req.body))
  app.use('/api', createApiErrorHandler({ logger }))
  return app
}

test('JSON parser entity.too.large failures use a stable 413 API response', async () => {
  const response = await request(createApp())
    .post('/api/echo')
    .set('Content-Type', 'application/json')
    .send({ value: 'x'.repeat(70 * 1024) })

  assert.equal(response.status, 413)
  assert.deepEqual(response.body, { error: 'payload_too_large' })
})

test('unhandled API failures return sanitized server_error and log only name/code', async () => {
  const logs = []
  const response = await request(createApp({ error: (...args) => logs.push(args) }))
    .post('/api/boom')
    .send({ token: 'request-secret', password: 'request-password' })

  assert.equal(response.status, 500)
  assert.deepEqual(response.body, { error: 'server_error' })
  assert.deepEqual(logs, [['api request failed', { name: 'Error', code: 'ER_PRIVATE' }]])
  assert.doesNotMatch(JSON.stringify(logs), /hunter2|secret|payload|password|token/i)
})
