# iPhone App Store 截图

`zh-Hans/upload/` 中的 5 张 JPEG 按文件名前缀顺序上传，每张为 1320 × 2868、RGB、无透明通道。保留既有文件名以兼容上传清单；第 5 张内容现为私有 iCloud 同步与本机导出。

2026-09-05 截图来自 iPhone 17 Pro Max 模拟器上的 Release 构建，使用独立应用标识、内存 SwiftData、虚构姓名和注入的同步/通知/应用锁状态。启动参数为 `-ui-testing -network-disabled -desktop-preview -cloudkit-sync`。这些画面用于展示真实界面，不是生产 CloudKit 或生物识别验收证据。

使用 XCTest 打开月历、全部生日、编辑器、设置和同步导出区域，从 xcresult 导出以下 1320 × 2868 原始附件：

- `01-calendar.png`
- `02-list.png`
- `03-editor.png`
- `04-settings.png`
- `05-icloud-export.png`

然后运行：

```bash
python3 ios/AppStore/Screenshots/render-iphone.py <原始截图目录> ios/AppStore/Screenshots/zh-Hans/upload
```

渲染器完整缩放真实应用截图，仅添加外框、背景、标题与阴影，不改写应用内信息。最终编辑器截图来自邮件入口修复后的源代码。全部 5 张已完成逐张视觉检查；尺寸、文件清单、格式、色彩空间与透明通道由契约测试验证。此次原始附件和构建记录位于 `/tmp/birthday-store-refresh-20260905/`，不提交进仓库。
