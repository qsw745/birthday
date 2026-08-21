const express = require('express')
const {
  createEmailRemindersRouter,
  registerEmailReminderSchedulers,
} = require('./emailReminders')

function createApiRouter({
  authRouter = require('./auth'),
  birthdaysRouter = require('./birthdays'),
  versionRouter = require('./version'),
  scheduleEmailRouter = require('./scheduleEmail'),
  createEmailRemindersRouterFn = createEmailRemindersRouter,
  registerEmailReminderSchedulersFn = registerEmailReminderSchedulers,
} = {}) {
  const router = express.Router()
  const emailRemindersRouter = createEmailRemindersRouterFn()
  registerEmailReminderSchedulersFn()

  router.use('/auth', authRouter)
  router.use('/birthdays', birthdaysRouter)
  router.use('/email-reminders', emailRemindersRouter)
  router.use('/version', versionRouter)
  router.use('/schedule-email', scheduleEmailRouter)
  return router
}

module.exports = { createApiRouter }
