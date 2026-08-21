const express = require('express')

function createTestApp({ path, router }) {
  const app = express()
  app.use(express.json())
  app.use(path, router)
  return app
}

module.exports = { createTestApp }
