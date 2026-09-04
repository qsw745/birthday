# iOS 1.1 与 macOS 1.0 受控发布记录

记录日期：2026-09-05

当前分支：`codex/ios-local-first`

应用：岁时（App Store Connect 应用 ID `6804226958`）

## 当前结论

本地发布候选和商店素材已准备，但尚未形成可上传的签名归档。没有部署生产 CloudKit、没有修改线上页面或 App Store Connect、没有创建或调整描述文件、没有上传构建、没有提交审核。

| 项目 | 当前证据 | 状态边界 |
| --- | --- | --- |
| iPhone 候选版本 | `1.1.0 (2)` | 本地 Release 无签名构建，不是归档 |
| Mac 候选版本 | `1.0.0 (2)` | 本地 Release 无签名 Catalyst 构建，不是归档 |
| 历史线上版本 | App Store Connect 读到 iOS `1.0`、构建 `1.0.0 (1)` | 2026-09-05 只读快照，后续可能变化 |
| TestFlight | 只读快照中仅有 iOS `1.0.0 (1)` | 新候选尚未上传 |
| macOS 平台 | 只读快照中尚未创建 | 本次未写入 App Store Connect |
| Release 服务器地址 | `BirthdayAPIBaseURL` 为空 | 正式版不恢复历史服务器同步 |
| 本地数据库与 iCloud | SwiftData `cloudKitDatabase` 显式为 `.none` | 本地模型不使用自动 CloudKit；同步只经过 `CKSyncEngine` |
| 审核说明草稿 | `ios/AppStore/review-notes.md` | 尚未粘贴或提交 |

行动前必须重新读取 App Store Connect；本记录不能作为最新在线状态的替代。

## 本地验证

| 检查 | 结果 |
| --- | --- |
| Node 主回归 | 338/338 通过 |
| 移动同步回归 | 264/264 通过 |
| BirthdayCore | 333/333 通过 |
| Apple 工程、隐私、元数据与截图契约 | 18/18 通过 |
| iPhone 模拟器完整方案 | 22/22 通过，包含 13 个应用测试和 9 个离线/UI 流程 |
| iOS Release 无签名构建 | 通过；包内版本 `1.1.0 (2)`，服务器地址为空 |
| Mac Catalyst Release 无签名构建 | 通过；包内版本 `1.0.0 (2)`，二进制包含 `arm64` 与 `x86_64`，服务器地址为空 |
| 包内资源 | 两端均只有各自主 `Info.plist` 与 `PrivacyInfo.xcprivacy`；未发现历史移动 API 地址 |

无签名构建和模拟器测试不能替代签名归档、真实 CloudKit、TestFlight 或商店审核。

## Mac 截图证据

上传目录：`ios/AppStore/Screenshots/macos/zh-Hans/upload/`

- 5 张 RGB JPEG，均为 2880 × 1800、16:10、无透明通道。
- 使用 Release 无签名应用、内存 SwiftData、固定时间和注入的 CloudKit 测试状态捕获。
- 虚构姓名白名单：清和、星野、望舒、知夏、小满。
- 不包含真实姓名、真实生日、邮箱、电话号码、Apple ID、iCloud 用户标识或服务器账号。
- 原始窗口截图不提交；渲染脚本和再生成说明保存在同级目录。
- 2026-09-05 已逐张完成视觉检查；自动契约同时校验文件清单、尺寸、格式、色彩空间和透明通道。

## 发布门禁

- [x] 本地候选版本、Release 无签名构建、隔离截图、隐私材料和审核说明草稿
- [ ] 获得行动时确认后创建或绑定 `iCloud.top.qisw.birthday`，并部署 Production CloudKit Schema 与索引
- [ ] 使用生产容器完成真实 iPhone ↔ Mac 双端验证
- [ ] 获得行动时确认后部署线上隐私与支持页面，并在 App Store Connect 增加 macOS 平台
- [ ] 获得行动时确认后生成签名归档，核对 Payload、entitlements、描述文件与 Xcode Privacy Report
- [ ] 上传 iOS 与 macOS 构建，并分别确认处理完成与 TestFlight 可用
- [ ] 从 TestFlight 在真实 iPhone 与 Mac 安装，重复离线、同步、通知、锁定、导出和迁移验收
- [ ] 展示最终构建、问卷、截图、审核说明和发布方式后，再获得提交审核确认
- [ ] 分别记录等待审核、审核中、批准、可供销售、公开页面和真实下载安装状态

任何生产 CloudKit 验证失败都会停止后续上传。`VALID`、上传完成、处理完成、TestFlight 可用、已提交审核和公开发布是不同状态，不得相互替代。

## 当前阻断项

- 当前设备清单中的实体 iPhone 不可用，真实双端矩阵尚未执行。
- 当前没有覆盖新 CloudKit 权限的 iPhone/Mac 发布描述文件。
- 最终签名归档的双架构、实际 entitlements、描述文件、Privacy Report 和 Payload 尚未检查。
- 生产 CloudKit、线上材料、App Store Connect 平台、上传和提交均等待各自的行动时确认。
