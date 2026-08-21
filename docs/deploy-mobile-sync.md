# 移动同步生产切换清单（尚未执行）

> 当前状态：仅完成本地实现与本地测试，**不等于已经部署、迁移或验证生产环境**。下面每一步都属于未来的一次窄范围生产切换；未取得第 1 步的单独明确确认时，不得执行任何命令。

## 固定边界

- 目标仅限生日服务：`/data/app/birthday-server`、`email-node`、`mysql8`，以及对生日 Nginx location 的只读核对。
- 不修改、重载或重启 Nginx；不重启完整 Docker Compose 栈。
- 迁移是一次性的。任何部分迁移、备份不可读、历史提醒无法判定、真实 InnoDB 并发测试未通过，都必须停止。
- 所有导出可能包含姓名、邮箱和提醒正文，备份目录必须设为仅管理员可读；终端输出、工单和聊天中不得粘贴凭据或导出内容。
- 下列变量只使用本次切换专用名称；值由获批操作者在安全终端中提供，不写入仓库：

```sh
export BIRTHDAY_DB_USER='已审批的数据库用户'
export BIRTHDAY_DB_NAME='email_server'
export BIRTHDAY_REVIEW_BASE='服务器当前已核验提交号'
export BIRTHDAY_RELEASE_ID='审核通过的提交号'
export BIRTHDAY_BACKUP_DIR="/root/birthday-backups/${BIRTHDAY_RELEASE_ID}"
printf 'Database password: ' >&2
IFS= read -r -s BIRTHDAY_DB_PASSWORD
printf '\n' >&2
export BIRTHDAY_DB_PASSWORD
umask 077
```

## 顺序门禁

### 1. 单独取得生产切换确认

- [ ] 记录用户对“生产上传、停服、数据库迁移、一次测试提醒邮件”的明确确认、时间和目标提交号。
- [ ] 确认审核提交与 `BIRTHDAY_RELEASE_ID` 完全一致；仅“规格确认”或“本地实现确认”不构成生产切换授权。

**停止点：** 没有单独确认，立即停止；当前仍是“本地已准备、生产未部署”。

### 2. 只读核对容器、端口、应用目录和生日 Nginx location

```sh
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
ss -lntp
find /data/app/birthday-server -maxdepth 2 -type f -print
docker exec nginx grep -n -E -A8 -B3 \
  'birthday|3300|/api/birthdays|/api/auth|schedule-email' \
  /etc/nginx/conf.d/site.conf
```

- [ ] `email-node`、`mysql8`、`nginx` 与预期容器一致，宿主机 `3300` 映射仍指向 `email-node:3300`。
- [ ] 只检查生日相关 Nginx location；若发现需改 Nginx，退出本清单并另行评审。

### 3. 停止所有旧提醒发送者，等待至少 15 分钟

```sh
docker stop email-node
date -u '+sender-stopped-at=%Y-%m-%dT%H:%M:%SZ'
sleep 900
docker ps --format 'table {{.Names}}\t{{.Status}}'
date -u '+claim-lease-ended-at=%Y-%m-%dT%H:%M:%SZ'
```

- [ ] 确认没有其他主机、容器、定时器或人工脚本运行旧版 reminder sender。
- [ ] 核对最后 15 分钟日志和连接状态，确认没有 SMTP 调用或 reminder worker 仍在执行。
- [ ] 从此刻到第 14 步，不得启动任何旧版或新版 sender。

**停止点：** 只要仍有 sender/SMTP/worker in flight，就继续保持停服并调查，不得迁移。

### 4. 备份应用、Nginx 和三个既有业务表，并验证可读

```sh
install -d -m 700 "$BIRTHDAY_BACKUP_DIR"
tar -C /data/app -czf "$BIRTHDAY_BACKUP_DIR/birthday-server.tgz" birthday-server
cp -a /opt/nginx/conf.d/site.conf "$BIRTHDAY_BACKUP_DIR/site.conf"
set -o pipefail
docker exec -i -e MYSQL_PWD="$BIRTHDAY_DB_PASSWORD" mysql8 \
  mysqldump --single-transaction --skip-lock-tables \
  -u"$BIRTHDAY_DB_USER" "$BIRTHDAY_DB_NAME" \
  birthdays email_reminders webauthn_credentials \
  | gzip -c > "$BIRTHDAY_BACKUP_DIR/business-tables.sql.gz"
tar -tzf "$BIRTHDAY_BACKUP_DIR/birthday-server.tgz"
gzip -t "$BIRTHDAY_BACKUP_DIR/business-tables.sql.gz"
test -s "$BIRTHDAY_BACKUP_DIR/site.conf"
test -s "$BIRTHDAY_BACKUP_DIR/business-tables.sql.gz"
```

