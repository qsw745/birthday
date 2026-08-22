# 移动端离线同步 API

本文固定生日移动端首版的服务器契约。移动端以本地数据库为界面事实来源：离线修改先写本地操作队列，联网后依次 `push`，再按游标 `pull`。本文记录的是当前代码和自动化测试覆盖的行为，不代表接口已迁移到生产数据库、已部署或已通过生产环境验证。

## 通用约定

- 基础路径：`/api/mobile`。
- 请求和响应均为 JSON；有请求体时发送 `Content-Type: application/json`。
- `login`、`refresh` 不需要 Cookie 或 Bearer；`revoke`、`devices`、`snapshot`、`push`、`pull` 必须发送 `Authorization: Bearer <accessToken>`。
- 网页端 `birthday_session` Cookie 不参与移动端认证。仅有 Cookie、没有有效 Bearer 时返回 `mobile_auth_required`。
- 日期时间使用与移动端 `MobileJSON` 共同支持的严格 RFC 3339 instant：仅接受 `YYYY-MM-DDTHH:mm:ssZ`、带一位或更多小数秒的 `YYYY-MM-DDTHH:mm:ss.S...Z`，或把 `Z` 换成带冒号的 `±HH:MM` 偏移；例如 `2026-08-22T00:15:00.000Z`。可空日期使用 JSON `null`。前后空白、空格分隔日期时间、basic/week/ordinal date、无时区、`±HHMM`、小写 `z`、无效闰日及时分秒/偏移越界均不接受。
- 设备、生日、操作 ID 均为 UUID 字符串。服务端接受 UUID v1...v8 和大小写输入，并在同步操作中规范化为小写。
- 游标、变更序号、`baseVersion` 和生日 `version` 是非负 signed Int64（`0...9223372036854775807`）的规范十进制字符串，不能发送 JSON 数字，也不能带符号、空格、指数或前导零；零只能写作 `"0"`。
- 访问令牌和刷新令牌是不透明字符串，客户端不得解析。当前访问令牌有效期为 15 分钟，刷新令牌有效期为 180 天；每次刷新同时轮换两枚令牌，旧刷新令牌立即失效。
- 全局 JSON 解析契约固定为 64 KiB；`JSON_BODY_LIMIT` 只能为空或精确等于 `64kb`，否则服务器在安装 API 中间件前明确启动失败。超过上限返回 HTTP 413 和 `payload_too_large`。`push` 另要求紧凑 JSON 不超过 60 KiB，为外层 JSON 和解析器留出余量。
- 服务端必须先完成 `20260821_mobile_sync.sql` 数据库迁移和只读结构核验，才可启用这些路径。未迁移时的数据库错误只会对外表现为 `server_error`。

### 路径与认证索引

| 名称 | 方法 | 完整路径 | 认证 |
|---|---|---|---|
| `login` | `POST` | `/api/mobile/auth/login` | `none` |
| `refresh` | `POST` | `/api/mobile/auth/refresh` | `none` |
| `revoke` | `POST` | `/api/mobile/auth/revoke` | `bearer` |
| `devices` | `GET` | `/api/mobile/auth/devices` | `bearer` |
| `snapshot` | `GET` | `/api/mobile/sync/snapshot` | `bearer` |
| `push` | `POST` | `/api/mobile/sync/push` | `bearer` |
| `pull` | `GET` | `/api/mobile/sync/pull` | `bearer` |

### 机器可核验限制

| 契约字段 | 值 |
|---|---:|
| `jsonBodyLimit` | `64kb` |
| `jsonBodyBytes` | `65536` |
| `pushCompactJSONBytes` | `61440` |
| `pushOperations` | `50` |
| `pullDefault` | `200` |
| `pullMaximum` | `200` |
| `enabledEmailStorageBytes` | `8192` |
| `signedInt64Maximum` | `9223372036854775807` |
| `accessTokenTTLSeconds` | `900` |
| `refreshTokenTTLSeconds` | `15552000` |

## 生日 DTO

`snapshot`、`push` 结果和 `pull` 变更共用以下生日对象：

```json
{
  "id": "11111111-1111-4111-8111-111111111111",
  "name": "妈妈",
  "lunarMonth": 8,
  "lunarDay": 15,
  "isLeapMonth": false,
  "reminderTimeMinutes": 540,
  "notifyDayBefore": true,
  "notifySameDay": true,
  "emailEnabled": true,
  "emailAddress": "mom@example.com",
  "emailMessage": "生日快乐",
  "nextSolarDate": "2026-09-25T01:00:00.000Z",
  "version": "3",
  "createdAt": "2026-01-01T00:00:00.000Z",
  "updatedAt": "2026-08-22T04:00:00.000Z",
  "deletedAt": null
}
```

