const assert = require('node:assert/strict')

function requireDisposableDatabase(env) {
  if (env.MOBILE_SYNC_TEST_DB_REQUIRED !== '1') {
    throw new Error('MOBILE_SYNC_TEST_DB_REQUIRED=1 is required before mobile sync integration setup')
  }

  const database = env.MOBILE_SYNC_TEST_DB_NAME
  if (
    typeof database !== 'string'
    || !/^[A-Za-z0-9_]{1,64}$/.test(database)
    || !database.endsWith('_test')
  ) {
    throw new Error('MOBILE_SYNC_TEST_DB_NAME must be an exact MySQL database name ending in _test')
  }

  const host = env.MOBILE_SYNC_TEST_DB_HOST || '127.0.0.1'
  if (!new Set(['127.0.0.1', 'localhost', '::1']).has(host.toLowerCase())) {
    throw new Error('MOBILE_SYNC_TEST_DB_HOST must be a loopback host')
  }

  const portText = env.MOBILE_SYNC_TEST_DB_PORT || '3306'
  if (!/^\d+$/.test(portText)) {
    throw new Error('MOBILE_SYNC_TEST_DB_PORT must be an integer from 1 through 65535')
  }
  const port = Number(portText)
  if (!Number.isSafeInteger(port) || port < 1 || port > 65535) {
    throw new Error('MOBILE_SYNC_TEST_DB_PORT must be an integer from 1 through 65535')
  }

  return Object.freeze({
    database,
    host,
    port,
    user: env.MOBILE_SYNC_TEST_DB_USER || 'root',
    password: env.MOBILE_SYNC_TEST_DB_PASSWORD || '',
  })
}

// This gate intentionally runs before mysql2 or any production router is loaded.
// A missing opt-in, unsafe database name, or remote host therefore cannot reach
// CREATE/DROP, repository setup, or a route call.
const databaseConfig = requireDisposableDatabase(process.env)

const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const express = require('express')
const mysql = require('mysql2/promise')
const request = require('supertest')
const { createProductionMobileRouter, MOBILE_API_CONTRACT } = require('../../routes/mobile')
const { createMobileSyncRepository } = require('../../repositories/mobileSyncRepository')
const { calculateNextSolarDate } = require('../../utils/helpers')

const DEVICE_A_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const DEVICE_B_ID = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const BIRTHDAY_ID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
const CREATE_OPERATION_ID = '11111111-1111-4111-8111-111111111111'
const UPDATE_OPERATION_ID = '22222222-2222-4222-8222-222222222222'
const STALE_OPERATION_ID = '33333333-3333-4333-8333-333333333333'
const DELETE_OPERATION_ID = '44444444-4444-4444-8444-444444444444'
const NOW = new Date('2026-08-22T00:00:00.000Z')
const ADMIN_ENV = Object.freeze({
  AUTH_USERNAME: 'mobile-integration-admin',
  AUTH_PASSWORD_HASH: 'integration-only-password-hash',
  AUTH_LOGIN_LIMIT: '10',
})

// This is the last schema state before the production one-shot mobile migration.
// It deliberately contains no mobile fields/tables so the real migration must
// establish the complete storage contract on a new disposable database.
const PRE_MOBILE_SCHEMA_SQL = `
CREATE TABLE birthdays (
  id VARCHAR(36) NOT NULL,
  name VARCHAR(64) NOT NULL,
  lunarMonth TINYINT UNSIGNED NOT NULL,
  lunarDay TINYINT UNSIGNED NOT NULL,
  isLeapMonth TINYINT(1) NOT NULL DEFAULT 0,
  remindTime VARCHAR(8) DEFAULT NULL,
  nextSolarDate DATETIME DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_nextSolarDate (nextSolarDate),
  KEY idx_lunar (lunarMonth, lunarDay, isLeapMonth)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE webauthn_credentials (
  credential_id VARCHAR(255) NOT NULL,
  username VARCHAR(64) NOT NULL,
  public_key BLOB NOT NULL,
  counter BIGINT UNSIGNED NOT NULL DEFAULT 0,
  transports VARCHAR(255) DEFAULT NULL,
  device_name VARCHAR(100) DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at TIMESTAMP NULL DEFAULT NULL,
  PRIMARY KEY (credential_id),
  KEY idx_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE email_reminders (
  id VARCHAR(36) NOT NULL,
  birthday_id VARCHAR(36) NOT NULL,
  name VARCHAR(64) NOT NULL,
  email VARCHAR(128) NOT NULL,
  remind_time DATETIME NOT NULL,
  message TEXT NOT NULL,
  status TINYINT NOT NULL DEFAULT 0,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_birthday_id (birthday_id),
  KEY idx_status_time (status, remind_time),
  CONSTRAINT fk_email_reminders_birthdays
    FOREIGN KEY (birthday_id) REFERENCES birthdays(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
`

