# Mac Catalyst 与 iCloud 本地优先实施计划

> **执行要求：** 实施时必须使用 `superpowers:executing-plans`，按任务顺序逐项完成。每项任务使用复选框跟踪；除非用户明确要求，不使用子代理。

**目标：** 在不破坏已发布 iPhone 本地数据和离线能力的前提下，为“岁时”增加默认开启、可按设备关闭的 iCloud 私有同步，并交付经过桌面化适配的 Mac Catalyst 版本。

**架构：** `BirthdayCore` 保持本地 SwiftData 为事实来源，新增与旧服务器队列隔离的 CloudKit 记录状态、合并规则和 `CKSyncEngine` 适配；应用层通过可注入的云同步协调器观察本地状态。iPhone 继续使用标签栏，Mac 使用三栏 `NavigationSplitView`。iCloud、通知和生物识别均通过平台服务封装，任何云端失败不得回滚本地保存。

**技术栈：** Swift 6、SwiftUI、SwiftData、CloudKit/`CKSyncEngine`、UserNotifications、LocalAuthentication、CryptoKit、XcodeGen、Swift Testing/XCTest、Node.js 契约测试

**设计规格：** `docs/superpowers/specs/2026-09-04-mac-catalyst-icloud-design.md`

## 全局约束

- 在 `/Users/qsw/work/project/birthday/.worktrees/ios-local-first`、`codex/ios-local-first` 分支实施；每次编辑前检查 `git status --short`。
- iPhone 最低 iOS 17，Mac Catalyst 最低 macOS 14；Mac 归档目标同时检查 `arm64` 与 `x86_64`。
- App Store Release 的 `BIRTHDAY_API_BASE_URL` 必须继续为空；不得把旧服务器同步入口重新暴露给正式版。
- CloudKit 使用用户私有数据库和专用记录区；不使用公共数据库、共享数据库或 SwiftData 自动 CloudKit。
- iCloud 开关默认开启但按设备保存；关闭同步不能删除本机或 iCloud 数据。
- 本地写入必须先成功落盘。CloudKit 超时、配额、账号和权限错误不得改写本地保存结果。
- 旧 `SyncOperationEntity`、服务器游标和历史冲突记录必须在 V3 迁移中保留，CloudKit 不得复用服务器队列。
- 不重生成现有固定迁移夹具。新增 V2 夹具时使用冻结的 V2 类型和一次性生成说明，提交后禁止由 V3 当前模型覆盖。
- 不记录姓名、生日、CloudKit 正文、同步令牌或完整 iCloud 用户标识。
- 不增加第三方运行时依赖；XcodeGen 仍是工程定义的唯一来源，不手工提交生成的 `.xcodeproj`。
- 所有用户文案使用简体中文，并保持“现代空气感”、日历优先和原生分组表单。
- 每个实现任务遵循红—绿—重构：先写失败测试并观察预期失败，再写最小实现，再运行定向与相关回归测试。
- 每项任务只提交列出的相关文件，保留任何无关工作区修改。
- 创建 CloudKit 生产 Schema、修改线上页面、创建发布证书、上传构建和提交审核前都必须再次获得明确授权。

## 计划文件结构

### 核心与同步

- `ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdaySchemaV3Models.swift`：V3 SwiftData 模型和 CloudKit 本地状态实体。
- `ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayModelContainer.swift`：V2 → V3 迁移计划。
- `ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayStore+Cloud.swift`：云同步所需的原子查询、待发送标记和远端合并。
- `ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudBirthdaySnapshot.swift`：不包含服务器和派生字段的云端数据契约。
- `ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudRecordCodec.swift`：`CKRecord`、UUID 和系统字段编解码。
- `ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudMergePolicy.swift`：本地、基础和远端三方合并决策。
- `ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudSyncEngineAdapter.swift`：`CKSyncEngine` 事件桥接。
- `ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudSyncCoordinator.swift`：开关、账号、触发、状态和重试编排。
- `ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudAccountMarkerStore.swift`：不可逆账号标记的 Keychain 存储。
- `ios/BirthdayCore/Sources/BirthdayCore/Export/BirthdayExportService.swift`：本机可见生日的版本化 JSON 导出。

### 应用与界面

