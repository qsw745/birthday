# 双平台商店材料与官网更新记录

日期：2026-09-05。工作树：`codex/ios-local-first`。用户确认范围：iPhone 1.1、Mac 1.0 及截图、介绍、更新说明、官网、隐私与支持页面一起更新。

## 交付结果

- iPhone 5 张 1320 × 2868 JPEG：`ios/AppStore/Screenshots/zh-Hans/upload/`。
- Mac 5 张 2880 × 1800 JPEG：`ios/AppStore/Screenshots/macos/zh-Hans/upload/`。
- 两端简体中文元数据已更新，新 marketingURL 为 https://qisw.top/birthday/app.html。
- 新官网、隐私页、支持页及关联资源已部署并完成线上读回。
- 材料完成不代表构建已上传、提交审核或公开上架。后续发布由已有的“设计离线优先移动端”任务执行；签名与审核状态见 `MAC_APP_STORE_RELEASE.md` 及 App Store Connect 最新证据。

## 截图来源与界限

截图使用 Release 的真实 SwiftUI 界面、独立截图应用标识和内存资料。虚构姓名仅含清和、星野、望舒、知夏、小满，未读取真实用户资料。同步、通知及生物识别能力为演示注入，不作为生产同步或硬件验证证据。

截图专用源代码副本位于 `/tmp/birthday-store-refresh-20260905/capture-source/ios`。Mac 的测试认证能力在该副本中改为 Touch ID，正式产品实现未因此改写。截图渲染仅处理系统提示区域、外框、缩放、背景、阴影及标题；应用内文字和控件来自捕获画面。

材料复核发现 Release 编辑器仍显示无效的“邮件备份提醒”入口。发布任务已修复为仅在旧服务器绑定可用时显示；本任务复制修复后的编辑器源代码、重新构建并捕获两端第 3 张截图，最终图片中不再出现此入口。

- 编辑器源文件 SHA-256：`622c82f0b6b74b84c42998b5a84c166a035b1862fb66ffe737065acf70bcca24`。
- 最终 iPhone 截图测试：`/tmp/birthday-store-refresh-20260905/iphone-capture-mail-fixed.xcresult`，1/1 通过。
- Mac Release 构建：`/tmp/birthday-store-refresh-20260905/mac-capture-mail-fixed.log`，构建通过。
- 原始截图：上述临时目录的 `iphone-raw/` 与 `mac-raw/`。
- UI 居中删除、键盘取消及离线增删改验证详见 `UI_POLISH_20260905.md`。

## 官网部署与读回

公开入口：https://qisw.top/birthday/app.html 。隐私与支持仍使用 `/birthday/privacy.html`、`/birthday/support.html`。页面明确区分已有 iPhone 版本与准备发布的 iPhone 1.1 / Mac 1.0。

部署前检查运行容器、监听端口、应用目录及生日服务 Nginx 路由；备份位于服务器 `/root/birthday-backups/website-20260905T141938Z`，包含完整应用归档、Nginx 配置及通过校验的 SHA256SUMS。

仅同步以下 7 个静态文件：`app.html`、`app-site.css`、`app-assets/icon.png`、`app-assets/mac-calendar.png`、`privacy.html`、`support.html`、`legal.css`。未修改 Nginx 配置，未重启容器。

HTTPS 读回记录：`/tmp/birthday-store-refresh-20260905/website-readback.json`。7/7 均返回 200，内容类型正确，SHA-256 与本地文件一致。桌面 1440 × 1000 与手机 390 × 844 浏览器检查通过；无横向溢出，图片全部加载，隐私与支持导航可用。

## 最终验证

- 两端共 10 张最终上传图逐张视觉检查通过：画面与标题一致，无其他窗口、录屏提示、黑色透明角或真实个人资料。
- Apple 工程、素材、隐私与元数据契约 20/20 通过（2026-09-05 22:55）。
- iPhone 邮件入口修复后的截图 UI 流程 1/1 通过。
- `git diff --check` 通过。
- 文件哈希见同目录 `STORE_MATERIALS_20260905_SHA256.txt`；用于发布任务确认接收的是本次最终素材。