function quoteIdentifier(value) {
  // The earlier exact-name validation excludes quoting characters; escaping is
  // still kept here so every DDL site has an explicit identifier boundary.
  return `\`${value.replaceAll('`', '``')}\``
}

function createApplication(pool) {
  const app = express()
  app.use(express.json({ limit: MOBILE_API_CONTRACT.limits.jsonBodyLimit }))
  app.use(MOBILE_API_CONTRACT.basePath, createProductionMobileRouter({
    pool,
    env: ADMIN_ENV,
    now: () => NOW,
    calculateNextSolarDateFn: calculateNextSolarDate,
    verifyPassword: async (password, passwordHash) => (
      password === 'integration-only-password'
      && passwordHash === ADMIN_ENV.AUTH_PASSWORD_HASH
    ),
    logger: { error() {} },
  }))
  return app
}

function login(app, deviceId, deviceName) {
  return request(app)
    .post(`${MOBILE_API_CONTRACT.basePath}${MOBILE_API_CONTRACT.endpoints.login}`)
    .send({
      username: ADMIN_ENV.AUTH_USERNAME,
      password: 'integration-only-password',
      deviceId,
      deviceName,
    })
}

function authorized(app, method, endpoint, accessToken) {
  return request(app)[method](`${MOBILE_API_CONTRACT.basePath}${endpoint}`)
    .set('Authorization', `Bearer ${accessToken}`)
}

function birthdayPayload(overrides = {}) {
  return {
    id: BIRTHDAY_ID,
    name: '离线新增',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    reminderTimeMinutes: 540,
    notifyDayBefore: true,
    notifySameDay: true,
    emailEnabled: true,
    emailAddress: 'integration@example.com',
    emailMessage: '生日快乐',
    ...overrides,
  }
}

function operation({
  operationId,
  entityId = BIRTHDAY_ID,
  type = 'upsert',
  baseVersion,
  payload,
}) {
  return {
    operationId,
    entityId,
    type,
    baseVersion,
    ...(type === 'upsert' ? { payload } : {}),
  }
}

async function schemaExists(adminPool, database) {
  const [rows] = await adminPool.execute(
    'SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = ?',
    [database],
  )
  return rows.length === 1
}