- [ ] 备份范围恰好包含应用目录、当前 `site.conf`、`birthdays`、`email_reminders`、`webauthn_credentials`。
- [ ] `tar -tzf`、`gzip -t` 和非空检查全部成功，并把文件大小与校验和写入切换记录。

**停止点：** 任一备份缺失或不可读，恢复到备份步骤，不得上传或迁移。

### 5. 导出历史已标记提醒和 provenance 候选，逐行人工审核

```sh
docker exec -i -e MYSQL_PWD="$BIRTHDAY_DB_PASSWORD" mysql8 mysql \
  --batch --raw -u"$BIRTHDAY_DB_USER" "$BIRTHDAY_DB_NAME" \
  -e "SELECT r.*, b.nextSolarDate,
             (r.remind_time = b.nextSolarDate) AS equals_next_solar_date
      FROM email_reminders r
      JOIN birthdays b ON b.id = r.birthday_id
      WHERE r.status = 1
      ORDER BY r.id" \
  > "$BIRTHDAY_BACKUP_DIR/legacy-status-1.tsv"

docker exec -i -e MYSQL_PWD="$BIRTHDAY_DB_PASSWORD" mysql8 mysql \
  --batch --raw -u"$BIRTHDAY_DB_USER" "$BIRTHDAY_DB_NAME" \
  -e "SELECT r.id, r.birthday_id, r.remind_time, b.nextSolarDate,
             CASE
               WHEN b.nextSolarDate IS NULL THEN 'nextSolarDate-null'
               WHEN r.remind_time = b.nextSolarDate THEN 'equal-candidate'
               ELSE 'legacy-exact-candidate'
             END AS provenance_candidate
      FROM email_reminders r
      JOIN birthdays b ON b.id = r.birthday_id
      WHERE b.nextSolarDate IS NULL
         OR r.remind_time = b.nextSolarDate
         OR r.remind_time <> b.nextSolarDate
      ORDER BY r.id" \
  > "$BIRTHDAY_BACKUP_DIR/legacy-provenance-candidates.tsv"

test -f "$BIRTHDAY_BACKUP_DIR/legacy-status-1.tsv"
test -f "$BIRTHDAY_BACKUP_DIR/legacy-provenance-candidates.tsv"
```

- [ ] `legacy-status-1.tsv` 保留全部旧 `status=1` 行；旧状态只表示“曾被领取或送达”，不能单独证明 SMTP 已送达。
- [ ] 对照 SMTP/邮件投递日志，为每一行记录“明确已送达 / 明确未送达 / 不确定”。
- [ ] 逐行人工确认 derived/exact 来源，特别审阅 `nextSolarDate IS NULL` 和 `remind_time = nextSolarDate`；相等的历史 exact 无法靠数据库自动区分。

**停止点：** 任一状态、投递结果或 provenance 候选无法确认，停止切换并保留旧 sender 停止状态，不得运行 migration。

### 6. 迁移前只读 preflight：四个生日新列必须全部不存在

```sh
docker exec -i -e MYSQL_PWD="$BIRTHDAY_DB_PASSWORD" mysql8 mysql \
  --batch --raw -u"$BIRTHDAY_DB_USER" "$BIRTHDAY_DB_NAME" \
  -e "SELECT COUNT(*) AS birthday_marker_count,
             GROUP_CONCAT(COLUMN_NAME ORDER BY COLUMN_NAME) AS present_columns
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'birthdays'
        AND COLUMN_NAME IN
          ('version','deleted_at','notify_day_before','notify_same_day');

      SELECT TABLE_NAME, COLUMN_NAME
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND ((TABLE_NAME = 'email_reminders'
              AND COLUMN_NAME IN
                ('schedule_mode','generation','claim_token','claim_generation',
                 'claim_remind_time','claimed_at','delivered_remind_time'))
          OR TABLE_NAME IN
                ('mobile_sync_changes','mobile_sync_operations','mobile_device_sessions'))
      ORDER BY TABLE_NAME, COLUMN_NAME;"
```

