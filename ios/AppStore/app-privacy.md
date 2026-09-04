# App Store Connect 隐私问卷判断草稿

适用平台：iOS 1.1、macOS 1.0。App Store Connect 的隐私答案按 App 记录汇总，两个平台必须使用同一套最完整的实际边界。

## 结论

- 是否将数据用于跟踪：否
- 跟踪域名：无
- 是否从 App 收集数据：否
- `NSPrivacyCollectedDataTypes`：保持空数组
- Required Reason API：UserDefaults 使用 `CA92.1`，仅保存应用自身偏好

这里的“不收集数据”不是指应用永远不联网，而是指生日资料不会以开发者或其第三方合作方可持续访问的方式离开设备。App Store Release 不连接历史生日服务器，不包含广告、分析或跟踪 SDK。

## CloudKit 边界

生日、提醒设置和删除墓碑会在同步开启时发送给 Apple CloudKit，并存入用户自己的私有数据库，用于同一 Apple ID 设备间的 App 功能。Apple 负责提供和处理私有数据库服务；默认只有用户能访问私有数据库，开发者后台无法访问这些私有记录正文。

应用不使用 CloudKit 公共数据库、共享数据库或 Web 服务端访问，不保存可供运营人员查询的生日副本，也不记录姓名、生日、CloudKit 正文、同步令牌或完整 iCloud 标识。CloudKit 远程通知仅作为变化信号，不携带生日正文。

根据 Apple 当前定义，“收集”是把数据传出设备，并使开发者或其第三方合作方能在完成实时请求所需时间之外访问。由于本实现的 CloudKit 私有记录不向开发者或集成的第三方开放，当前判断仍为“不收集数据”。如果将来加入服务端 CloudKit 访问、公共/共享数据库、运营后台、远程 SDK、分析或广告，必须在发布前重新判断并更新隐私清单、问卷和政策。

## 用户控制

- iCloud 私有同步按设备默认开启，可在设置中关闭或重新开启。
- 关闭同步不会删除本机生日，也不会自动删除 iCloud 数据。
- 账号变化时先暂停上传，用户确认后才与新账号的私有数据合并。
- 设置中的“导出生日数据”会导出当时本机可见的未删除生日，不会为导出强制请求 iCloud。
- 生物识别验证由系统处理，应用不读取或保存生物识别数据。
- 用户主动发送的支持邮件由邮件应用和邮件服务商处理，不会自动附带生日资料。

## Xcode 隐私报告证据

2026-09-05 使用 Xcode 26.6 从 `BirthdayMobile` Release 本地归档生成 Xcode Privacy Report。Xcode 对当前空收集、空跟踪声明生成了不含报告条目的空 PDF；因此该 PDF 只证明聚合结果中没有可展示的收集或跟踪条目，不能单独证明运行时网络行为。

同时对归档包内 `PrivacyInfo.xcprivacy` 直接读回，确认：

- `NSPrivacyTracking = false`
- `NSPrivacyTrackingDomains = []`
- `NSPrivacyCollectedDataTypes = []`
- `NSPrivacyAccessedAPITypes` 仅包含 UserDefaults `CA92.1`

最终签名发布候选生成后必须再次生成 Xcode Privacy Report，并结合包内容、依赖、entitlements 和实际网络测试复核，再更新 App Store Connect。当前材料只是本地草稿，尚未写入线上问卷。

## Apple 依据（2026-09-05 核对）

- App 隐私的“收集”定义与数据类型：https://developer.apple.com/app-store/app-privacy-details/
- CloudKit 私有数据库的默认访问边界：https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase
- CloudKit 用户数据查看与导出要求：https://developer.apple.com/documentation/cloudkit/providing-user-access-to-cloudkit-data
- 从 Xcode 归档生成隐私报告：https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests
