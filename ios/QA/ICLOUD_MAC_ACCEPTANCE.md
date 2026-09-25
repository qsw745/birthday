# iCloud 与 Mac 双端验收记录

记录日期：2026-09-06
当前分支：`codex/ios-local-first`
范围：本地开发构建、模拟环境、开发签名读回、Production CloudKit Schema 部署、隔离 App ID 下的真实 iPhone ↔ Mac Production 关键数据闭环，以及 iPhone 1.1.0 (4) / Mac 1.0.0 (4) 在稳定版 macOS 重建、发布签名、上传和 App Store Connect 提交状态复核。

## 状态结论

- 自动化核心、服务、迁移、iPhone 应用和 UI 回归：通过。
- iOS 与 Mac Catalyst Release 无签名构建：通过。
- iPhone 与 Mac Catalyst Debug 开发签名构建：通过；两端 CloudKit 与平台 APS 权限已从实包和描述文件读回。
- Production CloudKit Schema：部署成功并从 Production 环境读回。
- Production CloudKit 真实关键闭环：通过；iPhone 新增 → Mac 下载、Mac 修改 → iPhone 下载、iPhone 删除墓碑 → Mac 删除均已验证，上传结束时待同步数为 0。
- Mac Catalyst 双架构与目标级资源检查：通过。
- Mac Catalyst 普通 UI Runner：4/4 通过。
- CloudKit 开发环境真实 iPhone ↔ Mac 双端矩阵：未验证。
- Production 系统推送、完整离线冲突/账号切换/通知/生物识别矩阵：未验证。
- iPhone 1.1.0 (4) 与 Mac 1.0.0 (4) 已在稳定版 macOS 26.6（`25G72`）虚拟机重建，在本机使用发布证书和发布描述文件导出；两端上传成功、App Store Connect 处理完成，并已分别绑定到 iOS 1.1 与 macOS 1.0 版本页。
- App Store 审核提交：构建 3 的历史提交曾在一分钟内分别因 Mac `ITMS-90301` 和 iPhone `ITMS-90111` 自动被拒。构建 4 重新提交后，iPhone 1.1 已读回“已完成审核 / 已批准”并在中国大陆 App Store 公开接口读到版本 1.1；Mac 1.0 已读回“等待审核”，未再出现“二进制文件无效”。
- 构建环境根因与处理：被拒的构建 3 来自 macOS 27.0 beta 8（`26A5425a`）+ Xcode 26.6（`17F113`）+ SDK 26.5。构建 4 已改用稳定版 macOS 26.6（`25G72`）+ 同一 Xcode/SDK 重建，解决了包元数据中的测试版系统标记。
- TestFlight 安装与设备回归：未验证。

自动化中使用的 fake CloudKit、模拟器和无签名构建不能替代真实 Apple ID、CloudKit 环境、系统推送、通知、生物识别或 TestFlight 验收。

## 自动化证据

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| `npm test` | 340/340 通过 | Node 契约、服务和冒烟回归 |
| `npm run test:mobile` | 266/266 通过 | 移动端 API 与契约回归 |
| Apple 三组契约 | 20/20 通过 | 工程、隐私、元数据、双平台版本、截图资源与生产冒烟隔离 |
| `swift test` | 334/334 通过 | BirthdayCore 本地、迁移、CloudKit 状态机、回调错误传播与导出 |
| `swift test --filter BirthdayModelContainerMigrationTests` | 5/5 通过 | 固定 V1/V2 夹具与 V3 迁移 |
| iPhone 模拟器 `BirthdayMobile` 测试方案 | 23/23 通过，0 失败、0 跳过 | iPhone 17 Pro Max、iOS 26.5；14 个应用单元测试与 9 个 UI 流程 |
| iOS Release 无签名构建 | 通过 | generic iOS Simulator；不是可提交归档 |
| Mac Catalyst Release 无签名构建 | 通过 | generic Mac Catalyst；不是可提交归档 |
| Mac Catalyst 普通 UI 方案 | 4/4 通过 | 真实 Mac Catalyst Runner；三栏、右键菜单、居中删除确认、编辑器取消和本地导出入口 |
| Production CloudKit 隔离冒烟 | 4 段真实设备流程通过 | 实体 iPhone 17 Pro Max 与本机 Mac Catalyst；只使用手动同步，不代表系统推送已验证 |

iPhone UI 流程覆盖离线新增、搜索、编辑、删除、CloudKit 引导与设置、账号变化确认、旧服务器清理失败保护和快照导入保护。测试使用内存 SwiftData、测试偏好域与注入服务，不访问真实 CloudKit。

## 本地桌面可见验收

以下项目在本机 Debug Catalyst 应用中使用虚构数据人工检查过，但不是签名/TestFlight 候选：

