# 截图权限反复请求：定位与验收

## 已观察到的失败

- 用户入口是启用截图快捷键后按 `⌘X`。`HotKey.captureSelection()` 只启动一次 `/usr/sbin/screencapture -d -i -s -c`；没有自动重试。
- 2026-10-03 15:42、15:47，TCC 将该子进程的屏幕权限归到 `com.whattheport.app.local.zh`，并返回 `authValue=2`（允许）。
- 16:27、16:30、16:36、16:42，同一路径返回 `authValue=0 / authReason=5`。16:59:02 对当前运行的 WhatThePort PID 59333，TCC 明确记录 `Failed to match existing code requirement … service kTCCServiceScreenCapture`。
- 安装 build 20 使用 ad-hoc 签名。其 designated requirement（系统用于识别代码的条件）只有该版本的 `cdhash`。`build-localized.sh` 最后一步硬编码 ad-hoc，覆盖了 `build-app.sh` 可配置的签名。
- 最近 17:29 的其他屏幕请求来自 `com.openai.sky.CUAService`，结果允许。它与本应用权限独立。请求日志本身不证明当时显示了弹窗。
- 直接从终端执行应用的测试 PID 3472 / 11395，将权限归到了 `com.cmuxterm.app`。这些结果不能用来证明 Finder/LaunchServices 启动的用户路径通过。

证据：`.context/screenshot-permission/screenshot-failure.log`、`tcc-attribution.log`、`signing-baseline.log`。这些文件只保存与归因相关的系统日志，没有修改权限数据库。

## Build 21 的真实验收仍失败

主代理完成既有开发证书签名、安装和 LaunchServices 重开后，用户两次 `⌘X` 仍看到权限提示。不能把签名检查通过称为截图修复通过。

- 18:04:04 的请求进程是 `screencapture` PID 15424；18:04:15 是 PID 15735。两次 responsible process 均为 WhatThePort PID 6512，subject 均为 `com.whattheport.app.local.zh`。
- 两次 `kTCCServiceScreenCapture` 实际请求均返回 `authValue=0 / authReason=5`；preflight 返回 `authValue=1 / authReason=5`。
- 两次日志明确列出旧授权 requirement `cdhash H"167c6c1349582a05ba00633a5420125b12fe966a"`，与当前 certificate+bundle requirement 不匹配。系统随后通知 `universalAccessAuthWarn`，第二次其日志确认提示窗口显示。
- 对已安装 21 执行旧 requirement 的只读 `codesign -R` 验证返回 3（不满足）；当前证书身份检查通过。检查未调用任何屏幕权限 API。

这次失败来自旧 ad-hoc 授权未更新，不是责任归到截图子进程或 CUA，也没有系统 picker bypass 提醒的证据。签名稳定性实验只能证明后续版本身份兼容，不能迁移既有授权。

证据：`.context/screenshot-permission/installed21-stale-grant.log`、`installed21-old-requirement-check.log`。下一步由主代理协调用户在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」更新当前应用的授权。若开关已开启且无法刷新旧记录，可移除该条目，再通过 `+` 添加 `/Applications/WhatThePort 中文版.app`；这仍需用户执行与实际验证，不能声称已通过。[Apple 的该设置操作说明](https://support.apple.com/en-sg/guide/mac-help/mchld6aa7d23/mac) 提供开启、关闭和添加应用的入口。本次没有更改权限或重置 TCC。

## 最小修复

保留现有截图实现。本机中文构建应继续使用同一个现有 Apple Development 证书及同一个 bundle identifier，不在 localized 最后一步切回 ad-hoc。

采用的现有证书 SHA-1：`<本机开发证书 SHA-1，见 local-signing.env>`。没有创建证书或更改信任设置。

[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) 说明 ad-hoc 的代码身份绑定具体版本，开发期隐私授权可能因此无法保留。切换到证书身份时，旧 ad-hoc 授权不一定匹配，首轮仍可能需要用户授权一次。稳定身份不等于自动获取权限。

## 签名验收（不请求屏幕权限）

先定义失败：当前安装 app 是 ad-hoc；签名后的更新版本不满足旧版本要求；测试没有真正改变二进制；bundle identifier 不正确或签名无效。

先运行的基线检查按预期失败：

```sh
cd '/Users/mahaoxuan/Desktop/AI 产品/WhatThePort 中文版'
bash scripts/check-screenshot-signing.sh '/Applications/WhatThePort 中文版.app'
```

稳定性实验通过：

```sh
bash scripts/verify-screenshot-signing-stability.sh <本机开发证书 SHA-1，见 local-signing.env>
```

脚本先验证两个 ad-hoc 版本都失败，再以现有证书签名两个不同二进制，并交叉验证它们满足对方的 designated requirement。脚本不运行探针，不注册应用，不调用截图/TCC API，只删除自己创建的临时目录。结果在 `.context/screenshot-permission/signing-stability/`。这只证明代码身份兼容，不证明用户权限或截图功能通过。

最终中文构建的只读检查：

```sh
bash scripts/check-screenshot-signing.sh WhatThePort/.build/WhatThePort.app
```

如保存了同证书的上一构建，可加上上一 app 路径以验证双向身份兼容。

## 必须补完的真实用户路径

由主代理协调用户操作；本次子任务没有安装或操作 GUI。

1. 完成最终构建和签名检查后，仅安装一次。通过 Finder/LaunchServices 启动，不直接执行 app 二进制。
2. 用户按一次 `⌘X`。如系统请求权限，用户只授权这次最终版本。按系统提示处理重新打开应用，不反复替换构建。
3. 选择一个非敏感区域。验证剪贴板包含新截图，而不是上次截图。
4. 再按 `⌘X` 并选择区域。验证无需重复授权且剪贴板更新。
5. 按 `⌘X` 后按 Esc。验证取消不改剪贴板；关闭截图快捷键后 `⌘X` 恢复由前台应用处理。

未完成这些动作前，不能宣称截图权限问题已在用户环境修复。当前避免追加弹窗的安全措施是停止工具截图与反复构建安装；如果用户仍被 `⌘X` 打断，可在本应用设置关闭该快捷键。不要重置 TCC 或扩大权限。


## 主代理整合状态

构建 21 已于 2026-10-03 安装并通过 LaunchServices 重开，旧 build20 备份保留。build-localized.sh 现在继承已有 CODE_SIGN_IDENTITY，拒绝 ad-hoc；本机 local-signing.env 已配置同一现有证书，文件不入 Git。未创建证书，未修改信任或 TCC 数据库。安装版只读签名检查通过，证据 `.context/screenshot-permission/installed21-signing.log`。

主代理停止 SnapshotRenderer 与所有工具截图。Claude 验收改用 --probe-ai-usage，不创建窗口、不请求截屏。已请求用户在最终安装版按两次 ⌘X 验证；收到结果前仅称“签名原因修复并已安装”，不称“用户截图权限已通过”。

## 最终处理（2026-10-03 18:09）

构建 21 的两次 `⌘X` 仍被拒：TCC 中的旧授权仍按 ad-hoc 时期的 cdhash 核对，固定证书不会自动迁移旧记录，用户在原记录上重新授权也不更新。处理：主代理执行 `tccutil reset ScreenCapture com.whattheport.app.local.zh`（只清本应用），用户按提示重新授权并重开应用（新 PID 37944）。用户确认之后截图不再弹窗。

经验：从 ad-hoc 签名切到固定证书后，必须对该 bundle id 重置一次 ScreenCapture 授权再授权；之后同证书的新构建会保留授权。剪贴板内容和 Esc 取消路径没有另外核对。