- [ ] `birthday_marker_count` 必须严格等于 `0`，且第二个结果集为空。
- [ ] 若四列出现 1–3 列，属于明确的 partial migration；若出现 4 列或任何提醒/移动表 marker，也不得重跑 migration，必须先单独调查和恢复。

### 7. 仅上传已审核文件和一次性 migration

在本地从审核通过的提交生成并人工复核精确清单，排除 `tests/`、`docs/superpowers/`、`ios/` 和任何未审核文件：

```sh
git diff --name-only "$BIRTHDAY_REVIEW_BASE" "$BIRTHDAY_RELEASE_ID" \
  -- app.js jobs middleware repositories routes services utils sql scripts package.json package-lock.json \
  > /tmp/birthday-reviewed-files.txt
cat /tmp/birthday-reviewed-files.txt
```

- [ ] 清单必须包含 `sql/migrations/20260821_mobile_sync.sql` 和 `scripts/verify_mobile_sync_schema.js`，并只包含本轮已审核的生日服务文件。
- [ ] 使用显式清单逐文件上传到 `/data/app/birthday-server`；禁止同步整个工作区，禁止触碰其他应用目录：

```sh
rsync -a --files-from=/tmp/birthday-reviewed-files.txt ./ \
  root@101.37.21.147:/data/app/birthday-server/
```

- [ ] 上传后按清单逐项比较 SHA-256；差异不一致立即从第 4 步应用备份恢复。

### 8. 使用 `MYSQL_PWD` 在 `mysql8` 中一次性运行 migration

```sh
docker exec -i -e MYSQL_PWD="$BIRTHDAY_DB_PASSWORD" mysql8 mysql \
  -u"$BIRTHDAY_DB_USER" "$BIRTHDAY_DB_NAME" \
  < /data/app/birthday-server/sql/migrations/20260821_mobile_sync.sql
```

- [ ] 只运行一次，不使用 `-p"$BIRTHDAY_DB_PASSWORD"`，不忽略任何 SQL 错误。
- [ ] SQL 非零退出时保持 `email-node` 停止，保存错误位置，不继续依赖安装或启动。

### 9. 立即只读回读 schema 和保守提醒状态

```sh
docker exec -i -e MYSQL_PWD="$BIRTHDAY_DB_PASSWORD" mysql8 mysql \
  --batch --raw -u"$BIRTHDAY_DB_USER" "$BIRTHDAY_DB_NAME" \
  -e "SELECT TABLE_NAME, ENGINE
      FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME IN
          ('birthdays','email_reminders','mobile_sync_changes',
           'mobile_sync_operations','mobile_device_sessions')
      ORDER BY TABLE_NAME;

      SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, EXTRA
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND ((TABLE_NAME = 'birthdays'
              AND COLUMN_NAME IN
                ('version','deleted_at','notify_day_before','notify_same_day'))
          OR (TABLE_NAME = 'email_reminders'
              AND COLUMN_NAME IN
                ('schedule_mode','generation','claim_token','claim_generation',
                 'claim_remind_time','claimed_at','delivered_remind_time'))
          OR (TABLE_NAME = 'mobile_sync_changes'
              AND COLUMN_NAME IN ('seq','entity_version','record_json'))
          OR (TABLE_NAME = 'mobile_sync_operations'
              AND COLUMN_NAME IN ('base_version','response_json')))
      ORDER BY TABLE_NAME, ORDINAL_POSITION;

      SELECT COUNT(*) AS invalid_schedule_or_generation
      FROM email_reminders
      WHERE schedule_mode NOT IN ('derived','exact') OR CHAR_LENGTH(generation) <> 36;

      SELECT COUNT(*) AS non_null_claim_fields
      FROM email_reminders
      WHERE claim_token IS NOT NULL OR claim_generation IS NOT NULL
         OR claim_remind_time IS NOT NULL OR claimed_at IS NOT NULL;

      SELECT COUNT(*) AS legacy_not_conservatively_pending
      FROM email_reminders
      WHERE status <> 0 OR delivered_remind_time IS NOT NULL;"
```