- [x] 宽窗口显示月历、生日列表、详情三栏
- [x] 窄窗口和设置/冲突页不会保留无关详情栏
- [x] 工具栏、Command-N、Command-F、设置命令可用
- [x] 双击生日打开编辑器
- [x] 右键菜单包含编辑与从本机删除
- [x] 设置页设备文案显示“这台 Mac”
- [x] 离线状态下可打开“导出生日数据”的系统保存面板
- [x] 取消导出不显示错误，也不写入文件

Mac Catalyst 普通 UI 自动化已实际执行并 4/4 通过。Production 关键数据闭环也已在实体 iPhone 与 Mac Catalyst 上完成；下文 Development 完整矩阵及系统推送、通知、生物识别等条目仍保持“未验证”。

## 构建与包内容检查

- [x] Mac Catalyst Release 二进制包含 `arm64` 和 `x86_64`
- [x] iPhone 包只包含主 `Info.plist` 和根目录 `PrivacyInfo.xcprivacy`
- [x] Mac 包只包含主 `Contents/Info.plist` 和 `Contents/Resources/PrivacyInfo.xcprivacy`
- [x] 已修复 iPhone 误带 `MacInfo.plist`、Mac 误带 iOS `Info.plist` 的资源污染
- [x] Release `BirthdayAPIBaseURL` 为空
- [x] SwiftData 本地配置显式使用 `.none`，不会因 CloudKit entitlement 启动 SwiftData 自动 CloudKit；业务同步仍只经过 `CKSyncEngine`
- [x] iPhone 与 Mac 二进制均不包含 `qisw.top/api/mobile` 或完整移动 API URL
- [x] Mac 动态依赖只包含 Apple 系统框架和 Swift 运行库
- [x] 源 entitlements 声明计划内 CloudKit 容器、CloudKit 服务、键值存储与平台 APS 权限；Mac 另含沙盒和网络客户端能力
- [x] iPhone 开发描述文件 UUID `165e8217-6084-4d9c-a1e4-c97dd6442f71`，实包和描述文件均读回 `aps-environment=development`
- [x] Mac Catalyst 开发描述文件 UUID `a795de68-02a8-43d1-9be5-7686037d9354`，实包和描述文件均读回 `com.apple.developer.aps-environment=development`
- [x] Production 冒烟使用独立 bundle ID `top.qisw.birthday.cloudkitsmoke`；iPhone 开发描述文件 UUID `dd1feb0c-2dfb-4402-8174-c51f0f7bd449`，Mac Catalyst 开发描述文件 UUID `d418d738-2ffe-498d-90da-5af0c021e52a`
- [x] Production 冒烟配置复用 Release 的空服务器基址，只在对应 UI 测试目标中启用，普通 Debug/Release 测试不会访问真实 Production CloudKit
- [x] 包内隐私清单读回为：不跟踪、不声明收集数据、Required Reason API 仅 UserDefaults `CA92.1`
- [x] 最终上传包的 Payload、平台架构、实际 entitlements、嵌入式发布描述文件、隐私清单、服务器空基址和历史 API 字符串均已读回；两端使用同一有效 Apple Distribution 证书，iPhone 为 `arm64`，Mac 为 `arm64 + x86_64`
- [x] 构建 4 的归档 `BuildMachineOSBuild` 均为稳定版 `25G72`；iPhone IPA SHA-256 为 `cc46080cbc983c129f76560e893e3a7b4683518d0f22630e0a1ca918f3bcb978`，Mac PKG SHA-256 为 `01b7582bcfe14cbcc86da522dcd13d081f8206573bd418584edbf2be97e95eed`
- [ ] Xcode Privacy Report 未单独导出；当前只完成包内 `PrivacyInfo.xcprivacy` 的结构、哈希和声明读回
- [ ] Release 运行时网络抓包未验证；当前仅由空服务器基址、组装测试和静态字符串检查证明不会启动历史服务器同步

## CloudKit 开发环境真实双端矩阵

测试数据必须使用虚构姓名和日期。同一测试 Apple ID 登录 iPhone 与 Mac，并先确认使用的是 Development CloudKit 环境。

| 场景 | 状态 | 需要记录的证据 |
| --- | --- | --- |
| iPhone 新增 → Mac 到达 | 未验证 | 两端时间、记录 UUID、到达状态 |
| Mac 修改 → iPhone 到达 | 未验证 | 修改字段、两端最终值、到达状态 |
| 两端离线修改同一生日 | 未验证 | 冲突列表保留双方、两种解决路径 |
| 删除墓碑不复活 | 未验证 | 离线设备上线后的删除状态 |
| 关闭同步后继续本地使用 | 未验证 | 关闭期间 CRUD、提醒与云端不变化 |
| 重新开启后增量合并 | 未验证 | 待上传数、合并结果、无重复记录 |
| 未登录 iCloud | 未验证 | 降级文案、本地 CRUD 和提醒 |
| iCloud 空间不足 | 未验证 | 错误分类、待同步修改保留 |
| iCloud 账号切换 | 未验证 | 上传暂停、确认前后行为、新账号安全合并 |
| 两端本地通知 | 未验证 | 真机/真 Mac 实际到达时间与系统设置 |
| 两端生物识别和密码回退 | 未验证 | Face ID / Touch ID / 密码实际结果 |
| 两端数据导出 | 未验证 | 文件名、JSON 内容、取消与失败处理 |

