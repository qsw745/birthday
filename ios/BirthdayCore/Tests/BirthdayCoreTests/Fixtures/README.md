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
