# TouchBar Simulator

The first (open source) touchbar simulator (that I've seen) to use the new "2nd Generation" touchbar display APIs. If the other ones out there aren't working for you, this one might.  Even if the others are, this one doesn't suffer the same [bugs the others do](https://github.com/sindresorhus/touch-bar-simulator/issues/61).   

This simulator is also built the same way Apple built theirs for Xcode. Using an XPC service to render the touchbar display stream instead of the main app with the (also undocumented) ViewBridge framework. I would expect this to be pretty sturdy for at least the rest of Big Surs run.

配备实体 Touch Bar 的 Mac 现在由主应用读取实体画面，让窗口与键盘上的内容保持一致。没有实体触控栏的 Mac 仍使用原有的 XPC 模拟路径。屏幕唤醒或解锁后，应用会重建实体显示流；也可以在窗口中右键手动重连。构建方法和测试说明见 [开发文档](docs/development.md)。

这个 fork 从本仓库 `master` 单独开发，保留原有 XPC 路径，并新增状态栏菜单：浮动、置顶、置底、边距、不透明度、跨桌面显示、靠边自动隐藏和登录启动。菜单交互参考了 Sindre Sorhus 版的使用方式，但这是独立应用；原版与本仓库的代码和设置互不共用。

## 开发与 DMG 构建

Xcode 安装、Apple 芯片与 Intel 通用 DMG 构建、GitHub 下载以及睡眠唤醒测试步骤详见 [开发文档](docs/development.md)。