- `ios/BirthdayMobile/App/PlatformServices.swift`：UIKit/Catalyst 差异和用户可见平台名称。
- `ios/BirthdayMobile/App/BirthdayMobileApp.swift`：双平台根界面、命令和云同步生命周期。
- `ios/BirthdayMobile/App/AppModel.swift`：iCloud 状态、冲突和设备级开关。
- `ios/BirthdayMobile/App/ProductionAppModelFactory.swift`：Release CloudKit 组装与测试注入。
- `ios/BirthdayMobile/Sync/CloudSyncRuntime.swift`：scene、网络和远程变更触发。
- `ios/BirthdayMobile/Features/Desktop/MacRootView.swift`：Mac 三栏根界面。
- `ios/BirthdayMobile/Features/Desktop/BirthdayDetailView.swift`：桌面详情栏。
- `ios/BirthdayMobile/Features/Desktop/MacCommands.swift`：菜单和快捷键。
- `ios/BirthdayMobile/Features/Settings/ICloudSyncSettingsView.swift`：同步开关、状态、账号变化和手动同步。
- `ios/BirthdayMobile/Features/Settings/DataExportView.swift`：系统文件导出界面。
- `ios/BirthdayMobile/Config/*.entitlements`：iCloud、CloudKit、远程通知和 Mac 沙盒能力。

### 验证与发布材料

- `ios/BirthdayCore/Tests/BirthdayCoreTests/Cloud*Tests.swift`：迁移、编解码、合并、引擎和账号测试。
- `ios/BirthdayMobileTests/*Tests.swift`：运行时、平台、通知和命令测试。
- `ios/BirthdayMobileUITests/ICloudAndMacFlowUITests.swift`：iPhone/Mac 用户路径。
- `tests/contracts/macosAndCloudKitAssets.test.js`：工程、权限、隐私和元数据契约。
- `ios/AppStore/metadata/zh-Hans.json`：iOS 1.1 元数据。
- `ios/AppStore/metadata/macos-zh-Hans.json`：macOS 1.0 元数据。
- `ios/QA/ICLOUD_MAC_ACCEPTANCE.md`：真实双端验收记录。
- `ios/QA/MAC_APP_STORE_RELEASE.md`：生产发布与状态边界清单。

## 开始前基线

在 Task 1 前运行：

`git worktree list`

`git status --short`

`npm test`

`npm run test:mobile`

`node --test tests/contracts/appStoreAssets.test.js tests/contracts/iosPrivacyManifest.test.js`

`cd ios/BirthdayCore && swift test`

`cd ../ && xcodegen generate`

`xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

预期：当前 iOS 1.0 基线全部通过且工作区没有无关修改。若存在基线失败，先按 `superpowers:systematic-debugging` 查明原因，不把旧失败混入本计划实现。

---

## Task 1：锁定双平台工程与权限契约

**文件：**

- 新建：`tests/contracts/macosAndCloudKitAssets.test.js`
- 新建：`ios/BirthdayMobile/Config/BirthdayMobile.entitlements`
- 新建：`ios/BirthdayMobile/Config/BirthdayMac.entitlements`
- 修改：`ios/project.yml`
- 修改：`ios/BirthdayMobile/Info.plist`
- 修改：`ios/BirthdayMobile/Config/Release.xcconfig`

**产出接口：** iOS `BirthdayMobile` 与独立 `BirthdayMac` Catalyst scheme；计划容器标识 `iCloud.top.qisw.birthday`；Release 仍无自有服务器 URL。

- [x] **Step 1：写失败的工程契约测试**

测试必须断言：

- 存在独立 `BirthdayMac` 目标，开启 Mac Catalyst，并显式关闭“Designed for iPhone/iPad on Mac”替代路线。
- iOS 与 Mac 目标使用同一 `top.qisw.birthday` Bundle ID。
- 两个目标分别引用自己的 entitlements。
- entitlements 只声明计划中的 CloudKit 容器、CloudKit 服务及必要沙盒能力。
- `Info.plist` 声明 CloudKit 远程变更所需后台模式。
- Release `BIRTHDAY_API_BASE_URL` 仍为空且不包含 HTTP 地址。

运行：`node --test tests/contracts/macosAndCloudKitAssets.test.js`
预期：FAIL，提示 Mac 目标或 entitlements 尚不存在。

- [x] **Step 2：在 XcodeGen 中增加 Mac Catalyst 目标**

保持现有 iOS 目标不变，新增共享 `BirthdayMobile` 源码和 `BirthdayCore` 包的 `BirthdayMac` 目标。设置同一 Bundle ID、macOS 14 最低版本、独立 Info/entitlements 路径、`SUPPORTS_MACCATALYST=YES` 与不派生新 Bundle ID。不要手工编辑生成工程。

- [x] **Step 3：增加 CloudKit 和远程通知声明**

将容器标识集中在 xcconfig 或 XcodeGen 设置中。不得硬编码 `aps-environment`；由签名配置注入。Mac entitlements 同时启用 App Sandbox，但不增加文件、网络服务器或下载目录等无关权限。

- [x] **Step 4：生成工程并验证无签名编译入口**

运行：

`cd ios && xcodegen generate`

`xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

`xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMac -destination 'platform=macOS,variant=Mac Catalyst' build CODE_SIGNING_ALLOWED=NO`

预期：工程生成成功；若现有 UIKit 代码导致 Catalyst 编译失败，只记录精确失败位置，本任务可加入最小条件编译垫片，但不开始桌面 UI 重写。

- [x] **Step 5：运行契约测试并提交**

运行：`node --test tests/contracts/macosAndCloudKitAssets.test.js`
预期：PASS。

提交：`feat(apple): 建立 iOS 与 Mac Catalyst 双平台目标`

---

## Task 2：增加 V3 数据模型并证明老数据可迁移

**文件：**

- 新建：`ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdaySchemaV3Models.swift`
- 新建：`ios/BirthdayCore/Tests/BirthdayCoreTests/Fixtures/v2-pre-cloud.store`
- 新建或修改：`ios/BirthdayCore/Tests/BirthdayCoreTests/Fixtures/README.md`
- 修改：`ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayEntity.swift`
- 修改：`ios/BirthdayCore/Sources/BirthdayCore/Data/SyncOperationEntity.swift`
- 修改：`ios/BirthdayCore/Sources/BirthdayCore/Data/SyncMetadataEntity.swift`
- 修改：`ios/BirthdayCore/Sources/BirthdayCore/Data/SyncConflictEntity.swift`
- 修改：`ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayModelContainer.swift`
- 修改：`ios/BirthdayCore/Tests/BirthdayCoreTests/BirthdayModelContainerMigrationTests.swift`

**新增实体：**

- `CloudRecordStateEntity`：`entityId`、基础快照、编码后的 CloudKit 系统字段、`needsUpload`、最近 mutation ID 和错误类别。
- `CloudSyncEngineStateEntity`：单例 key、引擎序列化状态、初始合并状态和最近成功拉取时间。
- `CloudSyncConflictEntity`：实体 UUID、本机快照、iCloud 快照、冲突类型和时间。

- [x] **Step 1：固定 V2 前云端夹具并写失败迁移测试**

夹具至少包含一条有效生日、一条墓碑、一个待服务器操作、服务器游标和一个服务器冲突。测试打开夹具并断言 V3 迁移后所有旧数据不变，同时新的 CloudKit 表为空。

先运行：`cd ios/BirthdayCore && swift test --filter BirthdayModelContainerMigrationTests`
预期：FAIL，因为 V3 schema 和新实体不存在。

- [x] **Step 2：保留 V1/V2 类型并新增 V3 类型**

不要改变历史 schema 的模型声明。将公开 typealias 切换到 V3，对 V3 复制现有字段并加入三类 CloudKit 独立实体。新增字段必须可轻量迁移或提供默认值。

- [x] **Step 3：增加 V2 → V3 迁移阶段**

`BirthdaySchemaMigrationPlan` 顺序固定为 V1、V2、V3；使用轻量迁移，不在迁移阶段访问 CloudKit。

- [x] **Step 4：验证夹具和现有数据层**

运行：

`swift test --filter BirthdayModelContainerMigrationTests`

`swift test --filter BirthdayStoreTests`

预期：迁移、CRUD、墓碑、服务器 outbox 和游标测试全部 PASS。

- [x] **Step 5：提交**

提交：`feat(data): 增加 CloudKit V3 本地状态模型`

---

## Task 3：定义 CloudKit 快照与 CKRecord 编解码

**文件：**

- 新建：`ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudBirthdaySnapshot.swift`
- 新建：`ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudRecordCodec.swift`
- 新建：`ios/BirthdayCore/Tests/BirthdayCoreTests/CloudRecordCodecTests.swift`

**接口：**

- `CloudBirthdaySnapshot.init(record:)`
- `CloudRecordCodec.encode(snapshot:systemFields:)`
- `CloudRecordCodec.decode(record:)`
- 固定 record type `Birthday`、zone `BirthdayZone`、record name 为小写 UUID 字符串。

- [x] **Step 1：写失败的字段白名单测试**

验证往返编解码姓名、农历、提醒规则、创建/修改/删除时间；断言 `nextSolarDate`、服务器版本、邮件字段、通知权限和同步内部状态不进入 `CKRecord`。

同时测试：错误 record type、错误 zone、非法 UUID、缺字段、未知 schema 版本和非法农历值均拒绝。

运行：`swift test --filter CloudRecordCodecTests`
预期：FAIL，类型不存在。

- [x] **Step 2：实现版本化快照和严格 codec**

