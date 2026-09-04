# 岁时 App Store 发布材料

## 上传素材

- 简体中文元数据：`metadata/zh-Hans.json`
- macOS 简体中文元数据：`metadata/macos-zh-Hans.json`
- 隐私问卷答案：`app-privacy.md`
- 审核说明：`review-notes.md`
- 6.9 英寸 iPhone 截图：`Screenshots/zh-Hans/upload/`
- Mac 截图：`Screenshots/macos/zh-Hans/upload/`

iPhone 截图为 1320 × 2868；Mac 截图为 2880 × 1800。两组均为 RGB、JPEG、无透明通道，推荐按文件名前缀顺序上传。Mac 截图的隔离数据边界和再生成方式见 `Screenshots/macos/README.md`。

## 发布前阻断项

- `support@qisw.top` 已由用户确认可收件。
- 线上已有历史隐私与支持页面；本次加入 iCloud/Mac 说明的 `public/privacy.html`、`public/support.html` 与 `public/legal.css` 仍只在本地，获得线上材料授权后才能部署并逐页读回。
- 生产同步已完成结构、路由、鉴权拒绝与真实 MySQL 并发验证；尚未使用生产管理员账号写入生日数据或发送测试邮件。
- iOS 1.1 与 macOS 1.0 采用本机优先方案；Release 构建保持历史服务器地址为空，新增默认开启、可按设备关闭的 CloudKit 私有同步，无需审核账号。
- CloudKit 生产 Schema、线上隐私与支持页面、macOS 平台记录均未在本地准备阶段修改；执行这些发布动作前需重新确认。
- 历史 iOS 1.0 的 Apple Distribution 证书和真机签名证据不能替代本次 iCloud 双平台候选验收；iOS 1.1/macOS 1.0 的 App Store archive/profile 尚未生成。
- 在 App Store Connect 完成 App 记录、年龄分级、价格与销售范围、隐私问卷和出口合规。
- 上传构建后等待处理完成；“已上传”不等于“已提交审核”。
- 点击“提交以供审核”前再次获取用户的操作时确认。
