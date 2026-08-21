const express = require('express')
const {
  createEmailRemindersRouter,
  registerEmailReminderSchedulers,
} = require('./emailReminders')
const {
  MOBILE_API_CONTRACT,
  createProductionMobileRouter,
} = require('./mobile')

function createApiRouter({
  authRouter = require('./auth'),
  birthdaysRouter = require('./birthdays'),
  versionRouter = require('./version'),
  scheduleEmailRouter = require('./scheduleEmail'),
  createEmailRemindersRouterFn = createEmailRemindersRouter,
  registerEmailReminderSchedulersFn = registerEmailReminderSchedulers,
  createProductionMobileRouterFn = createProductionMobileRouter,
  mobileRouter,
  pool,
  env,
  now,
  calculateNextSolarDateFn,
  verifyPassword,
  mobileLogger,
} = {}) {
  const router = express.Router()
  const emailRemindersRouter = createEmailRemindersRouterFn()
  registerEmailReminderSchedulersFn()
  const resolvedMobileRouter = mobileRouter || createProductionMobileRouterFn({
    pool,
    env,
    now,
    calculateNextSolarDateFn,
    verifyPassword,
    logger: mobileLogger,
  })

  router.use('/auth', authRouter)
  router.use('/birthdays', birthdaysRouter)
  router.use('/email-reminders', emailRemindersRouter)
  router.use('/version', versionRouter)
  router.use('/schedule-email', scheduleEmailRouter)
  router.use(MOBILE_API_CONTRACT.apiMountPath, resolvedMobileRouter)
  return router
}

module.exports = { createApiRouter }