CloudKit 字段只接受明确类型，所有入站数据先通过 `BirthdayValidator` 或等价只读验证。系统字段使用安全归档保存，禁止把整个 `CKRecord` 以不受控对象图写入业务快照。

- [x] **Step 3：验证并提交**

运行：`swift test --filter CloudRecordCodecTests`
预期：PASS。

提交：`feat(icloud): 定义生日 CloudKit 记录契约`

---

## Task 4：实现三方合并和冲突判定

**文件：**

- 新建：`ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudMergePolicy.swift`
- 新建：`ios/BirthdayCore/Tests/BirthdayCoreTests/CloudMergePolicyTests.swift`

**接口：**

`CloudMergePolicy.decide(base:local:remote:)` 返回：

- `acceptLocal`
- `acceptRemote`
- `unchanged`
- `conflict(kind:)`

- [x] **Step 1：写失败的纯函数矩阵测试**

覆盖：

- 只有本机改变
- 只有 iCloud 改变
- 双方内容相同
- 双方同时编辑
- 本机删除 / 远端编辑
- 本机编辑 / 远端删除
- 双方删除
- 没有共同基础的首次合并
- 同名但 UUID 不同不得合并

运行：`swift test --filter CloudMergePolicyTests`
预期：FAIL。

- [x] **Step 2：实现内容比较**

比较只使用可同步字段；`updatedAt` 用于展示和诊断，不单独作为覆盖依据。存在共同基础时按三方差异判断；没有基础且同 UUID 两边均存在不同内容时生成冲突。

- [x] **Step 3：验证并提交**

提交：`feat(icloud): 实现无静默覆盖的合并策略`

---

## Task 5：实现 CloudKit 本地事务和待发送状态

**文件：**

- 新建：`ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayStore+Cloud.swift`
- 新建：`ios/BirthdayCore/Tests/BirthdayCoreTests/CloudSyncStoreTests.swift`
- 修改：`ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayStore.swift`

**接口：**

- `bootstrapCloudState()`
- `pendingCloudChanges(limit:)`
- `applyRemoteCloudChanges(_:now:timeZone:)`
- `markCloudUploadSucceeded(_:)`
- `recordCloudUploadFailure(_:category:)`
- `persistCloudEngineState(_:)`
- `cloudConflicts()` 与两种解决动作

- [x] **Step 1：写失败的原子性测试**

验证：

- V2 迁移来的活动生日和墓碑首次启动均标记待上传。
- 新增、编辑、软删除和恢复在同一事务中更新生日与 Cloud 状态。
- 关闭 iCloud 时本地修改仍标记待发送。
- 远端应用不产生新的服务器 outbox 或云端回声上传。
- 远端合并后重新计算本机 `nextSolarDate`。
- 事务提交失败时生日和 Cloud 状态一起回滚。

运行：`swift test --filter CloudSyncStoreTests`
预期：FAIL。

- [x] **Step 2：在 BirthdayStore 中接入 Cloud 状态**

保持现有服务器 outbox 行为和测试不变；Cloud 状态使用独立实体和 API。通过明确的“本地用户写入”与“远端合并”入口阻止回声循环。

- [x] **Step 3：接入冲突持久化与解决**

CloudKit 冲突使用独立快照实体。可以向界面映射到共用展示结构，但不得要求服务器 operation ID 或 baseVersion。解决后只生成 CloudKit 待发送变更。

- [x] **Step 4：验证并提交**

运行：

`swift test --filter CloudSyncStoreTests`

`swift test --filter BirthdayStoreTests`

`swift test --filter ConflictResolverTests`

提交：`feat(icloud): 原子记录本地云同步变更`

---

## Task 6：封装 CKSyncEngine 事件与状态恢复

**文件：**

- 新建：`ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudSyncEngineAdapter.swift`
- 新建：`ios/BirthdayCore/Tests/BirthdayCoreTests/CloudSyncEngineAdapterTests.swift`

**接口：**

- `CloudSyncEngineClient`：可启动、暂停、发送、拉取和关闭的测试协议。
- `SystemCloudSyncEngineAdapter`：唯一真实 `CKSyncEngine` 实现。
- `CloudSyncEngineEvent`：状态更新、待发送请求、远端变更、删除、部分失败和账号错误。

- [x] **Step 1：写失败的事件适配测试**

用假的事件源验证：引擎状态每次更新都持久化；待发送记录来自本地仓库；远端批次事务化应用；重复事件幂等；部分失败只重排失败项；取消不显示为永久失败。

- [x] **Step 2：实现专用私有数据库记录区**

