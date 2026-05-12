const nodemailer = require('nodemailer')

const host = process.env.SMTP_HOST
const port = Number(process.env.SMTP_PORT || 465)
const user = process.env.SMTP_USER
const pass = process.env.SMTP_PASS

if (!host || !user || !pass) {
  console.warn('[email] SMTP_HOST, SMTP_USER or SMTP_PASS is not configured')
}

module.exports = nodemailer.createTransport({
  host,
  port,
  secure: process.env.SMTP_SECURE !== 'false',
  auth: {
    user,
    pass,
  },
})
