const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const express = require('express')
const request = require('supertest')
const {
  API_JSON_BODY_LIMIT,
  createApiLimiter,
  installApiSurface,
  resolveApiJsonBodyLimit,
} = require('../../middleware/apiSurface')
const { createApiErrorHandler } = require('../../middleware/apiError')

function namedMiddleware(name, calls) {
  return (req, res, next) => {
    calls.push(name)
    next()
  }
}

test('API installer executes parser, auth, limiter, same-origin, router in production order', async () => {
  const calls = []
  const app = express()
  const apiRouter = express.Router().post('/echo', (req, res) => {
    calls.push('router')
    res.json({ body: req.body })
  })
  installApiSurface({
    app,
    env: {},
    jsonParser: (req, res, next) => {
      calls.push('parser')
      express.json({ limit: '64kb' })(req, res, next)
    },
    attachAuthMiddleware: namedMiddleware('auth', calls),
    apiLimiter: namedMiddleware('limiter', calls),
    sameOriginMiddleware: namedMiddleware('same-origin', calls),
    apiRouter,
    apiErrorHandler: createApiErrorHandler({ logger: { error() {} } }),
  })

  const response = await request(app).post('/api/echo').send({ ok: true })

  assert.equal(response.status, 200)
  assert.deepEqual(response.body, { body: { ok: true } })
  assert.deepEqual(calls, ['parser', 'auth', 'limiter', 'same-origin', 'router'])
})

test('API installer rejects non-contract JSON_BODY_LIMIT before installing middleware', () => {
  const app = express()
  const stackBefore = app.router?.stack.length || 0

  for (const value of ['63kb', '65536', '64KB', ' 64kb ', '1mb']) {
    assert.throws(
      () => installApiSurface({
        app,
        env: { JSON_BODY_LIMIT: value },
        attachAuthMiddleware: (req, res, next) => next(),
        apiLimiter: (req, res, next) => next(),
        sameOriginMiddleware: (req, res, next) => next(),
        apiRouter: express.Router(),
        apiErrorHandler: createApiErrorHandler({ logger: { error() {} } }),
      }),
      error => error.code === 'invalid_json_body_limit',
      value,
    )
  }

  assert.equal(resolveApiJsonBodyLimit({}), API_JSON_BODY_LIMIT)
  assert.equal(resolveApiJsonBodyLimit({ JSON_BODY_LIMIT: '' }), API_JSON_BODY_LIMIT)
  assert.equal(resolveApiJsonBodyLimit({ JSON_BODY_LIMIT: '64kb' }), API_JSON_BODY_LIMIT)
  assert.equal(app.router?.stack.length || 0, stackBefore)
})

test('production API limiter returns stable JSON when it is the first exhausted limiter', async () => {
  const app = express()
  app.set('trust proxy', false)
  const router = express.Router().get('/ok', (req, res) => res.json({ ok: true }))
  installApiSurface({
    app,
    env: { API_RATE_LIMIT: '1' },
    attachAuthMiddleware: (req, res, next) => next(),
    apiLimiter: createApiLimiter({ env: { API_RATE_LIMIT: '1' } }),
    sameOriginMiddleware: (req, res, next) => next(),
    apiRouter: router,
    apiErrorHandler: createApiErrorHandler({ logger: { error() {} } }),
  })

  const first = await request(app).get('/api/ok')
  const limited = await request(app).get('/api/ok')

  assert.equal(first.status, 200)
  assert.equal(limited.status, 429)
  assert.deepEqual(limited.body, { error: 'api_rate_limited' })
})

test('production API limiter accepts only strict bounded integers and otherwise uses safe defaults', async () => {
  const cases = [
    {
      name: 'valid values',
      env: { API_RATE_LIMIT: '3', API_RATE_WINDOW_MS: '60000' },
      expectedLimit: '3',
      expectedPolicy: '3;w=60',
    },
    {
      name: 'upper bounds',
      env: { API_RATE_LIMIT: '10000', API_RATE_WINDOW_MS: '2147483647' },
      expectedLimit: '10000',
      expectedPolicy: '10000;w=2147484',
    },
    ...[
      ['', ''],
      [' ', ' '],
      [' 3 ', ' 60000 '],
      ['0', '0'],
      ['-1', '-1'],
      ['1.5', '1.5'],
      ['NaN', 'NaN'],
      ['10001', '2147483648'],
      ['9007199254740992', '9007199254740992'],
    ].map(([limit, windowMs]) => ({
      name: `invalid ${JSON.stringify(limit)} / ${JSON.stringify(windowMs)}`,
      env: { API_RATE_LIMIT: limit, API_RATE_WINDOW_MS: windowMs },
      expectedLimit: '300',
      expectedPolicy: '300;w=900',
    })),
  ]

  for (const item of cases) {
    const app = express()
    app.use(createApiLimiter({ env: item.env }))
    app.get('/ok', (req, res) => res.json({ ok: true }))

    const response = await request(app).get('/ok')

    assert.equal(response.status, 200, item.name)
    assert.equal(response.headers['ratelimit-limit'], item.expectedLimit, item.name)
    assert.equal(response.headers['ratelimit-policy'], item.expectedPolicy, item.name)
  }
})

test('production API installer keeps parser failures inside the stable API error boundary', async () => {
  const downstream = []
  const app = express()
  installApiSurface({
    app,
    env: { JSON_BODY_LIMIT: '64kb' },
    attachAuthMiddleware: namedMiddleware('auth', downstream),
    apiLimiter: namedMiddleware('limiter', downstream),
    sameOriginMiddleware: namedMiddleware('same-origin', downstream),
    apiRouter: express.Router().post('/echo', (req, res) => res.json(req.body)),
    apiErrorHandler: createApiErrorHandler({ logger: { error() {} } }),
  })

  const response = await request(app)
    .post('/api/echo')
    .send({ value: 'x'.repeat(70 * 1024) })

  assert.equal(response.status, 413)
  assert.deepEqual(response.body, { error: 'payload_too_large' })
  assert.deepEqual(downstream, [])
})

test('example environment pins JSON parsing and safe API limiter defaults', () => {
  const example = fs.readFileSync(path.join(__dirname, '../../.env.example'), 'utf8')
  assert.match(example, /^JSON_BODY_LIMIT=64kb$/m)
  assert.match(example, /^API_RATE_LIMIT=300$/m)
  assert.match(example, /^API_RATE_WINDOW_MS=900000$/m)
})