只创建一个指向用户私有数据库和 `BirthdayZone` 的引擎实例。恢复持久化 state serialization；状态无效时安全清除引擎状态并重新枚举，不删除业务数据。

- [x] **Step 3：分类 CloudKit 错误**

至少区分：离线、未登录、账号受限、配额不足、限流、服务不可用、记录冲突、权限或容器配置错误。保存错误类别，不保存 CloudKit 正文。

- [x] **Step 4：验证并提交**

运行：`swift test --filter CloudSyncEngineAdapterTests`
提交：`feat(icloud): 接入可恢复的 CKSyncEngine 适配器`

---

## Task 7：实现默认开启、开关和账号变化协调器

**文件：**

- 新建：`ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudSyncCoordinator.swift`
- 新建：`ios/BirthdayCore/Sources/BirthdayCore/Cloud/CloudAccountMarkerStore.swift`
- 新建：`ios/BirthdayCore/Tests/BirthdayCoreTests/CloudSyncCoordinatorTests.swift`
- 新建：`ios/BirthdayCore/Tests/BirthdayCoreTests/CloudAccountMarkerStoreTests.swift`

**接口：**

- `CloudSyncPreferenceStore`：无存量键时返回开启，显式关闭后持久保持关闭。
- `CloudAccountMarkerStore`：将账号 record name 经过 CryptoKit 哈希后存入 Keychain。
- `CloudSyncCoordinator`：`start`、`setEnabled`、`requestSync`、`confirmAccountChange`、`cancelAccountChange`。

- [x] **Step 1：写失败的状态机测试**

覆盖首次默认开启、关闭不删数据、关闭期间累积修改、重新开启增量恢复、无 iCloud 降级、配额错误、限流退避、账号退出和账号切换暂停上传。

- [x] **Step 2：实现账号保护**

首次账号建立不可逆标记。账号变化后只允许读取状态，不允许上传；用户确认后重置该账号对应的引擎 state、进行安全初始合并，再允许上传。取消后保持本地模式。

- [x] **Step 3：定义用户状态快照**

输出 `disabled`、`unavailable`、`syncing`、`pending(count:)`、`synchronized(date:)`、`accountChangeRequiresConfirmation`、`conflicts(count:)` 和 `failed(category:)`。

- [x] **Step 4：验证并提交**

运行：

`swift test --filter CloudSyncCoordinatorTests`

`swift test --filter CloudAccountMarkerStoreTests`

提交：`feat(icloud): 编排默认同步与账号切换保护`

---

## Task 8：完成平台服务、通知开关和应用锁语义

**文件：**

- 新建：`ios/BirthdayMobile/App/PlatformServices.swift`
- 新建：`ios/BirthdayMobileTests/PlatformServicesTests.swift`
- 修改：`ios/BirthdayCore/Sources/BirthdayCore/Security/AppLockService.swift`
- 修改：`ios/BirthdayCore/Tests/BirthdayCoreTests/AppLockServiceTests.swift`
- 修改：`ios/BirthdayMobile/App/AppModel.swift`
- 修改：`ios/BirthdayMobile/App/BirthdayMobileApp.swift`
- 修改：`ios/BirthdayMobile/Features/Lock/AppLockView.swift`
- 修改：`ios/BirthdayMobile/Features/Settings/SettingsView.swift`

- [x] **Step 1：写失败的平台语义测试**

验证 iPhone 显示 Face ID/设备密码，Mac Catalyst 显示 Touch ID/登录密码；系统设置 URL 和设备名称通过平台服务返回；普通 Mac 焦点切换不锁定，系统锁屏、休眠和重新打开触发锁定。

- [x] **Step 2：扩展生物识别能力**

将当前只区分 Face ID/设备密码的模型扩展为 Face ID、Touch ID、设备凭据和不可用，保持旧测试语义兼容。所有用户文案由平台能力生成，不在业务模型中硬编码“iPhone”。

- [x] **Step 3：增加设备级通知开关**

通知开关使用独立 UserDefaults 键且不进入 iCloud。关闭后只移除本应用命名空间下的生日通知；重新开启时按本地数据重建，不等待同步。

- [x] **Step 4：验证并提交**

运行：

`cd ios/BirthdayCore && swift test --filter AppLockServiceTests`

`cd ../ && xcodegen generate`

先用 `xcrun simctl list devices available` 选择当前已安装的模拟器 UDID，再运行：

`xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobileTests -destination 'platform=iOS Simulator,id=<实际 UDID>' test CODE_SIGNING_ALLOWED=NO`

提交：`feat(apple): 统一双平台锁定与通知设置`

---

## Task 9：把 iCloud 运行时接入 AppModel 和设置页

**文件：**

