# 历史 SwiftData 迁移夹具

## 来源与完整性

- 来源提交：`d457260`。
- 模型身份：该提交中的顶层 `BirthdayEntity`、`SyncOperationEntity` 和
  `SyncMetadataEntity`，未使用当前 `BirthdaySchemaV1.*` 类型。
- 数据库：`d457260-unversioned.store`，已执行 WAL checkpoint，只需这一个 SQLite 文件。
- SHA-256：`eb16f77c40cc12eb91715b75f975cb51a013d2a38149f4b496c359c10bedb769`。
- 数据仅含固定测试文字、UUID 和时间，不含用户隐私、令牌或凭据。

测试复制该文件到临时目录后，只通过当前生产 `BirthdayModelContainer.make` 打开，
不得用当前 V1 类型重新创建“历史”数据库。

## 固定字段期望

- birthday：ID `11111111-1111-4111-8111-111111111111`、名称“旧版妈妈”、
  `syncStateRaw=pending`。
- pending outbox：operation ID `22222222-2222-4222-8222-222222222222`、
  `operationType=update`、`baseVersion=7`、`attemptCount=2`、payload
  `{"name":"旧版妈妈"}`。
- metadata：`key=primary`、`cursor=9`。
- 升级后：以上数据完整保留，且新的 `SyncConflictEntity` 可以写入。

## 再生成

先用 `git show d457260:<路径>` 逐项核对生成脚本中的三个顶层模型声明，然后在仓库根目录运行：

```bash
swift ios/BirthdayCore/Tests/BirthdayCoreTests/Fixtures/generate_d457260_fixture.swift \
  /tmp/d457260-unversioned.store
sqlite3 /tmp/d457260-unversioned.store 'PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;'
shasum -a 256 /tmp/d457260-unversioned.store
```

确认三个表各有一行、完整性为 `ok`，再替换仓库夹具并有意更新本文件中的 SHA-256。
SQLite 内部元数据可能使重新生成的字节散列变化，因此不得静默更新二进制或散列。

## V2 前 CloudKit 夹具

- 来源提交：`364b73d`，此时生产容器仍以 `BirthdaySchemaV2` 为当前 schema。
- 模型身份：`BirthdaySchemaV2.BirthdayEntity`、`SyncOperationEntity`、
  `SyncMetadataEntity` 和 `SyncConflictEntity`；生成器保存了完整的冻结声明，
  不导入当前 `BirthdayCore`，因此未来 V3 及更高版本的 typealias 不会改变夹具。
- 数据库：`v2-pre-cloud.store`，已执行 WAL checkpoint，只需这一个 SQLite 文件。
- SHA-256：`1dd21673d890fff38f97f9cc7de92b52ba1d607cfb9faf2be082ef090766b4d1`。
- 数据仅含固定测试文字、UUID 和时间，不含用户隐私、令牌或凭据。

### 固定字段期望

- 活动生日：ID `11111111-1111-4111-8111-111111111111`、名称“V2 妈妈”。
- 墓碑：ID `33333333-3333-4333-8333-333333333333`、名称“V2 已删除好友”、
  `deletedAt=1700000300`。
- 服务器待同步操作：operation ID `22222222-2222-4222-8222-222222222222`、
  `operationType=update`、`baseVersion=7`、`attemptCount=2`、
  `lastErrorCategory=network`。
- 服务器游标：`key=primary`、`cursor=19`。
- 服务器冲突：活动生日对应的本机与远端固定 JSON，`kindRaw=editEdit`。
- 升级到 V3 后：以上数据完整保留，三张新增 CloudKit 状态表为空。

### 再生成

只在有意更新 V2 兼容边界时运行；不得从当前生产模型或 typealias 生成：

```bash
swift generate_v2_pre_cloud_fixture.swift /tmp/v2-pre-cloud.store
sqlite3 /tmp/v2-pre-cloud.store 'PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;'
shasum -a 256 /tmp/v2-pre-cloud.store
```

确认两条生日、一条待同步操作、一条游标、一条服务器冲突、完整性为 `ok`，
再有意替换仓库夹具并同步更新本文件和迁移测试中的 SHA-256。
