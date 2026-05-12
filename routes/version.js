const express = require('express')
const router = express.Router()
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { query } = require('../utils/db') // 直接使用 query
const { generateUUID } = require('../utils/helpers')
const { requireAuth } = require('../utils/auth')
const multer = require('multer')

// 配置 multer
const upload = multer({
  dest: 'uploads/',
  limits: {
    fileSize: Number(process.env.APK_UPLOAD_MAX_BYTES || 100 * 1024 * 1024),
    files: 1,
  },
  fileFilter(req, file, cb) {
    if (!file.originalname || !file.originalname.toLowerCase().endsWith('.apk')) {
      return cb(new Error('仅允许上传 APK 文件'))
    }
    cb(null, true)
  },
}) // 文件暂存目录
const baseApkUrl = process.env.BASE_APK_URL || 'https://qisw.top'
const downloadsDir = path.join(__dirname, '../public/downloads')

function sanitizeApkFilename(filename) {
  const base = path.basename(String(filename || '')).replace(/[^a-zA-Z0-9._-]/g, '_')
  if (!base || !base.toLowerCase().endsWith('.apk')) {
    throw new Error('APK 文件名无效')
  }
  return `${Date.now()}-${base}`
}

function resolveDownloadPath(filePath) {
  const relative = String(filePath || '').replace(/^\/+/, '')
  const resolved = path.resolve(path.join(__dirname, '../public'), relative)
  const allowedRoot = path.resolve(downloadsDir)
  if (!resolved.startsWith(`${allowedRoot}${path.sep}`)) {
    throw new Error('文件路径无效')
  }
  return resolved
}

function fileMd5(filePath) {
  const hash = crypto.createHash('md5')
  hash.update(fs.readFileSync(filePath))
  return hash.digest('hex')
}

router.use('/apk-versions', requireAuth)

// ======================== APK 版本管理接口 ========================

// 获取所有版本记录 (支持包名过滤)
router.get('/apk-versions', async (req, res) => {
  const { package_name } = req.query
  let sql = 'SELECT * FROM apk_version'
  let params = []

  if (package_name) {
    sql += ' WHERE package_name = ?'
    params.push(package_name)
  }

  try {
    const results = await query(sql, params)
    res.json(results)
  } catch (error) {
    res.status(500).json({ error: '数据库查询失败', details: error.message })
  }
})

// 获取最新版本 (根据版本号排序)
router.get('/apk-versions/latest', async (req, res) => {
  const sql = `
    SELECT * FROM apk_version 
    ORDER BY version_code DESC 
    LIMIT 1
  `

  try {
    const results = await query(sql)
    if (results.length === 0) {
      return res.status(404).json({ error: '未找到该应用的版本记录' })
    }
    res.json(results[0])
  } catch (error) {
    res.status(500).json({ error: '数据库查询失败', details: error.message })
  }
})

// 上传新版本
router.post('/apk-versions', upload.single('apkFile'), async (req, res) => {
  const { version_code, version_name, package_name, release_notes, is_force_update, min_android_version } = req.body
  const apkFile = req.file

  if (!version_name) {
    return res.status(400).json({ error: '版本名称不能为空' })
  }

  if (!apkFile) {
    return res.status(400).json({ error: '请上传 APK 文件' })
  }

  try {
    // 检查版本是否存在
    const checkSql = 'SELECT id FROM apk_version WHERE package_name = ? AND version_code = ?'
    const checkResult = await query(checkSql, [package_name, version_code])

    if (checkResult.length > 0) {
      throw new Error('版本冲突: 该应用已存在相同版本号记录')
    }

    const id = generateUUID()
    fs.mkdirSync(downloadsDir, { recursive: true })
    const safeName = sanitizeApkFilename(apkFile.originalname)
    const filePath = `/downloads/${safeName}`
    const targetPath = resolveDownloadPath(filePath)

    // 移动文件到目标路径
    fs.renameSync(apkFile.path, targetPath)
    const md5Hash = fileMd5(targetPath)

    // 插入数据到数据库
    const sql = `
      INSERT INTO apk_version (
        id, version_code, version_name, package_name, 
        file_path, file_size, md5_hash, release_notes,
        is_force_update, min_android_version
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `
    const params = [
      id,
      version_code,
      version_name,
      package_name,
      filePath,
      apkFile.size,
      md5Hash,
      release_notes || null,
      is_force_update || 0,
      min_android_version || null,
    ]

    await query(sql, params)

    res.status(201).json({ id })
  } catch (error) {
    res.status(500).json({ error: '操作失败', details: error.message })
  }
})