- [ ] 三张移动表都存在且为 InnoDB；`seq`、`entity_version`、`base_version` 都是 signed `BIGINT`。
- [ ] `record_json`、`response_json` 为 `JSON`；四个生日列、提醒 7 个新增列全部符合迁移 SQL。
- [ ] `schedule_mode`/`generation` 全部有效；四个 claim 字段全部为 `NULL`。
- [ ] 在人工恢复前，全部 legacy 行都必须是 `status=0` 且 `delivered_remind_time IS NULL`。

**停止点：** 任一 read-back 不符即判定迁移未通过。不要启动服务；按“回滚停止点”处理。

### 10. 只恢复日志明确证明已送达的行，其他保持 pending

先从第 5 步的人审清单生成明确已送达 UUID 列表。没有明确已送达行时跳过 `UPDATE`，不得用旧 `status=1` 批量推断。

```sql
UPDATE email_reminders
SET status = 1,
    delivered_remind_time = remind_time
WHERE id IN ('仅填写逐行审核确认已送达的 UUID')
  AND status = 0
  AND delivered_remind_time IS NULL;

SELECT id, status, delivered_remind_time
FROM email_reminders
WHERE id IN ('同一份已确认 UUID 清单')
ORDER BY id;

SELECT COUNT(*) AS uncertain_rows_not_pending
FROM email_reminders
WHERE id IN ('人审标记为不确定的 UUID 清单')
  AND (status <> 0 OR delivered_remind_time IS NOT NULL);
```

- [ ] 通过 AGENTS 规定的 `docker exec -i -e MYSQL_PWD=... mysql8 mysql ...` 方式执行，并保存受影响行数。
- [ ] 已确认集合逐行 read-back 为 `status=1` 且 `delivered_remind_time=remind_time`；不确定集合计数必须为 `0`。

### 11. 仅在生产依赖确有变化时安装依赖

- [ ] 对比备份与上传后的 `package.json`/`package-lock.json` 的 `dependencies`；只有生产依赖变化时才在挂载应用目录运行：

```sh
cd /data/app/birthday-server
npm ci --omit=dev
```

- [ ] 若只有 Supertest 或测试脚本等 dev-only 变化，跳过本步；生产不得安装 Supertest。

### 12. 运行只读 verifier、语法检查和只读计数

在不启动 scheduler 的一次性 Compose 容器里执行：

```sh
docker compose -f /root/docker-migrated-stack/docker-compose.yml run --rm --no-deps \
  --entrypoint node email-node scripts/verify_mobile_sync_schema.js

node --check /data/app/birthday-server/scripts/verify_mobile_sync_schema.js
node --check /data/app/birthday-server/app.js
find /data/app/birthday-server/{jobs,middleware,repositories,routes,services,utils} \
  -type f -name '*.js' -exec node --check {} \;

docker exec -i -e MYSQL_PWD="$BIRTHDAY_DB_PASSWORD" mysql8 mysql \
  --batch --raw -u"$BIRTHDAY_DB_USER" "$BIRTHDAY_DB_NAME" \
  -e "SELECT 'birthdays' AS table_name, COUNT(*) AS row_count FROM birthdays
      UNION ALL SELECT 'email_reminders', COUNT(*) FROM email_reminders
      UNION ALL SELECT 'mobile_sync_changes', COUNT(*) FROM mobile_sync_changes
      UNION ALL SELECT 'mobile_sync_operations', COUNT(*) FROM mobile_sync_operations
      UNION ALL SELECT 'mobile_device_sessions', COUNT(*) FROM mobile_device_sessions;"
```

- [ ] verifier 必须只输出 `MOBILE_SYNC_SCHEMA=PASS`；任何 `FAIL`、缺列、类型、可空性、引擎或索引不兼容都阻塞启动。
- [ ] 所有 `node --check` 通过；只读计数已与迁移前备份/人工恢复清单核对。

### 13. 在可丢弃 MySQL 8 InnoDB 上完成真实并发阻塞测试