async function withDisposableDatabase(t, body) {
  const databaseIdentifier = quoteIdentifier(databaseConfig.database)
  const adminPool = mysql.createPool({
    host: databaseConfig.host,
    port: databaseConfig.port,
    user: databaseConfig.user,
    password: databaseConfig.password,
    waitForConnections: true,
    connectionLimit: 1,
    queueLimit: 0,
    connectTimeout: 5_000,
  })
  let applicationPool = null
  let createdByThisRun = false

  try {
    assert.equal(
      await schemaExists(adminPool, databaseConfig.database),
      false,
      `refusing to reuse existing database ${databaseConfig.database}`,
    )
    await adminPool.query(
      `CREATE DATABASE ${databaseIdentifier} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci`,
    )
    createdByThisRun = true
    assert.equal(await schemaExists(adminPool, databaseConfig.database), true)
    t.diagnostic(`created disposable database ${databaseConfig.database}; information_schema read-back=true`)

    applicationPool = mysql.createPool({
      host: databaseConfig.host,
      port: databaseConfig.port,
      user: databaseConfig.user,
      password: databaseConfig.password,
      database: databaseConfig.database,
      waitForConnections: true,
      connectionLimit: 8,
      queueLimit: 0,
      connectTimeout: 5_000,
      timezone: '+08:00',
      multipleStatements: true,
    })
    await applicationPool.query(PRE_MOBILE_SCHEMA_SQL)
    const migration = fs.readFileSync(
      path.join(__dirname, '../../sql/migrations/20260821_mobile_sync.sql'),
      'utf8',
    )
    await applicationPool.query(migration)
    await body(applicationPool)
  } finally {
    let cleanupError = null
    try {
      if (applicationPool) await applicationPool.end()
    } catch (error) {
      cleanupError = error
    }
    try {
      if (createdByThisRun) {
        await adminPool.query(`DROP DATABASE ${databaseIdentifier}`)
        assert.equal(await schemaExists(adminPool, databaseConfig.database), false)
        t.diagnostic(`dropped disposable database ${databaseConfig.database}; information_schema read-back=false`)
      }
    } catch (error) {
      if (!cleanupError) cleanupError = error
    }
    try {
      await adminPool.end()
    } catch (error) {
      if (!cleanupError) cleanupError = error
    }
    if (cleanupError) throw cleanupError
  }
}

