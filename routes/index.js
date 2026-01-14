const express = require('express')
const router = express.Router()

// 加载子路由
router.use('/birthdays', require('./birthdays'))
router.use('/email-reminders', require('./emailReminders'))
router.use('/version', require('./version'))

module.exports = router