本地单元测试只模拟 SQL 状态机，**尚未执行真实 MySQL/InnoDB 并发验证**。生产启动前，必须另行批准并在可丢弃、无生产数据的 MySQL 8 InnoDB 实例完成：

- [ ] 同一既有 birthday 的并发更新只允许一个基于当前版本成功，另一个得到可重放 conflict。
- [ ] 同一缺失 UUID 的并发插入 race 不产生两行；精确的 duplicate/deadlock/lock-timeout 最多共 3 次 transaction attempt。
- [ ] 同一 `operation_id` 的并发请求只持久化一次结果，重复请求返回完全相同的 `response_json`。
- [ ] 非 operation-id 的唯一键冲突不得被误当成可重试插入 race。
- [ ] 主动制造 InnoDB deadlock 与 lock timeout，确认只重试已允许错误，且每次使用全新连接/完整 transaction。
- [ ] 保存数据库版本、隔离级别、测试命令和结果；任一项未运行或失败都阻塞生产切换。

### 14. 只重启 `email-node`

```sh
docker restart email-node
docker ps --filter name=email-node --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker logs --since 5m email-node
```

- [ ] 不执行 `docker compose restart`，不重启 `mysql8` 或 `nginx`。
- [ ] 启动日志没有 schema、scheduler、数据库连接或重复 job 注册错误。

### 15. 验证网页、移动同步、提醒调度和 SMTP

- [ ] `GET /api/auth/status` 返回预期 JSON；用密码完成一次网页登录，并确认生日列表可读。
- [ ] 无 Bearer token 调用 `/api/mobile/sync/snapshot` 返回稳定 JSON `401`，而不是 HTML、重定向或 cookie 登录结果。
- [ ] 使用专门测试设备会话依次验证 mobile login/refresh/devices/snapshot/pull/push/revoke；核对字符串 Int64 cursor/version、operation replay、conflict 和 tombstone。
- [ ] 创建专用测试生日，核对 derived/exact 调度、generation、claim token、失败回滚与 15 分钟 lease 规则。
- [ ] 只向已批准的测试邮箱发送一次可识别 SMTP 测试提醒；同时核对应用日志、邮箱实际收件和 `delivered_remind_time`，三者缺一不可宣称送达。
- [ ] 删除测试生日后确认 tombstone 已同步，且不再发送提醒。

### 16. 明确不 reload Nginx，并完成记录

- [ ] 不运行 `nginx -s reload`、`docker reload nginx` 或任何 Nginx 写操作；本轮没有 Nginx 配置变更。
- [ ] 记录提交号、备份校验和、migration 输出、read-back、verifier、真实 InnoDB 并发测试、接口验证和 SMTP 证据。
- [ ] 只有以上 16 步全部通过，才可把状态从“生产切换中”更新为“已部署并完成受限验证”；这仍不等于已完成长期调度、长期离线同步或真实多设备稳定性验证。

## 回滚停止点

1. **运行 migration 前：** 保持 `email-node` 停止；如上传已发生，只从本次第 4 步应用备份恢复 `/data/app/birthday-server`。Nginx 未变，不做 reload。
2. **migration 已运行、`email-node` 尚未启动：** 不尝试手写逆向 `ALTER`。保留故障现场和导出，经单独回滚确认后，从已验证的三个业务表 dump 与应用备份恢复；恢复后重新执行只读 schema/行数检查。
3. **新 `email-node` 已产生任何同步、提醒或 SMTP 写入：** 禁止直接覆盖数据库。停止 sender，保存新写入和日志，进入单独的数据合并/事件恢复方案；未经审核的整库回灌可能丢失生日、operation replay 或投递证据。
4. **任何阶段出现疑似凭据泄露：** 停止切换并轮换相应凭据；错误输出和工单不得包含原始数据库/SMTP secret。

## 本计划未覆盖或尚未验证

- 尚未连接生产数据库、运行 migration、发送 SMTP、启动 scheduler、上传文件、重启容器或 SSH 到服务器。
- 尚未在真实 MySQL 8 InnoDB 上执行并发 race/deadlock/timeout 测试。
- 尚未进行生产移动同步、多设备、断网重连、长期 reminder 调度或实际投递监控。
- Nginx 配置不在变更范围；若后续发现需要修改，必须使用单独方案、备份、`nginx -t` 和独立授权。