test('production mobile routers preserve the two-device incremental sync contract', { timeout: 60_000 }, async t => {
  const databaseIdentifier = quoteIdentifier(databaseConfig.database)
  const adminPool = mysql.createPool({
    host: databaseConfig.host,
    port: databaseConfig.port,
    user: databaseConfig.user,
    password: databaseConfig.password,
    waitForConnections: true,
    connectionLimit: 1,
    queueLimit: 0,
    connectTimeout: 5_000,
  })
  let applicationPool = null
  let createdByThisRun = false

  try {
    assert.equal(
      await schemaExists(adminPool, databaseConfig.database),
      false,
      `refusing to reuse existing database ${databaseConfig.database}`,
    )
    await adminPool.query(
      `CREATE DATABASE ${databaseIdentifier} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci`,
    )
    createdByThisRun = true
    assert.equal(await schemaExists(adminPool, databaseConfig.database), true)
    t.diagnostic(`created disposable database ${databaseConfig.database}; information_schema read-back=true`)

    applicationPool = mysql.createPool({
      host: databaseConfig.host,
      port: databaseConfig.port,
      user: databaseConfig.user,
      password: databaseConfig.password,
      database: databaseConfig.database,
      waitForConnections: true,
      connectionLimit: 4,
      queueLimit: 0,
      connectTimeout: 5_000,
      timezone: '+08:00',
      multipleStatements: true,
    })
    await applicationPool.query(PRE_MOBILE_SCHEMA_SQL)
    const migration = fs.readFileSync(
      path.join(__dirname, '../../sql/migrations/20260821_mobile_sync.sql'),
      'utf8',
    )
    await applicationPool.query(migration)

    const app = createApplication(applicationPool)
    const loginA = await login(app, DEVICE_A_ID, '测试设备 A')
    assert.equal(loginA.status, 200)
    assert.equal(loginA.body.deviceId, DEVICE_A_ID)

    const createBody = {
      operations: [operation({
        operationId: CREATE_OPERATION_ID,
        baseVersion: '0',
        payload: birthdayPayload(),
      })],
    }
    const created = await authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginA.body.accessToken)
      .send(createBody)
    assert.equal(created.status, 200)
    assert.equal(created.body.results[0].status, 'applied')
    assert.equal(created.body.results[0].record.version, '1')
    assert.deepEqual(
      Object.keys(created.body.results[0].record),
      MOBILE_API_CONTRACT.dtoFields.birthday,
    )

    const replayed = await authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginA.body.accessToken)
      .send(createBody)
    assert.equal(replayed.status, 200)
    assert.deepEqual(replayed.body, created.body)

    const [replayRows] = await applicationPool.execute(
      `SELECT
         (SELECT COUNT(*) FROM birthdays WHERE id = ?) AS birthday_count,
         (SELECT COUNT(*) FROM mobile_sync_changes WHERE entity_id = ?) AS change_count,
         (SELECT COUNT(*) FROM mobile_sync_operations WHERE operation_id = ?) AS operation_count,
         (SELECT COUNT(*) FROM email_reminders WHERE birthday_id = ?) AS reminder_count`,
      [BIRTHDAY_ID, BIRTHDAY_ID, CREATE_OPERATION_ID, BIRTHDAY_ID],
    )
    assert.deepEqual({
      birthdayCount: Number(replayRows[0].birthday_count),
      changeCount: Number(replayRows[0].change_count),
      operationCount: Number(replayRows[0].operation_count),
      reminderCount: Number(replayRows[0].reminder_count),
    }, {
      birthdayCount: 1,
      changeCount: 1,
      operationCount: 1,
      reminderCount: 1,
    })

    const pulledFromZero = await authorized(
      app,
      'get',
      `${MOBILE_API_CONTRACT.endpoints.pull}?cursor=0`,
      loginA.body.accessToken,
    )
    assert.equal(pulledFromZero.status, 200)
    assert.equal(pulledFromZero.body.nextCursor, '1')
    assert.equal(pulledFromZero.body.hasMore, false)
    assert.deepEqual(pulledFromZero.body.changes, [{
      seq: '1',
      operation: 'upsert',
      record: created.body.results[0].record,
    }])

    const loginB = await login(app, DEVICE_B_ID, '测试设备 B')
    assert.equal(loginB.status, 200)
    assert.equal(loginB.body.deviceId, DEVICE_B_ID)

    const updated = await authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginB.body.accessToken)
      .send({ operations: [operation({
        operationId: UPDATE_OPERATION_ID,
        baseVersion: '1',
        payload: birthdayPayload({ name: '设备 B 更新' }),
      })] })
    assert.equal(updated.status, 200)
    assert.equal(updated.body.results[0].status, 'applied')
    assert.equal(updated.body.results[0].record.name, '设备 B 更新')
    assert.equal(updated.body.results[0].record.version, '2')

    const stale = await authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginA.body.accessToken)
      .send({ operations: [operation({
        operationId: STALE_OPERATION_ID,
        baseVersion: '1',
        payload: birthdayPayload({ name: '设备 A 过期更新' }),
      })] })
    assert.equal(stale.status, 200)
    assert.equal(stale.body.results[0].status, 'conflict')
    assert.equal(stale.body.results[0].remote.name, '设备 B 更新')
    assert.equal(stale.body.results[0].remote.version, '2')
    const [afterConflictRows] = await applicationPool.execute(
      'SELECT name, CAST(version AS CHAR) AS version FROM birthdays WHERE id = ?',
      [BIRTHDAY_ID],
    )
    assert.equal(afterConflictRows.length, 1)
    assert.equal(afterConflictRows[0].name, '设备 B 更新')
    assert.equal(afterConflictRows[0].version, '2')

    const deleted = await authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginB.body.accessToken)
      .send({ operations: [operation({
        operationId: DELETE_OPERATION_ID,
        type: 'delete',
        baseVersion: '2',
      })] })
    assert.equal(deleted.status, 200)
    assert.equal(deleted.body.results[0].status, 'applied')
    assert.equal(deleted.body.results[0].record.version, '3')
    assert.ok(deleted.body.results[0].record.deletedAt)
    assert.equal(deleted.body.results[0].record.emailEnabled, false)
    assert.equal(deleted.body.results[0].record.emailAddress, '')
    assert.equal(deleted.body.results[0].record.emailMessage, '')

    const snapshot = await authorized(app, 'get', MOBILE_API_CONTRACT.endpoints.snapshot, loginB.body.accessToken)
    assert.equal(snapshot.status, 200)
    assert.equal(snapshot.body.cursor, '3')
    assert.equal(snapshot.body.birthdays.length, 1)
    assert.deepEqual(snapshot.body.birthdays[0], deleted.body.results[0].record)
    const [reminderRows] = await applicationPool.execute(
      'SELECT COUNT(*) AS reminder_count FROM email_reminders WHERE birthday_id = ?',
      [BIRTHDAY_ID],
    )
    assert.equal(Number(reminderRows[0].reminder_count), 0)

    const lunarFixtures = require('../contracts/lunar-contract.json')
    for (const fixture of lunarFixtures) {
      const actual = calculateNextSolarDate({
        lunarMonth: fixture.month,
        lunarDay: fixture.day,
        isLeapMonth: fixture.leap,
        remindTime: '09:00',
      }, fixture.after)
      assert.equal(actual.slice(0, 10), fixture.expectedDate, fixture.name)
    }
  } finally {
    let cleanupError = null
    try {
      if (applicationPool) await applicationPool.end()
    } catch (error) {
      cleanupError = error
    }
    try {
      if (createdByThisRun) {
        // databaseIdentifier was produced only from the already validated exact
        // _test name captured before any connection or route was created.
        await adminPool.query(`DROP DATABASE ${databaseIdentifier}`)
        assert.equal(await schemaExists(adminPool, databaseConfig.database), false)
        t.diagnostic(`dropped disposable database ${databaseConfig.database}; information_schema read-back=false`)
      }
    } catch (error) {
      if (!cleanupError) cleanupError = error
    }
    try {
      await adminPool.end()
    } catch (error) {
      if (!cleanupError) cleanupError = error
    }
    if (cleanupError) throw cleanupError
  }
})

