const express = require('express')
const router = express.Router()

// 加载子路由
router.use('/auth', require('./auth'))
router.use('/birthdays', require('./birthdays'))
router.use('/email-reminders', require('./emailReminders'))
router.use('/version', require('./version'))
router.use('/schedule-email', require('./scheduleEmail'))

module.exports = router
