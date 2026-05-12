require('dotenv').config({ quiet: true })
const mysql = require('mysql2/promise')
const moment = require('moment')

// 1️⃣ 统一从环境变量加载配置
const pool = mysql.createPool({
  host: process.env.DB_HOST,
  port: +process.env.DB_PORT || 3306,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  waitForConnections: true,
  connectionLimit: +process.env.DB_CONN_LIMIT || 10,
  queueLimit: 0,
  connectTimeout: +process.env.DB_CONNECT_TIMEOUT || 10000,
  timezone: process.env.DB_TIMEZONE || '+08:00',
})

// 2️⃣ 格式化 Date → MySQL DATETIME
const formatDate = date =>
  moment(date).format('YYYY-MM-DD HH:mm:ss')

// 3️⃣ 通用查询
async function query(sql, params = []) {
  const [rows] = await pool.query(sql, params)
  return rows
}

// 4️⃣ 事务执行
async function transaction(execs = []) {
  const conn = await pool.getConnection()
  try {
    await conn.beginTransaction()
    for (const { sql, params } of execs) {
      const [res] = await conn.query(sql, params)
      if (res.affectedRows === 0) {
        throw new Error(`事务失败: ${sql}`)
      }
    }
    await conn.commit()
    return true
  } catch (err) {
    await conn.rollback()
    throw err
  } finally {
    conn.release()
  }
}

// 5️⃣ 测试连接
async function testConnection() {
  try {
    const conn = await pool.getConnection()
    conn.release()
    console.log('✅ MySQL connection OK')
  } catch (err) {
    console.error('❌ MySQL connection failed:', err.message)
    process.exit(1)
  }
}

module.exports = {
  pool,
  query,
  transaction,
  formatDate,
  testConnection,
}
