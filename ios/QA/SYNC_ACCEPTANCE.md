# 双设备同步验收清单

## 自动化集成测试前置条件

仅可连接本机回环地址上的一次性 MySQL。测试要求数据库名以 `_test` 结尾，若同名数据库已存在会直接拒绝复用；测试创建的数据库会在 teardown 中按已验证的精确名称删除并回读确认。

```bash
MOBILE_SYNC_TEST_DB_HOST=127.0.0.1 \
MOBILE_SYNC_TEST_DB_PORT=3306 \
MOBILE_SYNC_TEST_DB_USER=root \
MOBILE_SYNC_TEST_DB_PASSWORD='仅限临时本地实例' \
MOBILE_SYNC_TEST_DB_NAME=birthday_mobile_sync_test \
npm run test:integration:mobile
```

不得加载项目 `.env`、连接生产数据库、连接 `101.37.21.147`，也不得复用或删除已存在的测试数据库。

## 真机手工验收

- [ ] 首次导入条数与网页当前生日条数一致
- [ ] 飞行模式新增后立即可见，并显示待同步
- [ ] 恢复网络后自动同步，网页可见同一 UUID
- [ ] 第二台设备拉取到变更并重排本地通知
- [ ] 两台设备同时编辑同一记录时出现冲突，不静默覆盖
- [ ] 保留本机与使用云端两条解决路径均验证
- [ ] 删除与离线编辑冲突可以恢复或确认删除
- [ ] 访问令牌过期自动刷新一次
- [ ] 撤销设备后该设备同步收到认证失效，本地数据仍可用
- [ ] 服务器停机期间本地查看、编辑、Face ID 和通知正常