// 更新版本信息
router.put('/apk-versions/:id', upload.single('apkFile'), async (req, res) => {
  const { id } = req.params
  const { version_code, version_name, package_name, release_notes, is_force_update, min_android_version } = req.body
  const apkFile = req.file

  if (!version_name) {
    return res.status(400).json({ error: '版本名称不能为空' })
  }

  try {
    // 只检查其他记录是否存在相同版本号
    const checkSql = 'SELECT id FROM apk_version WHERE package_name = ? AND version_code = ? AND id <> ?'
    const checkResult = await query(checkSql, [package_name, version_code, id])

    if (checkResult.length > 0) {
      throw new Error('版本冲突: 该应用已存在相同版本号记录')
    }

    let filePath = null
    let md5Hash = null

    // 如果有新文件上传，处理文件
    if (apkFile) {
      fs.mkdirSync(downloadsDir, { recursive: true })
      const safeName = sanitizeApkFilename(apkFile.originalname)
      filePath = `/downloads/${safeName}`
      const targetPath = resolveDownloadPath(filePath)
      // 移动文件
      fs.renameSync(apkFile.path, targetPath)
      md5Hash = fileMd5(targetPath)
    }

    // 更新数据库记录
    const sql = `
      UPDATE apk_version 
      SET 
        version_code = ?,
        version_name = ?,
        package_name = ?,
        file_path = COALESCE(?, file_path),
        file_size = COALESCE(?, file_size),
        md5_hash = COALESCE(?, md5_hash),
        release_notes = ?,
        is_force_update = ?,
        min_android_version = ?,
        update_time = CURRENT_TIMESTAMP
      WHERE id = ?
    `
    const params = [
      version_code,
      version_name,
      package_name,
      filePath,
      apkFile ? apkFile.size : null,
      md5Hash,
      release_notes || null,
      is_force_update || 0,
      min_android_version || null,
      id,
    ]

    await query(sql, params)

    res.status(200).json({ success: true, id })
  } catch (error) {
    res.status(500).json({ error: '操作失败', details: error.message })
  }
})

// 删除版本记录
router.delete('/apk-versions/:id', async (req, res) => {
  const { id } = req.params

  try {
    // 先查询文件路径用于删除物理文件
    const sql = 'SELECT file_path FROM apk_version WHERE id = ?'
    const results = await query(sql, [id])

    if (results.length === 0) {
      return res.status(404).json({ error: '未找到该版本记录' })
    }

    // 获取文件路径
    const filePath = results[0].file_path

    // 拼接完整路径
    const fullPath = resolveDownloadPath(filePath)

    // 删除数据库记录
    await query('DELETE FROM apk_version WHERE id = ?', [id])

    // 删除物理文件
    fs.unlink(fullPath, err => {
      if (err) {
        console.error('文件删除失败:', err)
        return res.status(500).json({ error: '文件删除失败', details: err.message })
      }
      res.json({ success: true, message: '版本记录及文件已删除' })
    })
  } catch (error) {
    res.status(500).json({ error: '操作失败', details: error.message })
  }
})

// 版本检查接口
router.get('/version', async (req, res) => {
  const { package_name } = req.query

  if (!package_name) {
    return res.status(400).json({ error: '缺少 package_name 参数' })
  }

  const sql = `
    SELECT 
      version_code AS version,
      version_name,
      release_notes AS changelog,
      CONCAT(?, file_path) AS apkUrl,
      is_force_update,
      min_android_version
    FROM apk_version 
    WHERE package_name = ? 
    ORDER BY version_code DESC 
    LIMIT 1
  `

  try {
    const results = await query(sql, [baseApkUrl, package_name])

    if (results.length === 0) {
      return res.status(404).json({ error: '未找到该应用的版本信息' })
    }

    res.json(results[0])
  } catch (error) {
    res.status(500).json({ error: '数据库查询失败', details: error.message })
  }
})

// 获取单个版本详情
router.get('/apk-versions/:id', async (req, res) => {
  const { id } = req.params

  const sql = 'SELECT * FROM apk_version WHERE id = ?'

  try {
    const results = await query(sql, [id])

    if (results.length === 0) {
      return res.status(404).json({ error: '未找到该版本记录' })
    }

    res.json(results[0])
  } catch (error) {
    res.status(500).json({ error: '数据库查询失败', details: error.message })
  }
})

module.exports = router
