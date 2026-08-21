# Mobile Sync Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为现有 Node.js/MySQL 服务增加单管理员移动设备认证、首次快照、幂等上传、增量拉取、软删除和冲突检测，同时保持网页与邮件提醒行为可用。

**Architecture:** 新增依赖注入式 mobile routers、会话仓库和同步仓库；业务写入在 MySQL 事务中更新生日、邮件提醒、版本和全局变更日志。现有网页路由改用同一服务层，确保任何入口产生的变更都能被移动端增量拉取。

**Tech Stack:** Node.js 25、Express 5、MySQL 8、`node:test`、Supertest、现有 `mysql2/promise`、`lunar-javascript`、`moment-timezone`

**Spec:** `docs/superpowers/specs/2026-08-21-ios-local-first-birthday-app-design.md`

## Global Constraints

- 继续使用单管理员 `AUTH_USERNAME` 和 `AUTH_PASSWORD_HASH`；不增加公开注册或多租户。
- 执行前使用 `superpowers:using-git-worktrees` 从当前 `main` 创建隔离工作树，避免触碰主工作区的未提交修改。
- 当前主工作区的 `package.json`、`package-lock.json` 和 `routes/auth.js` 有用户未提交修改。Task 1 会接触前两者，执行前必须让用户选择“先提交这些修改”或“授权将其补丁带入隔离工作树”；不得静默丢弃、覆盖或顺带提交。
- 移动端令牌必须是不透明随机值；服务端只保存 SHA-256 哈希，日志不得输出令牌。
- 访问令牌有效 15 分钟；刷新令牌 180 天滚动有效，每次刷新都旋转。
- 推送请求每批最多 50 个操作；每个 `operationId` 必须幂等。
- `baseVersion` 不匹配时返回冲突，不覆盖数据库。
- 删除生日使用 `deleted_at` 墓碑，并停止对应邮件提醒。
- 普通月、闰月存在、闰月缺失和跨年必须与 iOS 使用同一组契约样例。
- `docs/mobile-sync-api.md` 使用平台中立字段和 JSON 样例；未来 Android/Jetpack Compose 客户端复用同一 UUID、版本、游标、墓碑、幂等操作和冲突语义，不引入 iOS 专属字段。
- 所有新增 API 位于 `/api/mobile/*`，现有 `/api/auth`、`/api/birthdays` 和网页路径保持兼容。
- 生产部署必须遵守项目 `AGENTS.md`：先检查、备份，仅重启 `email-node`，只有 Nginx 变更时才验证并重载 Nginx。
- 未获得生产切换确认前，只完成本地测试、迁移脚本和部署清单，不执行线上写入。
- 保留用户当前未提交的 `.DS_Store`、依赖文件和 `routes/auth.js` 修改；依赖文件若必须修改，只提交本计划明确新增的测试依赖差异。

---

## File Structure

- `tests/helpers/createTestApp.js`：挂载注入式 router 的测试 Express 应用。
- `tests/helpers/fakeConnection.js`：记录 SQL 和返回预设结果的连接替身。
- `tests/contracts/lunar-contract.json`：iOS 与服务器共用的农历期望样例。
- `sql/migrations/20260821_mobile_sync.sql`：版本、通知开关、墓碑和移动同步表。
- `utils/mobileTokens.js`：随机令牌、哈希和时间计算。
- `utils/mobileSyncContract.js`：请求验证、时间转换和 DTO 序列化。
- `middleware/mobileAuth.js`：Bearer 访问令牌认证。
- `repositories/mobileSessionRepository.js`：设备会话创建、查找、旋转和撤销。
- `repositories/mobileSyncRepository.js`：快照、游标、幂等操作和冲突事务。
- `services/birthdayMutationService.js`：网页与移动端共用的生日/邮件/变更日志写入。
- `routes/mobileAuth.js`：登录、刷新、撤销和设备列表。
- `routes/mobileSync.js`：快照、push 和 pull。
- `routes/mobile.js`：mobile router 聚合。
- `routes/index.js`：挂载 `/mobile`。
- `routes/birthdays.js`：改用共享 mutation service 和软删除。
- `jobs/updateBirthdays.js`：过滤墓碑并修正闰月转换。
- `utils/helpers.js`：修正 `lunar-javascript` 的闰月调用规则。
- `docs/mobile-sync-api.md`：固定请求响应契约和错误码。

---

### Task 1: Establish the Node Test Harness

**Files:**
- Modify: `package.json`
- Modify: `package-lock.json`
- Create: `tests/helpers/createTestApp.js`
- Create: `tests/smoke/mobileRoutes.test.js`

**Interfaces:**
- Consumes: Express routers created by factory functions
- Produces: `npm test`; `createTestApp({ path, router })`

- [ ] **Step 1: Add a failing route-factory smoke test**

```js
// tests/smoke/mobileRoutes.test.js
const test = require('node:test')
const assert = require('node:assert/strict')
const express = require('express')
const request = require('supertest')
const { createTestApp } = require('../helpers/createTestApp')

test('test app mounts an injected router', async () => {
  const router = express.Router()
  router.get('/health', (req, res) => res.json({ ok: true }))
  const response = await request(createTestApp({ path: '/api/mobile', router })).get('/api/mobile/health')
  assert.equal(response.status, 200)
  assert.deepEqual(response.body, { ok: true })
})
```

- [ ] **Step 2: Add the test script and dependency**

Set these exact package fields while preserving current dependencies:

