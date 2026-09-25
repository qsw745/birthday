# 岁时 App Store 发布材料

## 上传素材

- 简体中文元数据：`metadata/zh-Hans.json`
- macOS 简体中文元数据：`metadata/macos-zh-Hans.json`
- 隐私问卷答案：`app-privacy.md`
- 审核说明：`review-notes.md`
- 6.9 英寸 iPhone 截图：`Screenshots/zh-Hans/upload/`
- Mac 截图：`Screenshots/macos/zh-Hans/upload/`

iPhone 截图为 1320 × 2868；Mac 截图为 2880 × 1800。两组均为 RGB、JPEG、无透明通道，推荐按文件名前缀顺序上传。2026-09-05 已更新全部 10 张截图，并在邮件提醒入口修复后重新捕获两端编辑器。隔离数据边界和再生成方式见 `Screenshots/README.md`、`Screenshots/macos/README.md`。

## 线上材料

- 产品官网：https://qisw.top/birthday/app.html
- 隐私政策：https://qisw.top/birthday/privacy.html
- 使用支持：https://qisw.top/birthday/support.html
- 两端元数据的 marketingURL 均指向新的公开产品官网。
- 2026-09-05 已按用户授权部署上述页面及关联资源；7 个文件通过 HTTPS 读回，状态均为 200，SHA-256 与本地一致。桌面与手机浏览器布局检查通过。
- 页面区分已发布的 iPhone 版本和准备发布的 iPhone 1.1 / Mac 1.0。详细证据见 `../QA/STORE_MATERIALS_20260905.md`。

## 发布核对

- `support@qisw.top` 已由用户确认可收件。
- 生产同步已完成结构、路由、鉴权拒绝与真实 MySQL 并发验证；尚未使用生产管理员账号写入生日数据或发送测试邮件。
- iOS 1.1 与 macOS 1.0 采用本机优先方案；Release 构建保持历史服务器地址为空，新增默认开启、可按设备关闭的 CloudKit 私有同步，无需审核账号。
- 双平台签名、CloudKit 生产环境、上传与审核由“设计离线优先移动端”发布任务继续执行。用户已在该任务授权签名归档、上传、复核后提审及审核通过自动发布；以 `../QA/MAC_APP_STORE_RELEASE.md`、`../QA/ICLOUD_MAC_ACCEPTANCE.md` 与 App Store Connect 的最新读回为准。
- 历史 iOS 1.0 的证书和真机签名证据不能替代本次 iCloud 双平台候选验收。
- 在 App Store Connect 完成 App 记录、年龄分级、价格与销售范围、隐私问卷和出口合规。
- 上传构建后等待处理完成；“已上传”不等于“已提交审核”。
- 素材准备、构建上传、处理完成、提交审核、审核通过和公开上架应分别记录。

## 2026-09-20 商店文案更新

本次 iPhone 1.1.1（5）和 Mac 1.0.1（5）已重新打包、上传并提交审核。最新状态与实包校验依据见 `../QA/ASO_SUBMISSION_20260920.md`；审核通过和公开发布须另行核实。