字段约束：

- 对象必须精确包含示例中的 16 个字段，不能缺字段或夹带内部字段；`id` 必须是 UUID v1...v8，`version` 必须是规范 signed Int64 十进制字符串。
- `name` 去除两端 Unicode 空白后必须非空，最多 64 个扩展字素，同时最多 64 个 Unicode 标量。
- `lunarMonth` 为 JSON 整数 1...12，`lunarDay` 为 JSON 整数 1...30；`isLeapMonth`、`notifyDayBefore`、`notifySameDay`、`emailEnabled` 必须是真正的 JSON 布尔值，不能用字符串或数字代替。
- `reminderTimeMinutes` 为 JSON 整数 0...1439；`notifyDayBefore` 与 `notifySameDay` 至少一个为 `true`。
- `emailEnabled` 为 `true` 时，`emailAddress` 去除两端 Unicode 空白后最多 128 个扩展字素和 128 个 Unicode 标量，且必须恰有一个 `@`、两侧均非空；`emailMessage` 必须是字符串，去除两端 Unicode 空白后的 `name` 与 `emailMessage` 的 UTF-8 总长度最多 8192 字节。
- `emailEnabled` 为 `false` 时，DTO 中 `emailAddress` 和 `emailMessage` 必须同时是空字符串；服务端接收写入负载时会把禁用状态下的输入内容清空。
- `nextSolarDate` 可为 `null` 或上述严格 RFC 3339 字符串；`createdAt`、`updatedAt` 必须是上述字符串；`deletedAt` 可为 `null` 或上述字符串。`deletedAt` 非空表示墓碑，快照和增量拉取都可能返回墓碑，客户端不能把它当作普通活跃记录。

## 账号与设备

### 登录

`POST /api/mobile/auth/login`

无需 Cookie。请求：

```json
{
  "username": "admin",
  "password": "用户输入的密码",
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "deviceName": "QSW 的 iPhone"
}
```

`username` 去除两端空白后不能为空；`password` 不能为空；`deviceName` 去除两端空白后长度为 1...100。成功返回 HTTP 200：

```json
{
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "accessToken": "opaque-access-token",
  "accessExpiresAt": "2026-08-22T00:15:00.000Z",
  "refreshToken": "opaque-refresh-token",
  "refreshExpiresAt": "2027-02-18T00:00:00.000Z"
}
```

原始令牌只在响应中出现；服务器只持久化令牌哈希。

同一 `username + deviceId` 可以重复登录。服务端在一个显式事务中锁定设备行并原子替换设备名、两枚令牌哈希和两项有效期，同时清空 `revokedAt` 与 `lastUsedAt`；因此响应在网络中丢失后可安全重试，已撤销的同账号设备也可重新绑定。提交后旧访问令牌与旧刷新令牌立即失效，客户端只能保存最后一次成功响应中的整组新凭据；设备的 `deviceId`、所有者和首次 `createdAt` 不变。

`deviceId` 不可跨用户名接管。即使密码验证成功，只要该设备 ID 已属于不同用户名，服务端也不会改动原行，并返回 HTTP 409 `mobile_device_ownership_conflict`；响应和安全日志均不包含原所有者、令牌哈希或数据库消息。意外的唯一令牌哈希冲突会回滚整个绑定事务，对外统一为 HTTP 500 `server_error`。

### 刷新令牌

`POST /api/mobile/auth/refresh`

无需 Bearer。请求：

```json
{
  "refreshToken": "opaque-refresh-token"
}
```

成功返回 HTTP 200，响应字段与登录的令牌响应一致，并保留当前 `deviceId`：

```json
{
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "accessToken": "new-opaque-access-token",
  "accessExpiresAt": "2026-08-22T00:30:00.000Z",
  "refreshToken": "new-opaque-refresh-token",
  "refreshExpiresAt": "2027-02-18T00:15:00.000Z"
}
```

客户端必须原子替换本地保存的整组凭据，不能继续使用旧令牌。

### 撤销设备

`POST /api/mobile/auth/revoke`

需要 Bearer。请求：

```json
{
  "deviceId": "11111111-1111-4111-8111-111111111111"
}
```

只能撤销当前认证账号拥有的设备。成功返回 HTTP 200：

```json
{
  "success": true
}
```

撤销只终止该设备的服务器同步会话，不删除设备上的本地生日数据。

### 设备列表

`GET /api/mobile/auth/devices`

需要 Bearer，无请求体。成功返回 HTTP 200：

```json
{
  "devices": [
    {
      "deviceId": "11111111-1111-4111-8111-111111111111",
      "deviceName": "QSW 的 iPhone",
      "createdAt": "2026-08-22T00:00:00.000Z",
      "lastUsedAt": null,
      "revokedAt": null
    }
  ]
}
```

