# 岁时 App Store 发布材料

## 上传素材

- 简体中文元数据：`metadata/zh-Hans.json`
- 隐私问卷答案：`app-privacy.md`
- 审核说明：`review-notes.md`
- 6.9 英寸 iPhone 截图：`Screenshots/zh-Hans/upload/`

截图为 1320 × 2868、RGB、JPEG、无透明通道。推荐按文件名前缀顺序上传。

## 发布前阻断项

- `support@qisw.top` 已由用户确认可收件。
- `public/privacy.html`、`public/support.html` 与 `public/legal.css` 已部署到生产站点并逐页读回验证。
- 生产同步已完成结构、路由、鉴权拒绝与真实 MySQL 并发验证；尚未使用生产管理员账号写入生日数据或发送测试邮件。
- 首发范围仍需最终确认：若不提供隔离的审核账号，首发构建应隐藏同步入口并删除同步宣传；不得向审核团队提供含真实私人数据的管理员账号。
- Apple Distribution 证书已创建并在钥匙串读回；真机 Release 构建已签名、安装并启动。App Store archive/profile 尚待首发范围确认后生成。
- 在 App Store Connect 完成 App 记录、年龄分级、价格与销售范围、隐私问卷和出口合规。
- 上传构建后等待处理完成；“已上传”不等于“已提交审核”。
- 点击“提交以供审核”前再次获取用户的操作时确认。