- 新建：`ios/BirthdayMobile/Sync/CloudSyncRuntime.swift`
- 新建：`ios/BirthdayMobile/Features/Settings/ICloudSyncSettingsView.swift`
- 新建：`ios/BirthdayMobileTests/CloudAppCompositionTests.swift`
- 修改：`ios/BirthdayMobile/App/AppModel.swift`
- 修改：`ios/BirthdayMobile/App/ProductionAppModelFactory.swift`
- 修改：`ios/BirthdayMobile/App/BirthdayMobileApp.swift`
- 修改：`ios/BirthdayMobile/Features/Onboarding/OnboardingView.swift`
- 修改：`ios/BirthdayMobile/Features/Settings/SettingsView.swift`
- 修改：`ios/BirthdayMobile/Features/Conflicts/ConflictListView.swift`
- 修改：`ios/BirthdayMobileUITests/OfflineFlowUITests.swift`

- [x] **Step 1：写失败的组装与 UI 测试**

注入 fake CloudKit，不访问真实网络。验证 Release 组装选择 CloudKit 且不构造服务器 client；首次没有设置时同步默认开启；引导说明本机优先与 iCloud；设置可以关闭、重开、手动刷新和处理账号变化。

- [x] **Step 2：定义单一正式同步模式**

在 `AppConfiguration` 或组装层明确区分 `cloudKit`、`legacyServer` 和 `none`。App Store Release 固定 `cloudKit`；有 Debug API 地址时保留旧服务器诊断路径，但不得同时启动两套同步运行时。

- [x] **Step 3：接入 scene 生命周期**

应用启动先打开本地数据库和界面，再异步启动 CloudKit。前台、网络恢复和 CloudKit 远程变更可触发同步；后台调度只作增强。同步合并后统一 reload 并重建本地提醒。

- [x] **Step 4：更新设置与冲突界面**

替换“仅保存在此 iPhone”文案。设置页展示明确状态、设备级开关、手动刷新和账号变化确认。冲突页支持 CloudKit 快照，不显示服务器版本和邮件字段。

- [x] **Step 5：验证并提交**

运行：

`cd ios/BirthdayCore && swift test`

`cd ../ && xcodegen generate`

使用前一步确认存在的模拟器 UDID 运行 `BirthdayMobileTests`，不得假设固定机型名称。

提交：`feat(icloud): 在应用中启用默认私有同步`

---

## Task 10：实现正式 Mac 三栏界面与桌面命令

**文件：**

- 新建：`ios/BirthdayMobile/Features/Desktop/MacRootView.swift`
- 新建：`ios/BirthdayMobile/Features/Desktop/BirthdayDetailView.swift`
- 新建：`ios/BirthdayMobile/Features/Desktop/MacCommands.swift`
- 新建：`ios/BirthdayMobileTests/MacNavigationTests.swift`
- 新建：`ios/BirthdayMobileUITests/ICloudAndMacFlowUITests.swift`
- 修改：`ios/BirthdayMobile/App/BirthdayMobileApp.swift`
- 修改：`ios/BirthdayMobile/App/AppModel.swift`
- 修改：`ios/BirthdayMobile/Features/Calendar/CalendarHomeView.swift`
- 修改：`ios/BirthdayMobile/Features/Birthdays/BirthdayListView.swift`
- 修改：`ios/BirthdayMobile/Features/Birthdays/BirthdayEditorView.swift`
- 修改：`ios/BirthdayMobile/Design/ModernAirTheme.swift`

- [x] **Step 1：写失败的导航和命令测试**

使用纯状态 reducer 验证侧边栏选择、窄窗口详情收起、`Command-N`、`Command-F`、`Command-,`、Delete 和双击编辑路由。UI 测试验证三栏标识、工具栏、右键菜单和删除确认。

- [x] **Step 2：按平台选择根界面**

`targetEnvironment(macCatalyst)` 使用 `MacRootView`，iPhone 继续使用现有 `RootTabView`。Mac 默认 1080 × 720、最小 820 × 600，只建立一个主窗口。

- [x] **Step 3：实现三栏和自适应详情**

侧边栏为日历、全部生日、设置和条件出现的冲突。主栏复用日历/列表业务视图，详情栏展示选中记录。窗口变窄时先隐藏详情，不压坏七列日历。

- [x] **Step 4：完成桌面输入与视觉**

加入菜单命令、键盘焦点、悬停、双击和右键。编辑器在 Mac 使用有最小/理想尺寸的居中表单；iPhone 保持 sheet。主题颜色通过平台适配，不让共享源码无条件依赖错误的平台框架。

- [x] **Step 5：双平台构建和提交**

