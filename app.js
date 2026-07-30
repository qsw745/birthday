require('dotenv').config({ quiet: true })
process.env.TZ = process.env.TZ || 'Asia/Shanghai'

// ===== 定时任务（提前加载，便于关闭）=====
const schedule = require('node-schedule')
require('./jobs/updateBirthdays')

// ===== 基础依赖 =====
const express = require('express')
const cors = require('cors')
const helmet = require('helmet')
const rateLimit = require('express-rate-limit')
const https = require('https')
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const routes = require('./routes')
const { attachAuth, requirePageAuth } = require('./utils/auth')

// ===== 数据库（用于优雅关闭）=====
const { pool } = require('./utils/db')

const app = express()
app.set('trust proxy', Number(process.env.TRUST_PROXY_HOPS || 1))
const publicDir = path.join(__dirname, 'public')
const appBasePath = process.env.APP_BASE_PATH || '/birthday'

const allowedOrigins = new Set([
  'https://101.37.21.147:3300',
  'https://127.0.0.1:3300',
  'https://localhost:3300',
  'https://qisw.top:3300',
  'https://qisw.top',
  'https://www.qisw.top',
])

const corsOptions = {
  origin(origin, cb) {
    // curl / 同源 / 服务器内部请求：可能没有 Origin
    if (!origin) return cb(null, true)
    if (allowedOrigins.has(origin)) return cb(null, true)
    return cb(new Error(`CORS blocked: ${origin}`))
  },
  credentials: true,
}

const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: Number(process.env.API_RATE_LIMIT || 300),
  standardHeaders: true,
  legacyHeaders: false,
})

function requireSameOriginForUnsafeMethods(req, res, next) {
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next()
  const origin = req.headers.origin
  if (!origin || allowedOrigins.has(origin)) return next()
  return res.status(403).json({ error: '请求来源不允许' })
}

app.use(
  helmet({
    contentSecurityPolicy: false,
  })
)
app.use(cors(corsOptions))
app.use(express.json({ limit: process.env.JSON_BODY_LIMIT || '64kb' }))
app.use(attachAuth)
app.use('/api', apiLimiter, requireSameOriginForUnsafeMethods)

// ===== 首页资源版本戳 =====
// nginx 给 scripts.js / styles.css 加了 max-age=300，而资源 URL 没有版本号，
// 浏览器（尤其 iOS Safari）会继续用旧文件，导致前端改动上线后看不到效果。
// 这里按文件 mtime 生成版本戳注入 index.html，使每次部署自动失效旧缓存。
const indexPath = path.join(publicDir, 'index.html')
const versionedAssets = ['scripts.js', 'styles.css'].map(name => path.join(publicDir, name))
let indexCache = { version: null, html: null }

function assetVersion() {
  const stamp = versionedAssets
    .map(file => {
      try {
        return fs.statSync(file).mtimeMs
      } catch {
        return 0
      }
    })
    .join('-')
  return crypto.createHash('sha1').update(stamp).digest('hex').slice(0, 10)
}

function sendIndex(res) {
  const version = assetVersion()
  if (indexCache.version !== version) {
    indexCache = {
      version,
      html: fs.readFileSync(indexPath, 'utf8').split('__ASSET_V__').join(version),
    }
  }
  res.type('html').set('Cache-Control', 'no-cache').send(indexCache.html)
}

app.get(['/login', `${appBasePath}/login`], (req, res) => {
  if (req.session) return res.redirect(`${appBasePath}/`)
  return sendIndex(res)
})

app.get(['/', appBasePath, `${appBasePath}/`], requirePageAuth, (req, res) => {
  sendIndex(res)
})

app.get(['/index.html', `${appBasePath}/index.html`], requirePageAuth, (req, res) => {
  sendIndex(res)
})

app.use(`${appBasePath}/vendor`, express.static(path.join(publicDir, 'vendor'), { index: false }))
app.use(express.static(publicDir, { index: false }))
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