当前列表只返回未撤销设备，因此 `revokedAt` 为 `null`；响应不包含访问令牌、刷新令牌或其哈希。

## 同步

### 首次快照

`GET /api/mobile/sync/snapshot`

需要 Bearer，无请求体。服务端在一次可重复读事务中先取得当前最大游标，再读取全部生日（包括墓碑）。成功返回 HTTP 200：

```json
{
  "cursor": "41",
  "birthdays": [
    {
      "id": "11111111-1111-4111-8111-111111111111",
      "name": "妈妈",
      "lunarMonth": 8,
      "lunarDay": 15,
      "isLeapMonth": false,
      "reminderTimeMinutes": 540,
      "notifyDayBefore": true,
      "notifySameDay": true,
      "emailEnabled": false,
      "emailAddress": "",
      "emailMessage": "",
      "nextSolarDate": "2026-09-25T01:00:00.000Z",
      "version": "3",
      "createdAt": "2026-01-01T00:00:00.000Z",
      "updatedAt": "2026-08-22T04:00:00.000Z",
      "deletedAt": null
    }
  ]
}
```

客户端首次导入必须先完整校验所有 DTO，再在一个本地事务中写入记录和 `cursor`；任何记录无效时不能留下部分数据或推进游标。

### 上传离线操作

`POST /api/mobile/sync/push`

需要 Bearer。每次必须包含 1...50 个操作，紧凑 JSON 最大 60 KiB。客户端还应按编码后的实际字节数分批，不能只按操作数量分批。

新增或更新：

```json
{
  "operations": [
    {
      "operationId": "33333333-3333-4333-8333-333333333333",
      "entityId": "11111111-1111-4111-8111-111111111111",
      "type": "upsert",
      "baseVersion": "2",
      "payload": {
        "id": "11111111-1111-4111-8111-111111111111",
        "name": "妈妈",
        "lunarMonth": 8,
        "lunarDay": 15,
        "isLeapMonth": false,
        "reminderTimeMinutes": 540,
        "notifyDayBefore": true,
        "notifySameDay": true,
        "emailEnabled": true,
        "emailAddress": "mom@example.com",
        "emailMessage": "生日快乐"
      }
    }
  ]
}
```

删除操作的 `payload` 必须省略或为 `null`：

```json
{
  "operations": [
    {
      "operationId": "44444444-4444-4444-8444-444444444444",
      "entityId": "11111111-1111-4111-8111-111111111111",
      "type": "delete",
      "baseVersion": "3",
      "payload": null
    }
  ]
}
```

服务端先校验完整批次，再按原顺序逐操作处理；每个操作使用独立事务。成功应用示例：

```json
{
  "results": [
    {
      "operationId": "33333333-3333-4333-8333-333333333333",
      "status": "applied",
      "record": {
        "id": "11111111-1111-4111-8111-111111111111",
        "name": "妈妈",
        "lunarMonth": 8,
        "lunarDay": 15,
        "isLeapMonth": false,
        "reminderTimeMinutes": 540,
        "notifyDayBefore": true,
        "notifySameDay": true,
        "emailEnabled": true,
        "emailAddress": "mom@example.com",
        "emailMessage": "生日快乐",
        "nextSolarDate": "2026-09-25T01:00:00.000Z",
        "version": "3",
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-08-22T04:00:00.000Z",
        "deletedAt": null
      }
    }
  ]
}
```

`conflict` 是该操作的结果状态，不是 HTTP 错误码；版本冲突仍返回 HTTP 200：

```json
{
  "results": [
    {
      "operationId": "33333333-3333-4333-8333-333333333333",
      "status": "conflict",
      "remote": {
        "id": "11111111-1111-4111-8111-111111111111",
        "name": "妈妈（云端）",
        "lunarMonth": 8,
        "lunarDay": 15,
        "isLeapMonth": false,
        "reminderTimeMinutes": 540,
        "notifyDayBefore": true,
        "notifySameDay": true,
        "emailEnabled": false,
        "emailAddress": "",
        "emailMessage": "",
        "nextSolarDate": "2026-09-25T01:00:00.000Z",
        "version": "4",
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-08-22T05:00:00.000Z",
        "deletedAt": null
      }
    }
  ]
}
```

`operationId` 是幂等键。相同设备、相同实体、相同 `baseVersion` 重试同一操作时返回首次持久化的 `applied` 或 `conflict` 结果，不重复业务写入；同一操作 ID 跨设备、改指向其他实体或更换 `baseVersion` 会被拒绝为 `invalid_birthday_payload`。一个操作冲突不会回滚同批次已独立处理的其他操作。客户端必须保存本地与 `remote` 两个版本，让用户明确选择，不能自动“最后写入获胜”。

