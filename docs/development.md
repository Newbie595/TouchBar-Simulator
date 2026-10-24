# 开发、构建与安装

## 先确认运行的是哪个程序

这份仓库来自 `jslegendre/TouchBar-Simulator`，原版 Bundle ID 是
`com.github.jslegendre.TouchBar-Simulator`；这个 fork 的构建使用独立的
`com.github.Newbie595.TouchBar-Simulator`。同名的 Sindre Sorhus 软件 Bundle ID 是
`com.sindresorhus.Touch-Bar-Simulator`；它有 Docking、Opacity、Launch at Login 等菜单，
这份仓库目前没有这些功能。改动本仓库不会改变已安装的另一款程序。

在终端检查一个 `.app` 的身份：

```bash
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "/Applications/Touch Bar Simulator.app/Contents/Info.plist"
```

安装自己构建的版本前，先退出正在运行的同名应用，确认将要替换的应用身份。

## 本机准备

1. 安装完整 Xcode。macOS 15.8.1 可使用 Xcode 26.3；请在 [Apple Developer 下载页面](https://developer.apple.com/download/all/?q=Xcode%2026.3)选择兼容版本，M1 选择 Apple silicon 版。如果历史下载列表无法打开，可使用 [Apple 官方 Xcode 26.3 Apple silicon 下载链接](https://developer.apple.com/services-account/download?path=/Developer_Tools/Xcode_26.3/Xcode_26.3_Apple_silicon.xip)，需要登录 Apple Developer。Command Line Tools 单独安装不足以构建这个 Xcode 工程。解开 `.xip` 后把 `Xcode.app` 放进 `/Applications`。
2. 首次打开 Xcode，阅读并自行接受 Xcode 与 Apple SDK 许可协议。然后完成首次配置并验证版本：

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -runFirstLaunch
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
   ```

   Xcode 26.3 的 Metal 工具链按需下载；这个项目包含 `.metal` 着色器文件，缺少它时构建会报 `missing Metal Toolchain`。

   如果要让所有终端默认使用 Xcode，而不是原有的 Command Line Tools，可再运行 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。这需要你在终端输入本机管理员密码；本项目的构建脚本会自动识别 `/Applications/Xcode.app`，无需先更改全局选择。

3. 在仓库根目录运行 `bash scripts/build-dmg.sh`。脚本会构建 `arm64` 和 `x86_64` 两个架构、临时签名、验证应用，并生成 `build/TouchBar-Simulator-universal.dmg`。DMG 内的应用叫 `TouchBar Simulator (Newbie595).app`，便于和旧版区分。

这款应用使用 macOS 私有框架 `DFRFoundation` 和 `ViewBridge`。它们可能随系统更新变化，所以编译成功不等于当前系统上能正常获取触控栏；还需要在目标 Mac 上实际测试显示、点击与睡眠唤醒。

### 实体 Touch Bar 与模拟 Touch Bar

有实体 Touch Bar 的 Mac 会在主应用进程中读取实体显示流，画面应与 `Command-Shift-6` 的硬件快照一致。原因是原先 XPC 服务创建的是另一个 `DFRTouchBarSimulator`，它可能显示不同的内容；本机 macOS 15.8.1 上，尝试在 XPC 服务内读取实体显示流还会得到全黑帧。没有实体 Touch Bar 的 Mac 继续使用原来的 XPC 模拟路径。

实体显示流启动后若首帧全黑，应用会等待有效画面并有限重试。睡眠、屏幕熄灭和会话解锁后会清除旧画面并重建流。若系统恢复较慢，可以在模拟器窗口内右键选择“重新连接 Touch Bar”，无需退出程序。

实体栏的**点击转发需要“辅助功能”权限**。如果窗口显示正常但点击没有作用，打开“系统设置 → 隐私与安全性 → 辅助功能”，允许这份 fork 构建的 `TouchBar Simulator (Newbie595).app`。它与原来安装的 Sindre Sorhus 版是两款不同应用，旧版获得的权限不会自动转给新版。授权后重新打开测试版再试。仅查看画面不需要这项权限。

本地和 CI 的测试 DMG 使用临时签名。每次修改代码再构建，签名哈希可能变化；系统设置中的开关即使显示“已开启”，旧授权也可能不再匹配新构建。如果重启后点击仍无效，先确认列表中选的是**无空格**的 `TouchBar Simulator`，将这个旧条目移除，再通过“+”添加当前正在运行的 `.app` 并开启；不要移除 Sindre 版的 `Touch Bar Simulator`。正式分发时使用自己的稳定 Developer ID 签名和公证，可避免测试版反复构建造成的授权身份变化。

## 不安装 Xcode 时从 GitHub 下载

推送分支或手动运行仓库的 **Actions → 构建 macOS DMG** 后，打开该次运行的 **Artifacts**，下载 `TouchBar-Simulator-universal`。GitHub 会先提供一个 ZIP，解压得到 DMG。CI 构建失败时不会生成可下载 DMG；请先查看构建日志。
如果 GitHub 在 fork 中提示 Actions 尚未启用，需要先在仓库的 Actions 页面启用工作流。

发布版本时，给已验证的提交创建 `v` 开头的标签，例如 `v1.2.0`。工作流会把 DMG 附加到对应的 GitHub Release。建议先用 Actions 的测试产物验证运行，再发布预发布版本供更多机器试用。

脚本使用临时 ad-hoc 签名，适合个人测试；它没有 Apple Developer ID 公证。下载后若 macOS 拦截，请在“系统设置 → 隐私与安全性”中确认自己构建并下载的应用，再按系统提示打开。公开分发若希望用户正常双击安装，需要自己的 Developer ID 证书以及 Apple notarization；不要把证书或密码提交到仓库。

## M1 与 Intel

M1 原生运行 `arm64`，Intel Mac 运行 `x86_64`。通用二进制同时包含这两个架构：同一个 DMG 可以在两类机器上使用，M1 不需要 Rosetta 翻译 Intel 代码。架构差异不会自动解决私有触控栏接口在新 macOS 上的兼容问题，唤醒后的流和远端视图仍须单独测试。

## 睡眠唤醒修复的验证

1. 先退出其他同名应用，再运行本仓库构建的版本。用 Bundle ID 确认当前程序是 `com.github.Newbie595.TouchBar-Simulator`。
2. 记下睡眠前模拟器及实体 Touch Bar 的内容，锁屏、熄屏、唤醒、解锁。
3. 切换前台应用，让 Touch Bar 内容改变；确认模拟器同步更新且点击可用。
4. 连续重复几轮，并检查“控制台”中是否出现 `Physical Touch Bar stream returned a blank first frame`、`Physical Touch Bar stream did not recover` 或 `Touch Bar view service connection failed`。若仍失败，先右键窗口尝试重新连接，并记录 macOS 版本、触发步骤、应用 Bundle ID 和相关日志。

本次恢复逻辑在实体 Touch Bar 路径上重建主进程显示流，在无实体栏的模拟路径上重建 XPC 远端视图、DFR 模拟器和显示流；在失败时有限重试，并丢弃旧帧，避免把过时的界面留在屏幕上。已在这台 M1 Mac 上完成一次真实合盖、打开、解锁测试；仍建议在不同应用和多轮睡眠后继续验证。