运行：

`xcodebuild -project ios/BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

`xcodebuild -project ios/BirthdayMobile.xcodeproj -scheme BirthdayMac -destination 'platform=macOS,variant=Mac Catalyst' build CODE_SIGNING_ALLOWED=NO`

提交：`feat(mac): 增加日历优先的桌面三栏体验`

---

## Task 11：增加本机生日数据导出

**文件：**

- 新建：`ios/BirthdayCore/Sources/BirthdayCore/Export/BirthdayExportService.swift`
- 新建：`ios/BirthdayCore/Tests/BirthdayCoreTests/BirthdayExportServiceTests.swift`
- 新建：`ios/BirthdayMobile/Features/Settings/DataExportView.swift`
- 修改：`ios/BirthdayMobile/Features/Settings/SettingsView.swift`
- 修改：`ios/BirthdayMobileUITests/ICloudAndMacFlowUITests.swift`

**导出格式：** UTF-8 JSON，包含格式版本、导出时间和所有本机可见的未删除生日。

- [x] **Step 1：写失败的导出契约测试**

验证稳定排序、日期编码、农历和提醒字段；断言不含服务器令牌、版本、CloudKit 系统字段、账号标记、冲突快照、通知权限、已删除记录和隐藏邮件字段。

- [x] **Step 2：实现纯导出服务**

导出只查询本地数据库，不先请求同步。文件名使用 `岁时-生日数据-YYYY-MM-DD.json`，同日重复由系统保存面板处理。

- [x] **Step 3：接入系统文件导出**

iPhone 使用系统分享/文件面板，Mac 使用系统保存面板。取消不显示错误，写入失败保留可重试提示。

- [x] **Step 4：验证并提交**

运行：`cd ios/BirthdayCore && swift test --filter BirthdayExportServiceTests`
提交：`feat(data): 支持导出本机生日资料`

---

## Task 12：更新隐私、商店元数据与契约

**文件：**

- 修改：`ios/BirthdayMobile/PrivacyInfo.xcprivacy`
- 修改：`public/privacy.html`
- 修改：`public/support.html`
- 修改：`ios/AppStore/metadata/zh-Hans.json`
- 新建：`ios/AppStore/metadata/macos-zh-Hans.json`
- 修改：`tests/contracts/iosPrivacyManifest.test.js`
- 修改：`tests/contracts/appStoreAssets.test.js`
- 修改：`tests/contracts/macosAndCloudKitAssets.test.js`

- [ ] **Step 1：先让旧契约对新事实失败**

更新测试预期：

- 不再断言“没有后台同步权限”或“没有多设备同步”。
- 继续断言 Release 无自有服务器 URL、无广告/分析 SDK、无跟踪。
- 隐私政策必须说明本机优先、CloudKit 私有同步、默认开启、关闭方式、账号变化保护和数据导出。
- iOS 与 Mac 元数据必须与实际功能一致，不宣传实时同步。

运行：`node --test tests/contracts/iosPrivacyManifest.test.js tests/contracts/appStoreAssets.test.js tests/contracts/macosAndCloudKitAssets.test.js`
预期：FAIL，指出旧隐私和元数据内容。

- [ ] **Step 2：依据当前 Apple 规则完成隐私判断**

生成 Xcode Privacy Report，并记录 CloudKit 数据由 Apple 服务处理、开发者不接收私有记录正文的实际边界。只有证据支持时才保留 `NSPrivacyCollectedDataTypes=[]`；如果最终实现使开发者或第三方可持续访问任何数据，必须在 manifest 和 App Store Connect 问卷中申报对应类型、关联性和 App Functionality 用途。

- [ ] **Step 3：更新本地材料**

修改公开页面源文件和商店 JSON 草稿，但本任务不部署网页、不写 App Store Connect。Mac 描述突出桌面窗口、键鼠和离线能力，iOS 1.1 `whatsNew` 说明 iCloud 可关闭。

- [ ] **Step 4：验证并提交**

运行：

`npm test`

`node --test tests/contracts/iosPrivacyManifest.test.js tests/contracts/appStoreAssets.test.js tests/contracts/macosAndCloudKitAssets.test.js`

提交：`docs(appstore): 对齐 iCloud 与 Mac 隐私材料`

---

## Task 13：完成自动化回归和真实设备验收清单

**文件：**

- 新建：`ios/QA/ICLOUD_MAC_ACCEPTANCE.md`
- 修改：相关测试文件，仅限修复本任务发现的问题

- [ ] **Step 1：运行全量核心和服务回归**

运行：

`npm test`

`npm run test:mobile`

`node --test tests/contracts/appStoreAssets.test.js tests/contracts/iosPrivacyManifest.test.js tests/contracts/macosAndCloudKitAssets.test.js`

`cd ios/BirthdayCore && swift test`

`swift test --filter BirthdayModelContainerMigrationTests`

- [ ] **Step 2：运行双平台构建与测试**

运行：

`cd ios && xcodegen generate`

`xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

`xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMac -destination 'platform=macOS,variant=Mac Catalyst' build CODE_SIGNING_ALLOWED=NO`

在已安装的模拟器型号上分别运行应用单元测试和 UI 测试；不要把不存在的固定设备名称写成唯一入口。

- [ ] **Step 3：在 CloudKit 开发环境完成真实双端矩阵**

使用虚构测试数据和同一测试 Apple ID，记录：

- iPhone 新增 → Mac 到达
- Mac 修改 → iPhone 到达
- 两端离线修改 → 冲突保留双方
- 删除墓碑不复活
- 关闭同步后本地继续使用
- 重新开启后增量合并
- 退出 iCloud、空间不足模拟和账号切换保护
- 两端本地通知与生物识别

真实设备未完成的项目必须标为“未验证”，不能用单元测试替代。

- [ ] **Step 4：检查架构、隐私和包内容**

检查 Mac Release 架构包含计划的 `arm64` 和 `x86_64`；检查应用只包含声明的 entitlements、隐私清单和资源；确认 Release 不连接 `qisw.top/api/mobile`。

- [ ] **Step 5：提交验收文档**

提交：`test(apple): 记录 iCloud 与 Mac 双端验收`

---

## Task 14：准备并执行受控 App Store 发布

**文件：**

- 新建：`ios/QA/MAC_APP_STORE_RELEASE.md`
- 修改：`ios/project.yml` 中最终版本/构建号
- 新建：Mac App Store 截图输出目录和经验证的虚构数据截图
- 修改：发布证据文件，仅记录非敏感 ID、状态和时间

本任务分为准备段和外部动作段。准备段可以执行；每组外部动作必须在行动时重新确认。

- [ ] **Step 1：生成发布清单和本地候选**

确认 iOS 1.1 与 macOS 1.0 的版本/构建号未冲突，生成 Release 构建、隔离 UI 截图和审核说明草稿。验证所有截图无真实姓名、生日、邮箱或账号。

- [ ] **Step 2：请求生产 CloudKit 授权**

获得确认后才创建/绑定 `iCloud.top.qisw.birthday`、部署生产 Schema 和索引。部署后用生产容器进行一次真实 iPhone/Mac 双端验证；失败时停止，不上传构建。

- [ ] **Step 3：请求线上材料与 App Store 平台授权**

获得确认后才部署 `public/privacy.html`、`public/support.html`，并在现有 App Store Connect 应用中增加 macOS 平台。读回线上页面和平台记录验证结果。

- [ ] **Step 4：请求签名、归档和上传授权**

获得确认后才创建或调整证书/描述文件、执行正式归档和上传。上传后分别核对 iOS 与 macOS 构建的处理状态；`VALID` 或“处理完成”不等于 TestFlight 可用或已提交审核。

- [ ] **Step 5：TestFlight 真机安装**

从 TestFlight 在真实 iPhone 和 Mac 安装上传构建，重复离线、同步、通知、锁定、导出和升级迁移的发布候选验收。

- [ ] **Step 6：请求提交审核授权**

展示最终构建号、隐私问卷、截图、审核说明和发布方式。用户明确确认后才选择构建并提交。自动或手动发布在此时单独选择，不沿用 iOS 1.0 的历史设置。

- [ ] **Step 7：验证发布状态**

分别记录：已上传、处理完成、TestFlight 可用、已提交、等待审核、审核中、已批准、可供销售、公开页面可访问、真实下载安装。只有中国大陆商店页面与真实设备安装均成功时，才报告“已公开发布”。

---

## 最终完成标准

- V2 → V3 固定夹具迁移与全量 Swift 测试通过。
- iPhone 与 Mac 在无网络、无 iCloud 时核心功能完整。
- 默认 iCloud、设备级关闭、重新开启、冲突和账号切换保护均通过测试。
- Mac Catalyst 三栏、键鼠、窗口、Touch ID 和辅助功能验收通过。
- 导出文件不含同步和隐藏字段。
- Privacy Report、隐私清单、公开政策、元数据和真实网络行为一致。
- CloudKit 开发与生产环境均有真实双端证据。
- 最终双平台包通过签名、架构、entitlements、隐私和 Payload 检查。
- App Store Connect 与公开商店状态按证据分别报告。