### 增量拉取

`GET /api/mobile/sync/pull?cursor=41&limit=200`

需要 Bearer。`cursor` 必填；`limit` 可选，默认 200，只能为 1...200 的十进制整数。成功返回 HTTP 200：

```json
{
  "changes": [
    {
      "seq": "42",
      "operation": "delete",
      "record": {
        "id": "11111111-1111-4111-8111-111111111111",
        "name": "妈妈",
        "lunarMonth": 8,
        "lunarDay": 15,
        "isLeapMonth": false,
        "reminderTimeMinutes": 540,
        "notifyDayBefore": true,
        "notifySameDay": true,
        "emailEnabled": false,
        "emailAddress": "",
        "emailMessage": "",
        "nextSolarDate": "2026-09-25T01:00:00.000Z",
        "version": "4",
        "createdAt": "2026-01-01T00:00:00.000Z",
        "updatedAt": "2026-08-22T05:00:00.000Z",
        "deletedAt": "2026-08-22T05:00:00.000Z"
      }
    }
  ],
  "nextCursor": "42",
  "hasMore": false
}
```

`hasMore: true` 表示应立即使用 `nextCursor` 继续拉取。空页返回规范输入游标作为 `nextCursor`，并返回 `hasMore: false`。每条 `record` 都是该次变更提交后、在同一事务中保存的完整 APIBirthday 事件快照，不会用当前生日行覆盖历史事件。因此同一 ID 的 upsert、delete、restore 跨页拉取时仍各自保留当时的版本和墓碑状态；变更查询后的并发修改也不会改变已选中页面。`operation: "delete"` 的 `record` 必须是完整墓碑，且必须同时满足 `emailEnabled: false`、`emailAddress: ""`、`emailMessage: ""`；客户端应用墓碑后再推进本地游标。页内任一事件不满足完整 DTO、元数据、日期或墓碑约束时，整页失败且客户端不得推进游标。

## 稳定错误与状态

所有错误响应只包含稳定字段：

```json
{
  "error": "mobile_auth_required"
}
```

| HTTP | `error` | 含义 |
|---:|---|---|
| 400 | `invalid_mobile_login` | 登录请求字段、UUID 或设备名无效。 |
| 400 | `invalid_mobile_refresh` | 刷新令牌字段缺失、为空、类型错误或含非法字符。 |
| 400 | `invalid_mobile_device` | 撤销请求的设备 UUID 无效。 |
| 400 | `invalid_cursor` | 游标缺失、不是规范十进制，或超出非负 signed Int64。 |
| 400 | `invalid_limit` | `limit` 不在 1...200 或格式不合法。 |
| 400 | `invalid_birthday_payload` | 批次、操作、版本、UUID、生日或邮件字段不符合契约。 |
| 400 | `too_many_operations` | 单次 `push` 超过 50 个操作。 |
| 401 | `mobile_login_invalid` | 用户名或密码不匹配；不区分具体凭据。 |
| 401 | `mobile_auth_required` | 缺少格式正确的 Bearer 访问令牌。 |
| 401 | `mobile_access_expired` | 访问令牌未知、过期或已撤销。 |
| 401 | `mobile_refresh_invalid` | 刷新令牌未知、过期、已撤销或已被轮换。 |
| 404 | `mobile_device_not_found` | 当前账号没有对应的可撤销设备。 |
| 409 | `mobile_device_ownership_conflict` | `deviceId` 已属于不同用户名；原设备行保持不变且不披露所有者。 |
| 413 | `payload_too_large` | 请求超过 64 KiB JSON 解析上限。 |
| 429 | `api_rate_limited` | 全局 API 限流窗口内请求次数过多；若它先于登录限流命中，客户端也必须可解码此错误。 |
| 429 | `mobile_login_rate_limited` | 当前登录限流窗口内尝试次数过多。 |
| 500 | `server_error` | 未处理的服务器、数据库或内部一致性错误。 |
| 503 | `mobile_auth_unconfigured` | 服务器未配置移动登录账号或密码哈希。 |

内部一致性代码（例如 `mobile_sync_inconsistent_state`）不会返回给客户端，对外统一为 HTTP 500 `server_error`。错误日志只保留安全的异常 `name`/`code`，不记录异常消息、堆栈、令牌、密码或请求 payload。`conflict` 只出现在 HTTP 200 的 `results[].status` 中。

## 上线边界

本文及本地测试只证明代码契约。启用生产路由前仍需完成数据库备份、一次性迁移、结构只读核验、旧提醒发送器停机与遗留状态人工核对，并另行取得部署授权。未完成这些步骤时，不应向客户端承诺生产接口可用。
