const express = require('express')
const rateLimit = require('express-rate-limit')
const router = express.Router()
const transporter = require('../utils/emailConfig')

const scheduleEmailLimiter = rateLimit({
  windowMs: 10 * 60 * 1000,
  limit: Number(process.env.SCHEDULE_EMAIL_LIMIT || 30),
  standardHeaders: true,
  legacyHeaders: false,
  message: { success: false, message: '请求过于频繁，请稍后再试' },
})

function normalizeText(value, maxLength) {
  return String(value || '').trim().replace(/\s+/g, ' ').slice(0, maxLength)
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

router.post('/', scheduleEmailLimiter, async (req, res) => {
  const sendTime = normalizeText(req.body.sendTime, 80)
  const userInfo = normalizeText(req.body.userInfo, 120)

  if (!sendTime || !userInfo) {
    return res.status(400).json({ success: false, message: '缺少必要参数' })
  }

  const from = process.env.SMTP_FROM || process.env.SMTP_USER
  const to = process.env.SCHEDULE_EMAIL_TO || process.env.SMTP_USER
  if (!from || !to) {
    return res.status(503).json({ success: false, message: '邮件服务未配置' })
  }

  const mailOptions = {
    from,
    to,
    subject: '【机房哨兵】新的机房申请通知',
    html: [
      '<h3>新的机房申请</h3>',
      `<p><b>申请人：</b>${escapeHtml(userInfo)}</p>`,
      `<p><b>进入时间：</b>${escapeHtml(sendTime)}</p>`,
      '<p>请登录管理后台查看详情。</p>',
    ].join(''),
  }

  try {
    await transporter.sendMail(mailOptions)
    console.log('[schedule-email] 申请通知邮件已发送:', userInfo, sendTime)
    res.json({ success: true, message: '邮件发送成功' })
  } catch (err) {
    console.error('[schedule-email] 发送失败:', err)
    res.status(500).json({ success: false, message: '邮件发送失败' })
  }
})

module.exports = router
