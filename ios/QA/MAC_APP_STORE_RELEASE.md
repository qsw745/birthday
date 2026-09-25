# iOS 1.1 与 macOS 1.0 受控发布记录

记录日期：2026-09-06

当前分支：`codex/ios-local-first`

应用：岁时（App Store Connect 应用 ID `6804226958`）

## 当前结论

双平台商店材料和官网已更新，Production CloudKit Schema 与真实 iPhone ↔ Mac 关键数据闭环已验证。构建 3 因测试版 macOS 构建环境被 Apple 自动拒绝后，iPhone 1.1.0 (4) 和 Mac 1.0.0 (4) 已在稳定版 macOS 26.6（`25G72`）虚拟机重建，完成发布签名、导出、上传、处理和版本绑定；两端均保持“审核通过后自动发布”。iPhone 1.1 已完成审核并批准，App Store Connect 显示“可分发”，中国大陆 App Store 公开接口已返回版本 1.1。Mac 1.0 已于 2026-09-06 13:53 重新提交，当前为“等待审核”，尚未批准或公开发布。

| 项目 | 当前证据 | 状态边界 |
| --- | --- | --- |
| iPhone 发布版本 | `1.1.0 (4)`；构建 ID `e5482778-f81e-427f-822b-9cd32afdcd72` | 审核提交“已完成审核”，项目“已批准”；版本页“可分发”；中国大陆公开接口返回 1.1 |
| Mac 候选版本 | `1.0.0 (4)`；构建 ID `d75c210d-96c9-456a-823a-d32eb4639e3b` | 已于 2026-09-06 13:53 重新提交，状态“等待审核” |
| 中国大陆线上版本 | App Store 公开查询 `resultCount=1`，`version=1.1` | 公开页面为 `https://apps.apple.com/cn/app/id6804226958`；搜索索引仍可能延迟 |
| TestFlight | iPhone 与 Mac 构建 4 均已处理完成，状态为“准备提交” | 尚未完成 TestFlight 安装和真机/真 Mac 回归 |
| macOS 平台 | 已创建并配置 Mac 1.0 页面、5 张截图、构建 4 与审核资料 | 已重新提交并等待审核；尚未获批或公开发布 |
| iPhone 开发描述文件 | `iOS Team Provisioning Profile: top.qisw.birthday`，UUID `165e8217-6084-4d9c-a1e4-c97dd6442f71` | 已创建；Debug 实包读回 CloudKit 与 `aps-environment=development` |
| Mac Catalyst 开发描述文件 | `Mac Catalyst Team Provisioning Profile: top.qisw.birthday`，UUID `a795de68-02a8-43d1-9be5-7686037d9354` | 已创建；Debug 实包读回 CloudKit 与 `com.apple.developer.aps-environment=development` |
| 发布描述文件 | iPhone UUID `87a29727-1e83-4c67-b9ec-ba6b3fa790fb`；Mac Catalyst UUID `98899523-5526-4dd7-9a38-ae54aebd3c0a` | 2026-09-05 新建；两端均含 Production CloudKit 与生产 APS 权限 |
| Production CloudKit | 容器 `iCloud.top.qisw.birthday`；`Birthday` 含 11 个业务字段和 6 个系统字段；0 个自定义索引 | 已部署并读回；真实 iPhone ↔ Mac 新增、修改、删除墓碑和队列收敛已通过，系统推送尚未验证 |
| Production 隔离冒烟 | bundle ID `top.qisw.birthday.cloudkitsmoke`，Release 空服务器基址，独立开发描述文件 | 不替换公开 iOS 1.0，不恢复历史服务器同步，不等于 TestFlight 候选 |
| Release 服务器地址 | `BirthdayAPIBaseURL` 为空 | 正式版不恢复历史服务器同步 |
| 本地数据库与 iCloud | SwiftData `cloudKitDatabase` 显式为 `.none` | 本地模型不使用自动 CloudKit；同步只经过 `CKSyncEngine` |
| 审核提交 | iOS 提交 ID `f71bafa6-efec-416e-a62d-d2b6099701d9`；Mac 提交 ID `f1377851-e914-4cef-8d55-204a45e75c7e` | 构建 4：iOS 已完成审核并批准；Mac 等待审核。构建 3 的 `ITMS-90111` / `ITMS-90301` 仅作为历史拒绝记录 |
| 被拒构建环境 | macOS 27.0 beta 8（`26A5425a`）；Xcode 26.6（`17F113`）；iOS/macOS SDK 26.5 | 测试版构建系统与旧一代 SDK 组合不被 Apple 接受；不是应用功能或签名内容错误 |
| 发布方式 | 两端均选择审核通过后自动发布 | iPhone 已批准并可分发；Mac 批准后将自动发布 |
| 稳定构建环境 | macOS 26.6（`25G72`）；Xcode 26.6（`17F113`）；iOS/macOS SDK 26.5 | 构建 4 的归档均读回 `BuildMachineOSBuild=25G72` |

行动前必须重新读取 App Store Connect；本记录不能作为最新在线状态的替代。

## 本地验证

