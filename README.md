# WhatThePort 中文版

基于 [Tom John 的 WhatThePort](https://github.com/tomjohndesign/what-the-port) 的非官方派生版本，由 [yishu-ziyu](https://github.com/yishu-ziyu) 维护。

**当前提供中英双语的 Mac 开发服务监控；后续扩展到应用与开发服务的统一资源视图。** 应用管理扩展仍在规划，本次发行没有实现完整的应用管理功能。

[下载预发行版](https://github.com/yishu-ziyu/what-the-port/releases) · [路线图](ROADMAP.md) · [本地化说明](LOCALIZATION.md) · [原项目说明](UPSTREAM_README.md)

## 当前版本能做什么

- 在菜单栏查看开发服务的端口、项目、分支、内存和 CPU。
- 原生界面支持简体中文和 English，可跟随系统；切换后重启生效。
- 保留上游的会话关联、进程详情和清理功能，以及其他应用的内存汇总。
- 终端 `wtp` 和 JSON 输出保持英文；项目名、路径和命令保持原样。

## 开发中（`main` 分支，尚未发布）

以下改进已在源码中完成，会在下一个预发行版提供：

- 应用内存页：点击“其他应用”，查看占内存最多的 5 个应用（辅助进程已并入所属应用）、进程数，以及与开发服务的对比。只展示，不提供关闭。
- 能识别 Homebrew Python 和带版本号的 Python（如 `python3.13`）启动的服务。
- 停止 Homebrew 服务（postgres、redis 等）改用 `brew services stop` 并先确认，不会停了又被系统拉起；Homebrew 服务显示服务名，不再显示 Homebrew 自己的分支。
- 停止某个工具启动的预览服务时，不会连带停止启动它的工具。
- 应用自身 CPU 占用从约 5% 降到约 1%，不再每 2 秒启动 `lsof`。

![中文设置](docs/images/settings-zh-Hans.png)

## 安装

从本仓库 [Releases](https://github.com/yishu-ziyu/what-the-port/releases) 下载 `WhatThePort-ZH-2.5.1-arm64.zip`，解压后把 `WhatThePort 中文版.app` 移入「应用程序」。启动后点击菜单栏图标，或按 **⌥⌘P**。

本次预发行要求 **Apple Silicon、macOS 14+**。应用使用本地 ad-hoc 签名，尚未经过 Developer ID 公证；macOS 可能要求在系统设置中确认来源。当前已在开发者的 Mac 上验证，尚未完成第二台 Mac 的安装验证。

本派生版使用独立应用标识，保留自己的设置，不使用官方自动更新源。暂时通过 Releases 手动更新。下载官方原版请访问 [上游网站](https://whattheport.dev)。

## 从源码构建

```sh
cd WhatThePort
swift test --jobs 4
./build-localized.sh
```

需要 Xcode/Swift 工具链，首次构建会下载 SwiftPM 依赖。产物为 `.build/WhatThePort.app`。发布包带有相关许可文本；本仓库不包含编译缓存或应用二进制。

## 与上游协作

`feature/simplified-chinese` 分支只承载通用中文支持，供上游 PR 审查。`main` 包含本派生版的发行说明、独立应用标识和未来功能。我们会继续同步适合的上游修复，也会将通用改进回馈上游。

## 来源与许可

原项目由 Tom John 创建，上游 README 声明 MIT。原说明完整保留在 [UPSTREAM_README.md](UPSTREAM_README.md)。本仓库保留原作者署名，并在 [NOTICE.md](NOTICE.md) 列出原项目与依赖许可来源。派生修改以 MIT 许可提供；见 [LICENSE](LICENSE)。