test('real InnoDB races, duplicate keys, deadlocks, and lock timeouts obey retry boundaries', { timeout: 60_000 }, async t => {
  await withDisposableDatabase(t, async applicationPool => {
    const app = createApplication(applicationPool)
    const loginA = await login(app, DEVICE_A_ID, '并发设备 A')
    const loginB = await login(app, DEVICE_B_ID, '并发设备 B')
    assert.equal(loginA.status, 200)
    assert.equal(loginB.status, 200)

    const raceEntityId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    const createBodies = [
      {
        operations: [operation({
          operationId: '55555555-5555-4555-8555-555555555555',
          entityId: raceEntityId,
          baseVersion: '0',
          payload: birthdayPayload({ id: raceEntityId, name: '并发创建 A' }),
        })],
      },
      {
        operations: [operation({
          operationId: '66666666-6666-4666-8666-666666666666',
          entityId: raceEntityId,
          baseVersion: '0',
          payload: birthdayPayload({ id: raceEntityId, name: '并发创建 B' }),
        })],
      },
    ]
    const createResponses = await Promise.all([
      authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginA.body.accessToken)
        .send(createBodies[0]),
      authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginB.body.accessToken)
        .send(createBodies[1]),
    ])
    assert.deepEqual(createResponses.map(response => response.status), [200, 200])
    assert.deepEqual(
      createResponses.map(response => response.body.results[0].status).sort(),
      ['applied', 'conflict'],
    )

    const updateBodies = [
      {
        operations: [operation({
          operationId: '77777777-7777-4777-8777-777777777777',
          entityId: raceEntityId,
          baseVersion: '1',
          payload: birthdayPayload({ id: raceEntityId, name: '并发更新 A' }),
        })],
      },
      {
        operations: [operation({
          operationId: '88888888-8888-4888-8888-888888888888',
          entityId: raceEntityId,
          baseVersion: '1',
          payload: birthdayPayload({ id: raceEntityId, name: '并发更新 B' }),
        })],
      },
    ]
    const updateResponses = await Promise.all([
      authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginA.body.accessToken)
        .send(updateBodies[0]),
      authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginB.body.accessToken)
        .send(updateBodies[1]),
    ])
    assert.deepEqual(updateResponses.map(response => response.status), [200, 200])
    assert.deepEqual(
      updateResponses.map(response => response.body.results[0].status).sort(),
      ['applied', 'conflict'],
    )
    const [updatedRows] = await applicationPool.execute(
      'SELECT COUNT(*) AS row_count, CAST(MAX(version) AS CHAR) AS version FROM birthdays WHERE id = ?',
      [raceEntityId],
    )
    assert.equal(Number(updatedRows[0].row_count), 1)
    assert.equal(updatedRows[0].version, '2')

    const replayEntityId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
    const replayOperationId = '99999999-9999-4999-8999-999999999999'
    const replayBody = {
      operations: [operation({
        operationId: replayOperationId,
        entityId: replayEntityId,
        baseVersion: '0',
        payload: birthdayPayload({ id: replayEntityId, name: '并发重放' }),
      })],
    }
    const replayResponses = await Promise.all([
      authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginA.body.accessToken)
        .send(replayBody),
      authorized(app, 'post', MOBILE_API_CONTRACT.endpoints.push, loginA.body.accessToken)
        .send(replayBody),
    ])
    assert.deepEqual(replayResponses.map(response => response.status), [200, 200])
    assert.deepEqual(replayResponses[0].body, replayResponses[1].body)
    const [replayCounts] = await applicationPool.execute(
      `SELECT
        (SELECT COUNT(*) FROM birthdays WHERE id = ?) AS birthday_count,
        (SELECT COUNT(*) FROM mobile_sync_operations WHERE operation_id = ?) AS operation_count`,
      [replayEntityId, replayOperationId],
    )
    assert.equal(Number(replayCounts[0].birthday_count), 1)
    assert.equal(Number(replayCounts[0].operation_count), 1)

    await applicationPool.query(`CREATE TABLE retry_unique_probe (
      id INT NOT NULL AUTO_INCREMENT,
      marker VARCHAR(32) NOT NULL,
      PRIMARY KEY (id),
      UNIQUE KEY uk_retry_unique_marker (marker)
    ) ENGINE=InnoDB`)
    await applicationPool.query(`CREATE TABLE retry_lock_probe (
      id INT NOT NULL,
      PRIMARY KEY (id)
    ) ENGINE=InnoDB`)
    await applicationPool.query(
      "INSERT INTO retry_unique_probe (marker) VALUES ('duplicate')",
    )
    await applicationPool.query(
      'INSERT INTO retry_lock_probe (id) VALUES (1), (2), (3), (4)',
    )

    const probeOperation = operation({
      operationId: 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
      entityId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
      baseVersion: '0',
      payload: birthdayPayload({
        id: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
        name: '事务探针',
      }),
    })
    let uniqueAttempts = 0
    const uniqueRepository = createMobileSyncRepository({
      pool: applicationPool,
      applyMobileOperationFn: async connection => {
        uniqueAttempts += 1
        await connection.query(
          "INSERT INTO retry_unique_probe (marker) VALUES ('duplicate')",
        )
      },
    })
    await assert.rejects(
      uniqueRepository.applyOperation(DEVICE_A_ID, probeOperation),
      error => error.code === 'ER_DUP_ENTRY',
    )
    assert.equal(uniqueAttempts, 1)

    let timeoutBlocker = await applicationPool.getConnection()
    await timeoutBlocker.beginTransaction()
    await timeoutBlocker.query('SELECT id FROM retry_lock_probe WHERE id = 3 FOR UPDATE')
    let timeoutAttempts = 0
    let timeoutAcquisitions = 0
    const timeoutRepository = createMobileSyncRepository({
      pool: {
        async getConnection() {
          timeoutAcquisitions += 1
          return applicationPool.getConnection()
        },
      },
      applyMobileOperationFn: async connection => {
        timeoutAttempts += 1
        await connection.query('SET SESSION innodb_lock_wait_timeout = 1')
        try {
          await connection.query('SELECT id FROM retry_lock_probe WHERE id = 3 FOR UPDATE')
        } catch (error) {
          if (error.code === 'ER_LOCK_WAIT_TIMEOUT' && timeoutBlocker) {
            await timeoutBlocker.rollback()
            timeoutBlocker.release()
            timeoutBlocker = null
          }
          throw error
        }
        return { status: 'lock-timeout-recovered' }
      },
    })
    try {
      assert.deepEqual(
        await timeoutRepository.applyOperation(DEVICE_A_ID, probeOperation),
        { status: 'lock-timeout-recovered' },
      )
    } finally {
      if (timeoutBlocker) {
        await timeoutBlocker.rollback()
        timeoutBlocker.release()
        timeoutBlocker = null
      }
    }
    assert.equal(timeoutAttempts, 2)
    assert.equal(timeoutAcquisitions, 2)

    let deadlockArrivals = 0
    let releaseDeadlockBarrier
    const deadlockBarrier = new Promise(resolve => { releaseDeadlockBarrier = resolve })
    const deadlockAttempts = new Map()
    let deadlockAcquisitions = 0
    const deadlockRepository = createMobileSyncRepository({
      pool: {
        async getConnection() {
          deadlockAcquisitions += 1
          return applicationPool.getConnection()
        },
      },
      applyMobileOperationFn: async (connection, { operation: current }) => {
        const attempt = (deadlockAttempts.get(current.entityId) || 0) + 1
        deadlockAttempts.set(current.entityId, attempt)
        if (attempt > 1) return { status: 'deadlock-retried' }

        const isFirst = current.entityId === raceEntityId
        const firstLock = isFirst ? 1 : 2
        const secondLock = isFirst ? 2 : 1
        await connection.query(
          'SELECT id FROM retry_lock_probe WHERE id = ? FOR UPDATE',
          [firstLock],
        )
        deadlockArrivals += 1
        if (deadlockArrivals === 2) releaseDeadlockBarrier()
        await deadlockBarrier
        await connection.query(
          'SELECT id FROM retry_lock_probe WHERE id = ? FOR UPDATE',
          [secondLock],
        )
        return { status: 'deadlock-survived' }
      },
    })
    const deadlockOperations = [
      operation({
        operationId: 'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb',
        entityId: raceEntityId,
        baseVersion: '2',
        payload: birthdayPayload({ id: raceEntityId, name: '死锁 A' }),
      }),
      operation({
        operationId: 'cccccccc-1111-4111-8111-cccccccccccc',
        entityId: replayEntityId,
        baseVersion: '1',
        payload: birthdayPayload({ id: replayEntityId, name: '死锁 B' }),
      }),
    ]
    await Promise.all(deadlockOperations.map(current => (
      deadlockRepository.applyOperation(DEVICE_A_ID, current)
    )))
    assert.deepEqual([...deadlockAttempts.values()].sort(), [1, 2])
    assert.equal(deadlockAcquisitions, 3)

    const exhaustedBlocker = await applicationPool.getConnection()
    await exhaustedBlocker.beginTransaction()
    await exhaustedBlocker.query('SELECT id FROM retry_lock_probe WHERE id = 4 FOR UPDATE')
    let exhaustedAttempts = 0
    let exhaustedAcquisitions = 0
    const exhaustedRepository = createMobileSyncRepository({
      pool: {
        async getConnection() {
          exhaustedAcquisitions += 1
          return applicationPool.getConnection()
        },
      },
      applyMobileOperationFn: async connection => {
        exhaustedAttempts += 1
        await connection.query('SET SESSION innodb_lock_wait_timeout = 1')
        await connection.query('SELECT id FROM retry_lock_probe WHERE id = 4 FOR UPDATE')
      },
    })
    try {
      await assert.rejects(
        exhaustedRepository.applyOperation(DEVICE_A_ID, probeOperation),
        error => error.code === 'ER_LOCK_WAIT_TIMEOUT',
      )
    } finally {
      await exhaustedBlocker.rollback()
      exhaustedBlocker.release()
    }
    assert.equal(exhaustedAttempts, 3)
    assert.equal(exhaustedAcquisitions, 3)
  })
})
