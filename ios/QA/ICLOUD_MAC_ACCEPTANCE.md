# iCloud 与 Mac 双端验收记录

记录日期：2026-09-05  
当前分支：`codex/ios-local-first`  
范围：本地开发构建与模拟环境。没有部署生产 CloudKit、没有创建或更新描述文件、没有上传构建、没有修改 App Store Connect。

## 状态结论

- 自动化核心、服务、迁移、iPhone 应用和 UI 回归：通过。
- iOS 与 Mac Catalyst Release 无签名构建：通过。
- Mac Catalyst 双架构与目标级资源检查：通过。
- Mac Catalyst UI 测试代码无签名编译：通过；实际 Runner 未执行。
- CloudKit 开发环境真实 iPhone ↔ Mac 双端矩阵：未验证。
- 最终签名归档、生产 CloudKit 与 TestFlight 安装：未验证。

自动化中使用的 fake CloudKit、模拟器和无签名构建不能替代真实 Apple ID、CloudKit 环境、系统推送、通知、生物识别或 TestFlight 验收。

## 自动化证据

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| `npm test` | 338/338 通过 | Node 契约、服务和冒烟回归 |
| `npm run test:mobile` | 264/264 通过 | 移动端 API 与契约回归 |
| Apple 三组契约 | 18/18 通过 | 工程、隐私、元数据、双平台版本与截图资源 |
| `swift test` | 333/333 通过 | BirthdayCore 本地、迁移、CloudKit 状态机与导出 |
| `swift test --filter BirthdayModelContainerMigrationTests` | 5/5 通过 | 固定 V1/V2 夹具与 V3 迁移 |
| iPhone 模拟器 `BirthdayMobile` 测试方案 | 22/22 通过，0 失败、0 跳过 | iPhone 17 Pro、iOS 26.5；13 个应用单元测试与 9 个 UI 流程 |
| iOS Release 无签名构建 | 通过 | generic iOS Simulator；不是可提交归档 |
| Mac Catalyst Release 无签名构建 | 通过 | generic Mac Catalyst；不是可提交归档 |
| Mac Catalyst `build-for-testing` | 通过 | UI Runner 和测试源完成编译，未实际启动 Runner |

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

Mac Catalyst 实际 UI 自动化未执行：当前没有可用于 `top.qisw.birthday` 新 CloudKit 权限的 Mac Catalyst App Development 描述文件。无签名 Runner 无法作为有效 UI 测试宿主；创建或更新描述文件属于后续签名动作，需行动时确认。

## 构建与包内容检查

- [x] Mac Catalyst Release 二进制包含 `arm64` 和 `x86_64`
- [x] iPhone 包只包含主 `Info.plist` 和根目录 `PrivacyInfo.xcprivacy`
- [x] Mac 包只包含主 `Contents/Info.plist` 和 `Contents/Resources/PrivacyInfo.xcprivacy`
- [x] 已修复 iPhone 误带 `MacInfo.plist`、Mac 误带 iOS `Info.plist` 的资源污染
- [x] Release `BirthdayAPIBaseURL` 为空
- [x] SwiftData 本地配置显式使用 `.none`，不会因 CloudKit entitlement 启动 SwiftData 自动 CloudKit；业务同步仍只经过 `CKSyncEngine`
- [x] iPhone 与 Mac 二进制均不包含 `qisw.top/api/mobile` 或完整移动 API URL
- [x] Mac 动态依赖只包含 Apple 系统框架和 Swift 运行库
- [x] 源 entitlements 仅声明计划内 CloudKit 容器、CloudKit 服务与键值存储；Mac 另含沙盒和网络客户端能力
- [x] 包内隐私清单读回为：不跟踪、不声明收集数据、Required Reason API 仅 UserDefaults `CA92.1`
- [ ] 最终签名归档的实际 entitlements、描述文件、Privacy Report 和 Payload 未验证
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

当前可见设备清单中两台 iPhone 都为 `unavailable`，本机也没有移动描述文件，因此本次没有执行真实双端矩阵。

## 进入发布准备前的阻断项

- [ ] 连接可用的实体 iPhone，并准备一台可运行 Catalyst 候选的 Mac
- [ ] 经确认后创建或更新含 CloudKit 权限的开发描述文件
- [ ] 确认 Development CloudKit 容器、记录类型、字段、索引和权限
- [ ] 完成上面的真实双端矩阵并附上无敏感数据的证据
- [ ] 经单独确认后部署 Production CloudKit Schema，再重复关键双端矩阵
- [ ] 生成最终签名 iOS/macOS 归档并复核 Payload、entitlements 和 Xcode Privacy Report
- [ ] 从 TestFlight 安装上传构建后重复离线、同步、通知、锁定、导出和升级迁移验收

只有实际完成并读回证据的项目才可勾选。`VALID`、构建成功、上传完成、等待审核和公开发布必须分别记录，不能互相替代。
