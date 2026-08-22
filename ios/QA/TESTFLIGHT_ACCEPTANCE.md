# 首个 TestFlight 构建验收

## 本地准备

- [ ] 从 `ios/Config/Signing.xcconfig.example` 复制本地 `ios/Config/Signing.xcconfig`，只填写正确的 Apple Developer Team；确认该文件未被 Git 跟踪
- [ ] Debug and Release both build from a clean XcodeGen regeneration
- [ ] Release uses HTTPS production API URL and contains no token or password
- [ ] App icon, display name“岁时”、版本 1.0.0、构建号 1 正确
- [ ] Archive 的 bundle ID 为 `top.qisw.birthday`，仅包含 `fetch` 后台模式，未包含多余 entitlement
- [ ] Release 归档内 `BirthdayAPIBaseURL` 为审核过的 HTTPS 地址，且没有开发环境 API 值

## 真机验收（当前未验证，上传前必须人工完成）

- [ ] 真机首次启动、通知说明、Face ID 和设备密码回退通过
- [ ] 真机飞行模式完整 CRUD 与重启持久化通过
- [ ] 真机提前一天、当天和维护通知通过
- [ ] 首次服务器导入数量核对通过
- [ ] 双设备冲突与解绑不删本地数据通过
- [ ] 动态字体、VoiceOver、深色模式、减少动态效果通过
- [ ] 隐私说明仅声明实际使用的数据和网络行为

## 发布边界

- [ ] 用户已确认归档证据、Apple 账号、Team、App Store Connect App 与测试员组
- [ ] 上传后仅记录为“已提交处理”；等待 App Store Connect 完成处理并在目标测试员组可见后，才能记录为“TestFlight 可用”
