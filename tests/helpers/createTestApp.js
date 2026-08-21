const express = require('express')

function createTestApp({ path, router }) {
  const app = express()
  app.use(express.json({ limit: '64kb' }))
  app.use(path, router)
  return app
}

module.exports = { createTestApp }