实体 iPhone 已通过 Mac 直连、配对、解锁并用于下文 Production 关键闭环。上表要求的是 Development 环境的完整异常与设备能力矩阵，本轮没有执行，不能由 Production 关键闭环或自动化替代。

## Production CloudKit 真实关键闭环

测试设备为实体 iPhone 17 Pro Max（iOS 27.0，24A5430a）和本机 Mac Catalyst（macOS 27.0），两端登录同一测试 iCloud 账号，使用 `iCloud.top.qisw.birthday` 的私有数据库及隔离 bundle ID `top.qisw.birthday.cloudkitsmoke`。

| 场景 | 结果 | 证据边界 |
| --- | --- | --- |
| iPhone 新增 → Mac 到达 | 通过 | iPhone 创建虚构记录并手动同步；全新 Mac 进程从 Production 下载成功 |
| Mac 修改 → iPhone 到达 | 通过 | Mac 将虚构记录名称由 `云端验收-68F2A` 改为 `云端验收-68F2B`；iPhone 全新进程下载到修改值 |
| iPhone 删除 → Mac 不复活 | 通过 | iPhone 上传删除墓碑；Mac 全新进程确认 A/B 两个名称均不存在 |
| 待上传队列收敛 | 通过 | 每次上传完成后诊断均为 `pending=0` 且状态为已同步 |
| 故障修复后的重新拉取 | 通过 | 修复 CloudKit 整数布尔值解码后，以全新 iPhone 进程重新下载既有 Production 记录成功 |
| 冒烟数据清理 | 通过 | 删除诊断阶段遗留的 2 条重复虚构记录并上传墓碑；全新 Mac 进程再次确认无 A/B 记录 |

本闭环通过设置页“立即同步”触发并等待本轮同步完成，只证明 Production 私有数据库的上传、下载、修改、删除墓碑和队列收敛。没有验证静默推送/系统推送触发、后台到达时延、空间不足、账号切换、离线并发冲突、通知或生物识别。

## CloudKit Schema 部署证据

- [x] 容器：`iCloud.top.qisw.birthday`
- [x] Development 与 Production 均读到 `Birthday` 记录类型
- [x] 业务字段：`schemaVersion`、`name`、`lunarMonth`、`lunarDay`、`isLeapMonth`、`reminderTimeMinutes`、`notifyDayBefore`、`notifySameDay`、`createdAt`、`updatedAt`、`deletedAt`
- [x] 类型：字符串 1 个、64 位整数 7 个、日期时间 3 个，与 `CloudRecordCodec` 白名单一致
- [x] 自定义索引：0；当前实现只通过 `CKSyncEngine` 和专用记录区增量变更，不执行字段查询
- [x] 控制台部署结果：`Changes Deployed`，并在通知中读回 Schema 已提升到 Production
- [x] Production 私有记录区的真实双端新增、下载、修改、删除墓碑和清理已验证
- [ ] Production 订阅触发与系统推送未验证，不能由手动同步成功替代

## 进入发布准备前的阻断项

- [x] 连接可用的实体 iPhone，并准备一台可运行 Catalyst 候选的 Mac
- [x] 经确认后创建并读回含 CloudKit 与 APS 权限的 iPhone/Mac Catalyst 开发描述文件
- [x] 确认 Development/Production CloudKit 容器、记录类型、字段、索引和默认安全角色
- [ ] 完成上面的真实双端矩阵并附上无敏感数据的证据
- [x] 经单独确认后部署并读回 Production CloudKit Schema
- [x] 使用 Production 容器完成新增、修改、删除墓碑和队列收敛的关键双端闭环
- [x] 生成最终签名 iOS/macOS 归档并复核 Payload、entitlements、发布描述文件与包内隐私清单
- [x] 取得 Apple 对两个“二进制文件无效”状态的具体 `ITMS-` 原因：iPhone `ITMS-90111`，Mac `ITMS-90301`
- [x] 改用 Apple 接受的稳定版 macOS 构建环境，上传构建 4 并确认 App Store Connect 处理完成
- [x] 读回构建 4 重新提交状态：iPhone 1.1 “已批准”且中国大陆公开接口已返回 1.1；Mac 1.0 “等待审核”
- [ ] 从 TestFlight 安装上传构建后重复离线、同步、通知、锁定、导出和升级迁移验收

只有实际完成并读回证据的项目才可勾选。`VALID`、构建成功、上传完成、等待审核和公开发布必须分别记录，不能互相替代。