| 检查 | 结果 |
| --- | --- |
| Node 主回归 | 340/340 通过 |
| 移动同步回归 | 266/266 通过 |
| BirthdayCore | 334/334 通过 |
| 固定 V1/V2 → V3 迁移 | 5/5 通过 |
| Apple 工程、隐私、元数据、截图与生产冒烟隔离契约 | 20/20 通过 |
| iPhone 与 Mac Catalyst Debug 签名构建 | 通过；两端开发描述文件、CloudKit 容器和平台 APS 权限均已从实包读回 |
| iPhone 模拟器完整方案 | 23/23 通过，包含 14 个应用测试和 9 个离线/UI 流程 |
| Mac Catalyst 普通 UI 方案 | 4/4 通过，真实 Runner 覆盖三栏、右键菜单、居中删除确认、编辑取消与导出入口 |
| Production CloudKit 真实关键闭环 | 通过；实体 iPhone 新增 → Mac、Mac 修改 → iPhone、iPhone 删除墓碑 → Mac，最终清理并由全新 Mac 进程确认不存在 |
| iOS 发布签名上传包 | 通过；`1.1.0 (4)`，Apple Distribution，Production CloudKit / APS，`get-task-allow=false`，服务器地址为空；IPA SHA-256 `cc46080cbc983c129f76560e893e3a7b4683518d0f22630e0a1ca918f3bcb978` |
| Mac Catalyst 发布签名上传包 | 通过；`1.0.0 (4)`，Apple Distribution，二进制包含 `arm64` 与 `x86_64`，Production CloudKit / APS，`get-task-allow=false`，服务器地址为空；PKG SHA-256 `01b7582bcfe14cbcc86da522dcd13d081f8206573bd418584edbf2be97e95eed` |
| 包内资源 | 两端均只有各自主 `Info.plist` 与 `PrivacyInfo.xcprivacy`；隐私清单哈希与源文件一致，未发现历史移动 API 地址 |
| App Store Connect 构建处理 | 两端上传均成功，构建详情均为“已验证”；这不等于审核二进制要求通过 |

无签名构建、模拟器测试和隔离 Production 冒烟不能替代发布签名归档、系统推送验证、TestFlight 或商店审核。

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
- [x] 创建并读回 iPhone 与 Mac Catalyst 测试所需开发描述文件
- [x] 获得行动时确认后创建或绑定 `iCloud.top.qisw.birthday`，并部署 Production CloudKit Schema；代码不使用字段查询，因此自定义索引为 0
- [x] 使用生产容器完成真实 iPhone ↔ Mac 新增、修改、删除墓碑和队列收敛的关键闭环
- [x] 获得行动时确认后部署线上隐私与支持页面，并在 App Store Connect 增加 macOS 平台
- [x] 获得行动时确认后生成签名归档，核对 Payload、entitlements、描述文件与包内隐私清单
- [x] 上传 iOS 与 macOS 构建，并分别确认处理完成、构建元数据“已验证”
- [ ] 从 TestFlight 在真实 iPhone 与 Mac 安装，重复离线、同步、通知、锁定、导出和迁移验收
- [x] 展示最终构建、问卷、截图、审核说明和发布方式后，获得提交审核确认并提交
- [x] 记录 iPhone 1.1 批准、可分发和中国大陆公开接口状态
- [ ] 记录 Mac 1.0 审核中、批准、可供销售、公开页面和真实下载安装状态
- [x] 取得两个自动“二进制文件无效”事件的具体 `ITMS-` 原因：iPhone `ITMS-90111`，Mac `ITMS-90301`
- [x] 改用稳定版 macOS 26.6（`25G72`）构建环境，上传构建 4 并确认处理完成、绑定到对应版本
- [x] 重新提交 iPhone 1.1 与 Mac 1.0，并读回当前最终状态：iPhone 已批准，Mac 等待审核

任何生产 CloudKit 验证失败都会停止后续上传。`VALID`、上传完成、处理完成、TestFlight 可用、已提交审核和公开发布是不同状态，不得相互替代。

## 当前剩余项

- Apple 错误邮件已给出明确原因：iPhone `ITMS-90111`（不支持的 SDK 或 Xcode 版本），Mac `ITMS-90301`（当前不接受使用该版本 macOS 构建的应用）。原归档来自 macOS 27.0 beta 8（`26A5425a`）+ Xcode 26.6（`17F113`）+ SDK 26.5。
- 构建 4 已在稳定版 macOS 26.6（`25G72`）虚拟机中完成，两个归档均读回 `BuildMachineOSBuild=25G72`；构建 3 的测试版系统环境问题已绕开。
- Production 关键双端闭环已通过；系统推送、完整离线冲突、账号切换、通知、生物识别和 TestFlight 安装仍未验证。
- Xcode Privacy Report 尚未单独导出；包内隐私清单已经过结构、哈希和内容读回。
- iPhone 1.1 已批准、App Store Connect 已可分发，中国大陆公开接口已返回 1.1；尚未在真实设备从公开商店下载并执行安装后回归。
- Mac 1.0 当前为“等待审核”；批准、自动发布、中国大陆公开页面和真实下载安装均尚未验证。
