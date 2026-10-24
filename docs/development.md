# 开发、构建与安装

## 先确认运行的是哪个程序

这份仓库来自 `jslegendre/TouchBar-Simulator`，Bundle ID 是
`com.github.jslegendre.TouchBar-Simulator`。同名的 Sindre Sorhus 软件 Bundle ID 是
`com.sindresorhus.Touch-Bar-Simulator`；它有 Docking、Opacity、Launch at Login 等菜单，
这份仓库目前没有这些功能。改动本仓库不会改变已安装的另一款程序。

在终端检查一个 `.app` 的身份：

```bash
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "/Applications/Touch Bar Simulator.app/Contents/Info.plist"
```

安装自己构建的版本前，先退出正在运行的同名应用，确认将要替换的应用身份。

## 本机准备

1. 安装完整 Xcode。macOS 15.8.1 可使用 Xcode 26.3；请在 [Apple Developer 下载页面](https://developer.apple.com/download/all/?q=Xcode%2026.3)选择兼容版本。Command Line Tools 单独安装不足以构建这个 Xcode 工程。
2. 安装完成后，在终端选择 Xcode 并完成首次配置：

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   xcodebuild -version
   ```

3. 在仓库根目录运行 `bash scripts/build-dmg.sh`。脚本会构建 `arm64` 和 `x86_64` 两个架构、临时签名、验证应用，并生成 `build/TouchBar-Simulator-universal.dmg`。

这款应用使用 macOS 私有框架 `DFRFoundation` 和 `ViewBridge`。它们可能随系统更新变化，所以编译成功不等于当前系统上能正常获取触控栏；还需要在目标 Mac 上实际测试显示、点击与睡眠唤醒。

## 不安装 Xcode 时从 GitHub 下载

推送分支或手动运行仓库的 **Actions → Build macOS DMG** 后，打开该次运行的 **Artifacts**，下载 `TouchBar-Simulator-universal`。GitHub 会先提供一个 ZIP，解压得到 DMG。CI 构建失败时不会生成可下载 DMG；请先查看构建日志。
如果 GitHub 在 fork 中提示 Actions 尚未启用，需要先在仓库的 Actions 页面启用工作流。

打正式版本时，给已验证的提交创建 `v` 开头的标签，例如 `v1.2.0`，并推送标签。工作流会把 DMG 附加到 GitHub Releases。建议先用 Actions 的测试产物验证运行，再创建标签。

脚本使用临时 ad-hoc 签名，适合个人测试；它没有 Apple Developer ID 公证。下载后若 macOS 拦截，请在“系统设置 → 隐私与安全性”中确认自己构建并下载的应用，再按系统提示打开。公开分发若希望用户正常双击安装，需要自己的 Developer ID 证书以及 Apple notarization；不要把证书或密码提交到仓库。

## M1 与 Intel

M1 原生运行 `arm64`，Intel Mac 运行 `x86_64`。通用二进制同时包含这两个架构：同一个 DMG 可以在两类机器上使用，M1 不需要 Rosetta 翻译 Intel 代码。架构差异不会自动解决私有触控栏接口在新 macOS 上的兼容问题，唤醒后的流和远端视图仍须单独测试。

## 睡眠唤醒修复的验证

1. 先退出其他同名应用，再运行本仓库构建的版本。
2. 记下睡眠前模拟器及实体 Touch Bar 的内容，锁屏、熄屏、唤醒、解锁。
3. 切换前台应用，让 Touch Bar 内容改变；确认模拟器同步更新且点击可用。
4. 连续重复几轮，并检查“控制台”中是否出现 `Touch Bar display stream failed to start` 或 `Touch Bar view service connection failed`。若仍失败，记录 macOS 版本、触发步骤、应用 Bundle ID 和相关日志。

本次恢复逻辑在唤醒后重建 XPC 远端视图、DFR 模拟器和显示流；在失败时有限重试，并丢弃旧帧，避免把过时的界面留在屏幕上。尚未在真实睡眠唤醒场景验证前，不能认为故障已彻底解决。
