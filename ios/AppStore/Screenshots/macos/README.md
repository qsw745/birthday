# Mac App Store 截图

## 上传文件

`zh-Hans/upload/` 中的 5 张图片按文件名前缀顺序上传。每张均为 2880 × 1800、16:10、RGB、JPEG、无透明通道。

截图内容来自 `BirthdayMac` 的 Release 无签名本地构建，使用内存 SwiftData、固定时间和注入的 CloudKit 测试状态。截图数据仅包含以下虚构姓名：清和、星野、望舒、知夏、小满；不包含真实生日、邮箱、电话号码、Apple ID 或账号标识。

2026-09-05 全部 5 张截图已按新界面重新捕获。设置页使用截图专用的 Touch ID 能力注入，展示 Mac 的实际文案分支；这不代表已验证真实指纹硬件或生产 iCloud 同步。编辑器截图已更新为不显示历史服务器邮件提醒入口的版本。

## 重新生成

原始窗口截图不提交到仓库。先在隔离启动参数下重新捕获 1662 × 1170 的窗口图片，并保存为以下文件：

- `01-calendar.png`
- `02-list.png`
- `03-editor.png`
- `04-settings.png`
- `05-icloud-export.png`

使用独立应用标识，并以 `-ui-testing -network-disabled -desktop-preview -cloudkit-sync` 启动。通过实际窗口编号执行 `screencapture -x -o -l<窗口编号> <输出路径>`；父窗口截图会保留附着的编辑表单。捕获后先核对画面，不使用屏幕区域截图，以免切换前台应用时混入其他窗口。

然后运行：

```bash
python3 ios/AppStore/Screenshots/macos/render.py <原始截图目录> ios/AppStore/Screenshots/macos/zh-Hans/upload
```

渲染器只裁去窗口上方的系统录屏提示区域、缩放真实应用画面，并增加标题、背景与阴影；不会生成或改写应用内信息。2026-09-05 已逐张完成视觉检查，并由契约测试检查文件清单、格式、色彩空间、透明通道和尺寸。
