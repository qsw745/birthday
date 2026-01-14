require('dotenv').config()
process.env.TZ = process.env.TZ || 'Asia/Shanghai'

// ===== 定时任务（提前加载，便于关闭）=====
const schedule = require('node-schedule')
require('./jobs/updateBirthdays')

// ===== 基础依赖 =====
const express = require('express')
const cors = require('cors')
const bodyParser = require('body-parser')
const https = require('https')
const fs = require('fs')
const path = require('path')
const routes = require('./routes')

// ===== 数据库（用于优雅关闭）=====
const { pool } = require('./utils/db')

const app = express()

const allowedOrigins = new Set([
  'https://101.37.21.147:3300',
  'https://127.0.0.1:3300',
  'https://localhost:3300',
  'https://qisw.top:3300',
])

app.use(
  cors({
    origin(origin, cb) {
      // curl / 同源 / 服务器内部请求：可能没有 Origin
      if (!origin) return cb(null, true)
      if (allowedOrigins.has(origin)) return cb(null, true)
      return cb(new Error(`CORS blocked: ${origin}`))
    },
    credentials: true,
  })
)

// 让预检请求（OPTIONS）也走 CORS
app.options('*', cors())
app.use(bodyParser.json())
app.use(express.static(path.join(__dirname, 'public')))
app.use('/api', routes)

// ===== 启动 HTTPS Server（保存 server 引用）=====
const PORT = process.env.PORT || 3300

const server = https.createServer(
  {
    key: fs.readFileSync('./ssl/qisw.top.key'),
    cert: fs.readFileSync('./ssl/qisw.top.pem'),
  },
  app
)

server.listen(PORT, () => {
  console.log(`Server running on https://localhost:${PORT}`)
})

// ===== 优雅退出逻辑 =====
let isShuttingDown = false

async function shutdown(signal) {
  if (isShuttingDown) return
  isShuttingDown = true

  console.log(`[shutdown] received ${signal}, shutting down...`)

  // 1️⃣ 停止接收新请求
  server.close(() => {
    console.log('[shutdown] HTTPS server closed')
  })

  // 2️⃣ 取消所有定时任务（node-schedule）
  try {
    const jobs = schedule.scheduledJobs
    Object.keys(jobs).forEach(name => {
      jobs[name].cancel()
    })
    console.log('[shutdown] scheduled jobs cancelled')
  } catch (e) {
    console.warn('[shutdown] failed to cancel jobs', e)
  }

  // 3️⃣ 关闭 MySQL 连接池
  try {
    await pool.end()
    console.log('[shutdown] MySQL pool closed')
  } catch (e) {
    console.warn('[shutdown] MySQL pool close failed', e)
  }

  // 4️⃣ 给一点缓冲时间，再退出进程
  setTimeout(() => {
    console.log('[shutdown] exit now')
    process.exit(0)
  }, 1000)
}

// ===== 监听信号 =====
process.on('SIGTERM', () => shutdown('SIGTERM'))
process.on('SIGINT', () => shutdown('SIGINT'))

// 防止未捕获异常导致僵死
process.on('uncaughtException', err => {
  console.error('[uncaughtException]', err)
  shutdown('uncaughtException')
})

process.on('unhandledRejection', err => {
  console.error('[unhandledRejection]', err)
  shutdown('unhandledRejection')
})
