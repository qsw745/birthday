# App Store Connect 隐私问卷答案

## 跟踪

- 是否将数据用于跟踪：否
- 跟踪域名：无

## 收集的数据

- 是否从 App 收集数据：否
- 生日资料、提醒设置、农历日期和应用锁偏好均在用户设备上处理，不发送给开发者。
- Face ID 由 iOS 系统处理，应用不读取或收集生物识别数据。
- App 内的支持链接会离开 App 打开公开支持页面；用户若自行发送支持邮件，该通信由邮件应用处理，不代表岁时 App 自动收集本机生日资料。

## Required Reason API

- UserDefaults：`CA92.1`，仅用于读取和写入应用自身的偏好设置。

问卷应选择“不收集数据”，并与 `BirthdayMobile/PrivacyInfo.xcprivacy` 的空 `NSPrivacyCollectedDataTypes` 保持一致。