```json
{
  "scripts": {
    "test": "node --test",
    "test:mobile": "node --test tests/mobile/*.test.js tests/contracts/*.test.js"
  },
  "devDependencies": {
    "supertest": "^7.1.4"
  }
}
```

Run: `npm install --package-lock-only`

Expected: only `package.json` and `package-lock.json` dependency metadata change; do not overwrite the user's pre-existing `multer` or `nodemailer` upgrades.

- [ ] **Step 3: Run and verify the helper is missing**

Run: `npm test`

Expected: FAIL with module-not-found for `tests/helpers/createTestApp`.

- [ ] **Step 4: Implement the test app helper**

```js
// tests/helpers/createTestApp.js
const express = require('express')

function createTestApp({ path, router }) {
  const app = express()
  app.use(express.json())
  app.use(path, router)
  return app
}

module.exports = { createTestApp }
```

- [ ] **Step 5: Run tests**

Run: `npm test`

Expected: smoke test PASS.

- [ ] **Step 6: Commit only the intended dependency delta**

```bash
git add package.json package-lock.json tests/helpers/createTestApp.js tests/smoke/mobileRoutes.test.js
git commit -m "test(server): 建立移动同步接口测试框架"
```

---

### Task 2: Add the Mobile Sync Schema Migration

**Files:**
- Create: `sql/migrations/20260821_mobile_sync.sql`
- Create: `tests/contracts/mobileSchema.test.js`
- Modify: `sql/tables.sql`

**Interfaces:**
- Consumes: existing `birthdays` and `email_reminders`
- Produces: columns `version`, `deleted_at`, `notify_day_before`, `notify_same_day`; tables `mobile_sync_changes`, `mobile_sync_operations`, `mobile_device_sessions`

- [ ] **Step 1: Write a failing schema contract test**

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

test('mobile migration contains every required durable field', () => {
  const sql = fs.readFileSync(path.join(__dirname, '../../sql/migrations/20260821_mobile_sync.sql'), 'utf8')
  for (const token of ['version', 'deleted_at', 'notify_day_before', 'notify_same_day', 'mobile_sync_changes', 'mobile_sync_operations', 'mobile_device_sessions']) {
    assert.match(sql, new RegExp(`\\b${token}\\b`, 'i'), token)
  }
  assert.match(sql, /UNIQUE KEY uk_mobile_operation_id \(operation_id\)/)
  assert.match(sql, /AUTO_INCREMENT/)
})
```

- [ ] **Step 2: Run and verify the migration is absent**

Run: `node --test tests/contracts/mobileSchema.test.js`

Expected: FAIL with `ENOENT`.

- [ ] **Step 3: Create the one-shot migration and idempotent clean-install schema**

```sql
ALTER TABLE birthdays
  ADD COLUMN version BIGINT UNSIGNED NOT NULL DEFAULT 1,
  ADD COLUMN deleted_at DATETIME NULL,
  ADD COLUMN notify_day_before TINYINT(1) NOT NULL DEFAULT 1,
  ADD COLUMN notify_same_day TINYINT(1) NOT NULL DEFAULT 1,
  ADD KEY idx_birthdays_deleted_at (deleted_at);

CREATE TABLE IF NOT EXISTS mobile_sync_changes (
  seq BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  entity_type VARCHAR(32) NOT NULL,
  entity_id VARCHAR(36) NOT NULL,
  operation ENUM('upsert','delete') NOT NULL,
  version BIGINT UNSIGNED NOT NULL,
  changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (seq),
  KEY idx_mobile_changes_entity (entity_type, entity_id, seq)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS mobile_sync_operations (
  operation_id VARCHAR(36) NOT NULL,
  device_id VARCHAR(36) NOT NULL,
  response_json JSON NOT NULL,
  processed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_mobile_operation_id (operation_id),
  KEY idx_mobile_operations_device (device_id, processed_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS mobile_device_sessions (
  device_id VARCHAR(36) NOT NULL,
  username VARCHAR(64) NOT NULL,
  device_name VARCHAR(100) NOT NULL,
  access_token_hash CHAR(64) NOT NULL,
  refresh_token_hash CHAR(64) NOT NULL,
  access_expires_at DATETIME NOT NULL,
  refresh_expires_at DATETIME NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at TIMESTAMP NULL DEFAULT NULL,
  revoked_at TIMESTAMP NULL DEFAULT NULL,
  PRIMARY KEY (device_id),
  UNIQUE KEY uk_mobile_access_hash (access_token_hash),
  UNIQUE KEY uk_mobile_refresh_hash (refresh_token_hash),
  KEY idx_mobile_sessions_username (username, revoked_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

This migration is intentionally one-shot: the deployment verifier must confirm the four columns are absent before execution and present afterward. Mirror the same final-state columns and table definitions in `sql/tables.sql` for clean installs.

- [ ] **Step 4: Run schema contract and static checks**

Run: `node --test tests/contracts/mobileSchema.test.js`

Expected: PASS.

Run: `git diff --check -- sql/tables.sql sql/migrations/20260821_mobile_sync.sql tests/contracts/mobileSchema.test.js`

Expected: no whitespace errors.

- [ ] **Step 5: Commit**

```bash
git add sql/tables.sql sql/migrations/20260821_mobile_sync.sql tests/contracts/mobileSchema.test.js
git commit -m "feat(server): 增加移动同步数据表"
```

---

### Task 3: Correct Lunar Conversion and Lock the Cross-Platform Contract

**Files:**
- Create: `tests/contracts/lunar-contract.json`
- Create: `tests/contracts/lunarContract.test.js`
- Modify: `utils/helpers.js`

**Interfaces:**
- Consumes: `{ lunarMonth, lunarDay, isLeapMonth, remindTime, now? }`
- Produces: `calculateNextSolarDate(item, nowInput)` with deterministic test clock and correct leap fallback

- [ ] **Step 1: Add exact shared contract fixtures**

```json
[
  { "name": "ordinary-new-year", "after": "2026-01-01T00:00:00+08:00", "month": 1, "day": 1, "leap": false, "expectedDate": "2026-02-17" },
  { "name": "ordinary-mid-autumn", "after": "2026-01-01T00:00:00+08:00", "month": 8, "day": 15, "leap": false, "expectedDate": "2026-09-25" },
  { "name": "leap-six-present", "after": "2025-01-01T00:00:00+08:00", "month": 6, "day": 1, "leap": true, "expectedDate": "2025-07-25" },
  { "name": "leap-six-missing-falls-back", "after": "2026-01-01T00:00:00+08:00", "month": 6, "day": 1, "leap": true, "expectedDate": "2026-07-14" }
]
```

- [ ] **Step 2: Write the failing contract test**

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const fixtures = require('./lunar-contract.json')
const { calculateNextSolarDate } = require('../../utils/helpers')

for (const item of fixtures) {
  test(`lunar contract: ${item.name}`, () => {
    const actual = calculateNextSolarDate({ lunarMonth: item.month, lunarDay: item.day, isLeapMonth: item.leap, remindTime: '09:00' }, item.after)
    assert.equal(actual.slice(0, 10), item.expectedDate)
  })
}
```

- [ ] **Step 3: Run and observe the leap case fail**

Run: `node --test tests/contracts/lunarContract.test.js`

Expected: ordinary cases pass; `leap-six-present` fails because the current fourth boolean argument is ignored.

- [ ] **Step 4: Implement correct negative-month leap selection and fallback**

```js
function lunarToSolar(lunarYear, month, day, isLeapMonth) {
  if (isLeapMonth) {
    try {
      return Lunar.fromYmd(lunarYear, -month, day).getSolar()
    } catch {
      return Lunar.fromYmd(lunarYear, month, day).getSolar()
    }
  }
  return Lunar.fromYmd(lunarYear, month, day).getSolar()
}

function calculateNextSolarDate(item, nowInput = new Date()) {
  const now = moment.tz(nowInput, TZ)
  const lunarMonth = Number(item.lunarMonth)
  const lunarDay = Number(item.lunarDay)
  const isLeap = !!item.isLeapMonth
  const { h, m, s } = parseTimeOfDay(item.remindTime)
  if (!lunarMonth || !lunarDay) throw new Error('缺少 lunarMonth / lunarDay')
  let lunarYear = Lunar.fromDate(now.toDate()).getYear()
  let solar = lunarToSolar(lunarYear, lunarMonth, lunarDay, isLeap)
  let candidate = toShanghaiCandidate(solar.toYmd(), h, m, s)
  if (!candidate.isValid() || candidate.isSameOrBefore(now)) {
    lunarYear += 1
    solar = lunarToSolar(lunarYear, lunarMonth, lunarDay, isLeap)
    candidate = toShanghaiCandidate(solar.toYmd(), h, m, s)
  }
  if (!candidate.isValid()) throw new Error('无法计算下一次阳历提醒日期')
  return candidate.format(STORAGE_FMT)
}
```

Extract `toShanghaiCandidate(ymd,h,m,s)` from the current duplicate `moment.tz` blocks. Export only `calculateNextSolarDate`; keep `lunarToSolar` private.

- [ ] **Step 5: Run contract and existing syntax checks**

Run: `node --test tests/contracts/lunarContract.test.js`

Expected: 4 contract cases PASS.

Run: `node --check utils/helpers.js`

Expected: no syntax errors.

- [ ] **Step 6: Commit**

```bash
git add utils/helpers.js tests/contracts/lunar-contract.json tests/contracts/lunarContract.test.js
git commit -m "fix(server): 正确换算闰月生日"
```

---

### Task 4: Implement Opaque Mobile Device Tokens

**Files:**
- Create: `utils/mobileTokens.js`
- Create: `repositories/mobileSessionRepository.js`
- Create: `middleware/mobileAuth.js`
- Create: `tests/mobile/mobileTokens.test.js`
- Create: `tests/mobile/mobileAuthMiddleware.test.js`

**Interfaces:**
- Consumes: `crypto.randomBytes`, repository query function
- Produces: `issueTokenPair(now)`, `hashToken(token)`, `createMobileAuth({ sessions })`

- [ ] **Step 1: Write failing token tests**

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const { hashToken, issueTokenPair } = require('../../utils/mobileTokens')

test('token pair uses opaque values and exact lifetimes', () => {
  const now = new Date('2026-08-21T00:00:00Z')
  const pair = issueTokenPair(now)
  assert.notEqual(pair.accessToken, pair.refreshToken)
  assert.equal(pair.accessExpiresAt.toISOString(), '2026-08-21T00:15:00.000Z')
  assert.equal(pair.refreshExpiresAt.toISOString(), '2027-02-17T00:00:00.000Z')
  assert.match(hashToken(pair.accessToken), /^[a-f0-9]{64}$/)
})
```

- [ ] **Step 2: Implement token generation**

```js
const crypto = require('node:crypto')

const ACCESS_TTL_MS = 15 * 60 * 1000
const REFRESH_TTL_MS = 180 * 24 * 60 * 60 * 1000
const randomToken = () => crypto.randomBytes(32).toString('base64url')
const hashToken = token => crypto.createHash('sha256').update(String(token)).digest('hex')

function issueTokenPair(now = new Date()) {
  return {
    accessToken: randomToken(),
    refreshToken: randomToken(),
    accessExpiresAt: new Date(now.getTime() + ACCESS_TTL_MS),
    refreshExpiresAt: new Date(now.getTime() + REFRESH_TTL_MS),
  }
}

module.exports = { ACCESS_TTL_MS, REFRESH_TTL_MS, hashToken, issueTokenPair }
```

- [ ] **Step 3: Implement the session repository**

`mobileSessionRepository` accepts `{ pool }` and exports:

```js
createSession({ deviceId, username, deviceName, pair })
findByAccessToken(accessToken, now)
rotateByRefreshToken(refreshToken, nextPair, now)
revoke(deviceId, username)
list(username)
```

Each lookup hashes the presented token before SQL. `rotateByRefreshToken` updates both hashes and both expirations only when `revoked_at IS NULL` and `refresh_expires_at > ?`; it returns `null` otherwise.

- [ ] **Step 4: Write and implement the Bearer middleware contract**

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const { createMobileAuth } = require('../../middleware/mobileAuth')

test('mobile auth rejects missing bearer token', async () => {
  const middleware = createMobileAuth({ sessions: { findByAccessToken: async () => null } })
  const req = { headers: {} }
  const res = { statusCode: 200, body: null, status(code) { this.statusCode = code; return this }, json(body) { this.body = body } }
  await middleware(req, res, () => assert.fail('next must not run'))
  assert.equal(res.statusCode, 401)
  assert.deepEqual(res.body, { error: 'mobile_auth_required' })
})
```

```js
function createMobileAuth({ sessions, now = () => new Date() }) {
  return async function mobileAuth(req, res, next) {
    const match = String(req.headers.authorization || '').match(/^Bearer (.+)$/)
    if (!match) return res.status(401).json({ error: 'mobile_auth_required' })
    const session = await sessions.findByAccessToken(match[1], now())
    if (!session) return res.status(401).json({ error: 'mobile_access_expired' })
    req.mobileSession = session
    next()
  }
}

module.exports = { createMobileAuth }
```

- [ ] **Step 5: Run tests**

Run: `node --test tests/mobile/mobileTokens.test.js tests/mobile/mobileAuthMiddleware.test.js`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add utils/mobileTokens.js repositories/mobileSessionRepository.js middleware/mobileAuth.js tests/mobile/mobileTokens.test.js tests/mobile/mobileAuthMiddleware.test.js
git commit -m "feat(server): 增加移动设备令牌认证"
```

---

### Task 5: Add Login, Refresh, Revoke, and Device Routes

**Files:**
- Create: `routes/mobileAuth.js`
- Create: `tests/mobile/mobileAuthRoutes.test.js`

**Interfaces:**
- Consumes: `verifyPassword`, `mobileSessionRepository`, `issueTokenPair`
- Produces: `createMobileAuthRouter({ sessions, verifyPassword, env, now })`

- [ ] **Step 1: Write failing login and refresh route tests**

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const request = require('supertest')
const { createTestApp } = require('../helpers/createTestApp')
const { createMobileAuthRouter } = require('../../routes/mobileAuth')

test('login binds one device and returns token pair', async () => {
  const sessions = { createSession: async input => input }
  const router = createMobileAuthRouter({ sessions, verifyPassword: async () => true, env: { AUTH_USERNAME: 'admin', AUTH_PASSWORD_HASH: 'hash' }, now: () => new Date('2026-08-21T00:00:00Z') })
  const response = await request(createTestApp({ path: '/api/mobile/auth', router })).post('/api/mobile/auth/login').send({ username: 'admin', password: 'secret', deviceId: '11111111-1111-4111-8111-111111111111', deviceName: 'iPhone' })
  assert.equal(response.status, 200)
  assert.equal(response.body.deviceId, '11111111-1111-4111-8111-111111111111')
  assert.ok(response.body.accessToken)
  assert.ok(response.body.refreshToken)
})

test('refresh rejects an unknown refresh token', async () => {
  const sessions = { rotateByRefreshToken: async () => null }
  const router = createMobileAuthRouter({ sessions, verifyPassword: async () => false, env: {}, now: () => new Date() })
  const response = await request(createTestApp({ path: '/api/mobile/auth', router })).post('/api/mobile/auth/refresh').send({ refreshToken: 'bad' })
  assert.equal(response.status, 401)
  assert.equal(response.body.error, 'mobile_refresh_invalid')
})
```

- [ ] **Step 2: Run and verify the router is missing**

Run: `node --test tests/mobile/mobileAuthRoutes.test.js`

Expected: module-not-found failure.

- [ ] **Step 3: Implement router validation and response shape**

`POST /login` validates username, password, UUID `deviceId`, and a 1...100 character `deviceName`; it rate-limits like the existing login route. On success it calls `issueTokenPair(now())`, stores only hashes through the repository, and returns:

```json
{
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "accessToken": "opaque",
  "accessExpiresAt": "2026-08-21T00:15:00.000Z",
  "refreshToken": "opaque",
  "refreshExpiresAt": "2027-02-17T00:00:00.000Z"
}
```

`POST /refresh` rotates both tokens. `POST /revoke` and `GET /devices` require injected mobile auth middleware; revoke may target only the current username's devices.

- [ ] **Step 4: Run route tests**

Run: `node --test tests/mobile/mobileAuthRoutes.test.js`

Expected: login, invalid login, refresh, revoke ownership, and list-device cases PASS.

- [ ] **Step 5: Commit**

```bash
git add routes/mobileAuth.js tests/mobile/mobileAuthRoutes.test.js
git commit -m "feat(server): 增加移动设备绑定接口"
```

---

### Task 6: Implement Snapshot and Pull Contracts

**Files:**
- Create: `utils/mobileSyncContract.js`
- Create: `repositories/mobileSyncRepository.js`
- Create: `routes/mobileSync.js`
- Create: `tests/mobile/mobileSnapshotPull.test.js`

**Interfaces:**
- Consumes: authenticated `req.mobileSession`, MySQL rows
- Produces: `serializeBirthdayRow(row)`, `snapshot(username)`, `pull(cursor,limit)`

- [ ] **Step 1: Write failing serializer and pull tests**

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const { serializeBirthdayRow } = require('../../utils/mobileSyncContract')

test('serializer emits stable mobile field names', () => {
  const dto = serializeBirthdayRow({ id: '11111111-1111-4111-8111-111111111111', name: '妈妈', lunarMonth: 8, lunarDay: 15, isLeapMonth: 0, remindTime: '09:00:00', nextSolarDate: '2026-09-25 09:00:00', notify_day_before: 1, notify_same_day: 1, version: 3, deleted_at: null, created_at: '2026-01-01T00:00:00.000Z', updated_at: '2026-08-01T00:00:00.000Z', userEmail: 'a@example.com', message: '妈妈生日快乐' })
  assert.equal(dto.reminderTimeMinutes, 540)
  assert.equal(dto.notifyDayBefore, true)
  assert.equal(dto.emailEnabled, true)
  assert.equal(dto.version, '3')
})
```

- [ ] **Step 2: Implement request validation and serializer**

```js
function timeToMinutes(value) {
  const match = String(value || '09:00').match(/^(\d{2}):(\d{2})/)
  return match ? Number(match[1]) * 60 + Number(match[2]) : 540
}

const moment = require('moment-timezone')
const { TZ } = require('./helpers')

function toISO(value) {
  if (!value) return null
  return value instanceof Date ? value.toISOString() : moment.tz(value, TZ).toISOString()
}

function serializeBirthdayRow(row) {
  return {
    id: row.id,
    name: row.name,
    lunarMonth: Number(row.lunarMonth),
    lunarDay: Number(row.lunarDay),
    isLeapMonth: !!row.isLeapMonth,
    reminderTimeMinutes: timeToMinutes(row.remindTime),
    notifyDayBefore: !!row.notify_day_before,
    notifySameDay: !!row.notify_same_day,
    emailEnabled: !!row.userEmail,
    emailAddress: row.userEmail || '',
    emailMessage: row.message ? String(row.message).replace(String(row.name), '') : '',
    nextSolarDate: toISO(row.nextSolarDate),
    version: String(row.version),
    createdAt: toISO(row.created_at),
    updatedAt: toISO(row.updated_at),
    deletedAt: toISO(row.deleted_at),
  }
}

module.exports = { serializeBirthdayRow, timeToMinutes }
```

- [ ] **Step 3: Implement repository snapshot and cursor pull**

`snapshot()` executes one transaction-consistent read: query the current maximum `mobile_sync_changes.seq`, then select all birthdays joined to email reminders, including tombstones, and return `{ cursor: String(maxSeq), birthdays }`.

`pull(cursor, limit=200)` validates a nonnegative integer cursor, selects changes `WHERE seq > ? ORDER BY seq ASC LIMIT ?`, fetches current joined rows for affected IDs, preserves delete tombstones, and returns:

```json
{
  "changes": [{ "seq": "41", "operation": "upsert", "record": {} }],
  "nextCursor": "41",
  "hasMore": false
}
```

Use strings for `BIGINT` cursor values to avoid JavaScript number precision loss.

- [ ] **Step 4: Implement GET routes and tests**

`createMobileSyncRouter({ syncRepository, mobileAuth })` exposes authenticated `GET /snapshot` and `GET /pull?cursor=<string>&limit=200`. Invalid cursor returns `400 { error: 'invalid_cursor' }`.

Run: `node --test tests/mobile/mobileSnapshotPull.test.js`

Expected: serializer, snapshot cursor, tombstone, pagination, and invalid cursor cases PASS.

- [ ] **Step 5: Commit**

```bash
git add utils/mobileSyncContract.js repositories/mobileSyncRepository.js routes/mobileSync.js tests/mobile/mobileSnapshotPull.test.js
git commit -m "feat(server): 增加移动快照与增量拉取"
```

---

### Task 7: Implement Idempotent Push and Conflict Results

**Files:**
- Create: `services/birthdayMutationService.js`
- Modify: `repositories/mobileSyncRepository.js`
- Modify: `routes/mobileSync.js`
- Create: `tests/helpers/fakeConnection.js`
- Create: `tests/mobile/mobilePush.test.js`

**Interfaces:**
- Consumes: `{ operationId, entityId, type, baseVersion, payload }`
- Produces: `applyMobileOperation(connection, context) -> applied|conflict`; `POST /push`

- [ ] **Step 1: Write failing conflict and idempotency tests**

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const { applyMobileOperation } = require('../../services/birthdayMutationService')
const { FakeConnection, validPayload } = require('../helpers/fakeConnection')

const BIRTHDAY_ID = '11111111-1111-4111-8111-111111111111'
const DEVICE_ID = '22222222-2222-4222-8222-222222222222'
const OPERATION_ID = '33333333-3333-4333-8333-333333333333'

test('base version mismatch returns conflict without update', async () => {
  const connection = FakeConnection.withBirthday({ id: BIRTHDAY_ID, version: 5, deleted_at: null })
  const result = await applyMobileOperation(connection, { deviceId: DEVICE_ID, operation: { operationId: OPERATION_ID, entityId: BIRTHDAY_ID, type: 'upsert', baseVersion: '4', payload: validPayload({ id: BIRTHDAY_ID }) } })
  assert.equal(result.status, 'conflict')
  assert.equal(result.remote.version, '5')
  assert.equal(connection.countSQL(/^UPDATE birthdays/), 0)
})

test('replayed operation returns stored response', async () => {
  const stored = { operationId: OPERATION_ID, status: 'applied', record: { id: BIRTHDAY_ID, version: '2' } }
  const connection = FakeConnection.withProcessedOperation(OPERATION_ID, stored)
  const result = await applyMobileOperation(connection, { deviceId: DEVICE_ID, operation: { operationId: OPERATION_ID, entityId: BIRTHDAY_ID, type: 'upsert', baseVersion: '1', payload: validPayload({ id: BIRTHDAY_ID }) } })
  assert.deepEqual(result, stored)
  assert.equal(connection.countSQL(/^UPDATE birthdays/), 0)
})
```

Create `tests/helpers/fakeConnection.js` with this deterministic SQL recorder and payload fixture:

```js
class FakeConnection {
  constructor({ birthday = null, processed = null } = {}) {
    this.birthday = birthday
    this.processed = processed
    this.queries = []
  }
  static withBirthday(birthday) { return new FakeConnection({ birthday }) }
  static withProcessedOperation(operationId, response) { return new FakeConnection({ processed: { operation_id: operationId, response_json: response } }) }
  async beginTransaction() {}
  async commit() {}
  async rollback() {}
  release() {}
  countSQL(pattern) { return this.queries.filter(entry => pattern.test(entry.sql)).length }
  async query(sql, params = []) {
    this.queries.push({ sql: sql.trim(), params })
    if (/FROM mobile_sync_operations/.test(sql)) return [[this.processed].filter(Boolean)]
    if (/FROM birthdays/.test(sql) && /FOR UPDATE/.test(sql)) return [[this.birthday].filter(Boolean)]
    if (/^SELECT/.test(sql)) return [[]]
    return [{ affectedRows: 1, insertId: 1 }]
  }
}

function validPayload(overrides = {}) {
  return {
    id: '11111111-1111-4111-8111-111111111111',
    name: '妈妈',
    lunarMonth: 8,
    lunarDay: 15,
    isLeapMonth: false,
    reminderTimeMinutes: 540,
    notifyDayBefore: true,
    notifySameDay: true,
    emailEnabled: false,
    emailAddress: '',
    emailMessage: '生日快乐',
    ...overrides,
  }
}

module.exports = { FakeConnection, validPayload }
```

- [ ] **Step 2: Implement strict payload normalization**

Add this strict normalizer to `utils/mobileSyncContract.js`:

```js
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

function invalidPayload() {
  const error = new Error('invalid birthday payload')
  error.code = 'invalid_birthday_payload'
  return error
}

function normalizeBirthdayPayload(payload) {
  const id = String(payload && payload.id || '')
  const name = String(payload && payload.name || '').trim()
  const lunarMonth = Number(payload && payload.lunarMonth)
  const lunarDay = Number(payload && payload.lunarDay)
  const minutes = Number(payload && payload.reminderTimeMinutes)
  const emailEnabled = payload && payload.emailEnabled === true
  const emailAddress = String(payload && payload.emailAddress || '').trim()
  if (!UUID_RE.test(id) || !name || name.length > 64) throw invalidPayload()
  if (!Number.isInteger(lunarMonth) || lunarMonth < 1 || lunarMonth > 12) throw invalidPayload()
  if (!Number.isInteger(lunarDay) || lunarDay < 1 || lunarDay > 30) throw invalidPayload()
  if (!Number.isInteger(minutes) || minutes < 0 || minutes >= 1440) throw invalidPayload()
  if (typeof payload.notifyDayBefore !== 'boolean' || typeof payload.notifySameDay !== 'boolean') throw invalidPayload()
  if (!payload.notifyDayBefore && !payload.notifySameDay) throw invalidPayload()
  if (emailEnabled && (!emailAddress.includes('@') || emailAddress.length > 128)) throw invalidPayload()
  const hour = String(Math.floor(minutes / 60)).padStart(2, '0')
  const minute = String(minutes % 60).padStart(2, '0')
  return { id, name, lunarMonth, lunarDay, isLeapMonth: payload.isLeapMonth === true, reminderTimeMinutes: minutes, remindTime: `${hour}:${minute}:00`, notifyDayBefore: payload.notifyDayBefore, notifySameDay: payload.notifySameDay, emailEnabled, emailAddress, emailMessage: String(payload.emailMessage || '') }
}
```

- [ ] **Step 3: Implement transactional operation application**

`applyMobileOperation` performs these exact steps on one connection:

1. Read `mobile_sync_operations` by `operation_id`; return stored JSON if present.
2. `SELECT ... FOR UPDATE` the birthday and joined reminder.
3. Compare current version with `baseVersion` (`0` only for a new UUID).
4. On mismatch, build a conflict result and store it as the idempotent response without changing the birthday.
5. On upsert, validate payload, calculate `nextSolarDate`, insert or update birthday with `version = current + 1` and `deleted_at = NULL`.
6. If `emailEnabled`, upsert one reminder; otherwise delete its reminder.
7. On delete, set `deleted_at`, increment version, and delete its reminder.
8. Insert one `mobile_sync_changes` row.
9. Insert `mobile_sync_operations.response_json`.
10. Return the applied record and new version.

The route processes at most 50 operations, one transaction per operation, so one conflict does not roll back unrelated items. Response shape:

```json
{
  "results": [
    { "operationId": "o1", "status": "applied", "record": { "id": "b1", "version": "2" } },
    { "operationId": "o2", "status": "conflict", "remote": { "id": "b2", "version": "5" } }
  ]
}
```

- [ ] **Step 4: Run push tests**

Run: `node --test tests/mobile/mobilePush.test.js`

Expected: new insert, update, email disable, soft delete, replay, conflict, invalid payload, and 51-operation rejection cases PASS.

- [ ] **Step 5: Commit**

```bash
git add services/birthdayMutationService.js repositories/mobileSyncRepository.js routes/mobileSync.js utils/mobileSyncContract.js tests/helpers/fakeConnection.js tests/mobile/mobilePush.test.js
git commit -m "feat(server): 实现幂等移动上传与冲突检测"
```

---

### Task 8: Route Existing Web Mutations Through the Versioned Service

**Files:**
- Modify: `routes/birthdays.js`
- Modify: `jobs/updateBirthdays.js`
- Modify: `services/birthdayMutationService.js`
- Create: `tests/server/webMutationSync.test.js`
- Create: `tests/server/updateBirthdaysDeletedFilter.test.js`

**Interfaces:**
- Consumes: existing web request shapes
- Produces: unchanged web JSON shape plus versioned change log; deleted records excluded from jobs/lists

- [ ] **Step 1: Write failing web-change-log tests**

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const { applyWebUpsert, applyWebDelete } = require('../../services/birthdayMutationService')
const { FakeConnection, validPayload } = require('../helpers/fakeConnection')

const BIRTHDAY_ID = '11111111-1111-4111-8111-111111111111'

test('web update increments version and appends one change', async () => {
  const connection = FakeConnection.withBirthday({ id: BIRTHDAY_ID, version: 2, deleted_at: null })
  const record = await applyWebUpsert(connection, { id: BIRTHDAY_ID, payload: validPayload({ id: BIRTHDAY_ID }) })
  assert.equal(record.version, '3')
  assert.equal(connection.countSQL(/^INSERT INTO mobile_sync_changes/), 1)
})

test('web delete writes tombstone instead of hard delete', async () => {
  const connection = FakeConnection.withBirthday({ id: BIRTHDAY_ID, version: 2, deleted_at: null })
  await applyWebDelete(connection, { id: BIRTHDAY_ID })
  assert.equal(connection.countSQL(/^DELETE FROM birthdays/), 0)
  assert.equal(connection.countSQL(/^UPDATE birthdays SET deleted_at/), 1)
})
```

- [ ] **Step 2: Add web service methods and preserve response fields**

`applyWebUpsert` and `applyWebDelete` share the same SQL helpers as mobile operations, always increment version and append one change. They do not require `baseVersion` because the current webpage has no concurrency token. Return the fields currently consumed by `public/scripts.js`, including `id`, `name`, lunar fields, `remindTime`, `nextSolarDate`, and reminder values.

- [ ] **Step 3: Replace route-local mutation SQL**

Modify `POST /api/birthdays`, `PUT /api/birthdays/:id`, and `DELETE /api/birthdays/:id` to call the service inside their existing transaction boundary. Modify `GET /list` to add `WHERE b.deleted_at IS NULL`. Keep `requireAuth`, validation messages, and JSON keys compatible.

- [ ] **Step 4: Filter jobs and email pollers**

Change `jobs/updateBirthdays.js` birthday query to:

```sql
SELECT * FROM birthdays WHERE deleted_at IS NULL
```

Change due/remount email queries in `routes/emailReminders.js` to join `birthdays b` and require `b.deleted_at IS NULL`. This prevents tombstones from sending email even if an inconsistent reminder row remains.

- [ ] **Step 5: Run route and job tests**

Run: `node --test tests/server/webMutationSync.test.js tests/server/updateBirthdaysDeletedFilter.test.js`

Expected: all cases PASS.

Run: `node --check routes/birthdays.js && node --check routes/emailReminders.js && node --check jobs/updateBirthdays.js`

Expected: no syntax errors.

- [ ] **Step 6: Commit**

```bash
git add routes/birthdays.js routes/emailReminders.js jobs/updateBirthdays.js services/birthdayMutationService.js tests/server/webMutationSync.test.js tests/server/updateBirthdaysDeletedFilter.test.js
git commit -m "refactor(server): 统一网页与移动生日写入"
```

---

### Task 9: Mount Mobile Routes and Document the API

**Files:**
- Create: `routes/mobile.js`
- Modify: `routes/index.js`
- Create: `docs/mobile-sync-api.md`
- Create: `tests/mobile/mobileMount.test.js`

**Interfaces:**
- Consumes: mobile auth and sync router factories, production repositories
- Produces: `/api/mobile/auth/*`, `/api/mobile/sync/*`

- [ ] **Step 1: Write the failing mount test**

```js
const test = require('node:test')
const assert = require('node:assert/strict')
const request = require('supertest')
const { createMobileRouter } = require('../../routes/mobile')
const { createTestApp } = require('../helpers/createTestApp')

test('mobile router exposes auth and protected sync surfaces', async () => {
  const router = createMobileRouter({ authRouter: require('express').Router().get('/health', (req, res) => res.json({ auth: true })), syncRouter: require('express').Router().get('/health', (req, res) => res.json({ sync: true })) })
  const app = createTestApp({ path: '/api/mobile', router })
  assert.equal((await request(app).get('/api/mobile/auth/health')).body.auth, true)
  assert.equal((await request(app).get('/api/mobile/sync/health')).body.sync, true)
})
```

- [ ] **Step 2: Implement aggregation and production wiring**

```js
const express = require('express')

function createMobileRouter({ authRouter, syncRouter }) {
  const router = express.Router()
  router.use('/auth', authRouter)
  router.use('/sync', syncRouter)
  return router
}

module.exports = { createMobileRouter }
```

In `routes/index.js`, construct production repositories from `pool`, create mobile middleware, create both routers, and mount `router.use('/mobile', mobileRouter)`. Do not place mobile routes behind cookie `requireAuth`.

- [ ] **Step 3: Document every request and stable error code**

`docs/mobile-sync-api.md` must contain exact schemas and examples for login, refresh, revoke, devices, snapshot, push, and pull. Document these error codes: `mobile_auth_required`, `mobile_access_expired`, `mobile_refresh_invalid`, `invalid_cursor`, `invalid_birthday_payload`, `too_many_operations`, `conflict`, and `server_error`. Cursors and versions are decimal strings in JSON.

- [ ] **Step 4: Run all server tests and syntax checks**

Run: `npm test`

Expected: all tests PASS.

Run: `node --check routes/mobile.js && node --check routes/mobileAuth.js && node --check routes/mobileSync.js && node --check routes/index.js`

Expected: no syntax errors.

- [ ] **Step 5: Commit**

```bash
git add routes/mobile.js routes/index.js docs/mobile-sync-api.md tests/mobile/mobileMount.test.js
git commit -m "feat(server): 挂载移动同步接口"
```

---

### Task 10: Verify Migration and Prepare Narrow Deployment

**Files:**
- Create: `scripts/verify_mobile_sync_schema.js`
- Create: `docs/deploy-mobile-sync.md`

**Interfaces:**
- Consumes: production-like MySQL credentials and migration SQL
- Produces: read-only schema verifier and an approval-gated deployment checklist

- [ ] **Step 1: Implement a read-only schema verifier**

```js
require('dotenv').config({ quiet: true })
const { query, pool } = require('../utils/db')

async function main() {
  const columns = await query("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'birthdays'")
  const names = new Set(columns.map(row => row.COLUMN_NAME))
  for (const required of ['version', 'deleted_at', 'notify_day_before', 'notify_same_day']) {
    if (!names.has(required)) throw new Error(`missing column: ${required}`)
  }
  const tables = await query("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN ('mobile_sync_changes','mobile_sync_operations','mobile_device_sessions')")
  if (tables.length !== 3) throw new Error(`mobile table count: ${tables.length}`)
  console.log('MOBILE_SYNC_SCHEMA=PASS')
}

main().finally(() => pool.end())
```

- [ ] **Step 2: Create the exact deployment checklist**

`docs/deploy-mobile-sync.md` must require, in order:

1. User confirmation for production cutover.
2. `docker ps`, `ss -lntp`, inspection of `/data/app/birthday-server`, and only birthday Nginx locations.
3. Backups of `/data/app/birthday-server`, `/opt/nginx/conf.d/site.conf`, and a MySQL dump of the three business tables before migration.
4. Query `information_schema` and require all four new birthday columns to be absent; stop if the migration appears partially applied.
5. Upload only reviewed birthday app files and migration.
6. Run the one-shot migration in `mysql8` using `MYSQL_PWD` environment injection specified by `AGENTS.md`.
7. Run `npm ci --omit=dev` inside `email-node` only if production dependencies changed; Supertest is dev-only and must not be installed.
8. Run `node scripts/verify_mobile_sync_schema.js`, `node --check` on modified files, and a read-only snapshot count query.
9. Restart only `email-node`.
10. Verify `/api/auth/status`, password web login, birthday list, and unauthorized mobile sync behavior.
11. Do not reload Nginx because this plan changes no Nginx config.

- [ ] **Step 3: Run complete local verification**

Run: `npm test`

Expected: all tests PASS.

Run: `git diff --check`

Expected: no whitespace errors.

Run: `git status --short`

Expected: intended server changes plus the user's unrelated pre-existing changes only.

- [ ] **Step 4: Commit**

```bash
git add scripts/verify_mobile_sync_schema.js docs/deploy-mobile-sync.md
git commit -m "docs(server): 增加移动同步部署验证"
```
