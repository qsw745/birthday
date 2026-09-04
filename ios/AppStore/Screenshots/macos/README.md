# Mac App Store 截图

## 上传文件

`zh-Hans/upload/` 中的 5 张图片按文件名前缀顺序上传。每张均为 2880 × 1800、16:10、RGB、JPEG、无透明通道。

截图内容来自 `BirthdayMac` 的 Release 无签名本地构建，使用内存 SwiftData、固定时间和注入的 CloudKit 测试状态。截图数据仅包含以下虚构姓名：清和、星野、望舒、知夏、小满；不包含真实生日、邮箱、电话号码、Apple ID 或账号标识。

## 重新生成

原始窗口截图不提交到仓库。先在隔离启动参数下重新捕获 1662 × 1170 的窗口图片，并保存为以下文件：

- `01-calendar.png`
- `02-list.png`
- `03-editor.png`
- `04-settings.png`
- `05-icloud-export.png`

然后运行：

```bash
python3 ios/AppStore/Screenshots/macos/render.py <原始截图目录> ios/AppStore/Screenshots/macos/zh-Hans/upload
```

渲染器只裁去窗口上方的系统录屏提示区域、缩放真实应用画面，并增加标题、背景与阴影；不会生成或改写应用内信息。2026-09-05 已逐张完成视觉检查，并由契约测试检查文件清单、格式、色彩空间、透明通道和尺寸。
