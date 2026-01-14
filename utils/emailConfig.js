const nodemailer = require('nodemailer')

module.exports = nodemailer.createTransport({
  host: 'smtp.163.com',
  port: 465,
  secure: true,
  auth: {
    user: 'qishiwei745@163.com',
    pass: 'ADKHNLBHPJIABLWV'
  }
})