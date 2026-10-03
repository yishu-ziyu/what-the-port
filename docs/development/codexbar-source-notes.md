# CodexBar 源码阅读与迁入记录

日期：2026-10-03。阅读版本：v0.68.0。范围：CLI、配置、九个服务商的数据映射、账号缓存及原生呈现。上游源码放在本机 `.context/upstream/CodexBar-0.68.0/`；不引入整份上游工程或新的 Swift 依赖。

## 从源码追踪的真实路径

`CLIUsageCommand` 读取配置和账号选择，经 `ProviderDescriptor` 的凭据适配及查询策略得到 `UsageSnapshot`，再由 `CLIPayloads` 输出 JSON。JSON 中同时存在额度、业务标签、估算标记、额外模型窗口及服务明细。WhatThePort 继续复用独立打包的 CLI；新应用只实现自己的配置、状态和轻量 UI。

- [查询入口](https://github.com/steipete/CodexBar/blob/v0.68.0/Sources/CodexBarCLI/CLIUsageCommand.swift)
- [JSON 与标签映射](https://github.com/steipete/CodexBar/blob/v0.68.0/Sources/CodexBarCLI/CLIPayloads.swift)
- [配置路径与 CODEXBAR_CONFIG](https://github.com/steipete/CodexBar/blob/v0.68.0/Sources/CodexBarCore/Config/CodexBarConfigStore.swift)

## 直接改变本次实现的发现

| 发现 | 本次处理 |
|---|---|
| primary / secondary / tertiary 是数据槽位，不等于五小时／每周／每月 | 读取实际周期和业务名称。Codex Pro 每周单窗口仍只有一个窗口。Kimi 的主窗口是七天，次窗口才是五小时。 |
| Cursor 还返回第三方窗口和 extraRateWindows；Antigravity 返回不同模型组的多个窗口 | 保留全部返回窗口。详情采用可滚动的两列环形布局，不强行“双环”。 |
| OpenCode Go 的本地记录不能证明账号真实额度。源码明确禁止对估算数据计算用量节奏 | 保留估算标记，但不展示这些估算窗口的“剩余百分比”、环形和速度预测。提示真实剩余额度尚不可用。 |
| MiniMax 把 orderedQuotaServices 映射进三个通用槽位；CLI 通用标签可能将第三个服务叫成 Sonnet | 使用同一顺序的 Quota services 明细名称。本机实际第三项是 Video，不能照搬 Sonnet。 |
| StepFun GUI 将用户名放在 apiKey，密码放在 cookieHeader，手动 Oasis-Token 放在 region；CLI 凭据适配把 password 设为空 | 只对 StepFun 子进程从新应用的私有配置设置 STEPFUN_USERNAME / STEPFUN_PASSWORD / STEPFUN_TOKEN；不经 shell，不输出凭据。本机登录后取得的是积分额度，缺少重置时间，不虚构五小时或每周限制。 |
| Antigravity 联网失败可能返回 source=offline，用一个 usedPercent=0 的窗口承载会话数量，源码注明 non-quota snapshot | 拒绝离线结果作为额度。已有真实读数转为过期，保留原时间；首次只有离线数据则额度不可用。 |
| 上游缓存键包含服务商、查询配置和账号身份，不能只以服务商名字作为身份 | Codex 继续验证本机 account_id；其余服务商验证配置指纹。浏览器或外部登录的活动账号无法提前证明，因此不恢复其磁盘旧读数；同一运行中的旧读数注明“采集时的账号”。这不是完整多账号迁移。 |

对应源码：

- [OpenCode Go 查询与估算](https://github.com/steipete/CodexBar/blob/v0.68.0/Sources/CodexBarCore/Providers/OpenCodeGo/OpenCodeGoProviderDescriptor.swift)
- [MiniMax 服务排序与明细](https://github.com/steipete/CodexBar/blob/v0.68.0/Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsageSnapshot.swift)
- [StepFun 查询凭据适配](https://github.com/steipete/CodexBar/blob/v0.68.0/Sources/CodexBarCore/Providers/StepFun/StepFunProviderDescriptor.swift)
- [StepFun GUI 配置字段](https://github.com/steipete/CodexBar/blob/v0.68.0/Sources/CodexBar/Providers/StepFun/StepFunSettingsStore.swift)
- [Antigravity 离线兜底](https://github.com/steipete/CodexBar/blob/v0.68.0/Sources/CodexBarCore/Providers/Antigravity/AntigravityProviderDescriptor.swift)
- [账号缓存键](https://github.com/steipete/CodexBar/blob/v0.68.0/Sources/CodexBar/UsageStore%2BTokenAccountCacheKey.swift)

## 可以复用的工程经验

1. 先沿“凭据 → 查询策略 → 标准数据 → 业务标签 → UI”读完整路径。只看 JSON 示例会漏掉估算语义，照搬通用标签也会出错。
2. 不用同一套时间窗口猜所有套餐。业务名称和周期来自返回数据，时间不足时不给预测。
3. 估算、未知、查询失败和真实零额度必须是四种状态。不能用空数组或零值把它们压成一种状态。
4. 图形界面与 CLI 未必使用完全相同的凭据适配。先核对源码，再用真实安装版验证。不能只因 CLI 报错就认定用户没配置账号。
5. 独立保存显示偏好和数据来源。切换模式不改变用量含义；时间戳来自采集，不来自切换动作。
6. 迁移先复制、隔离配置，并保留原数据。查询程序已打包不等于历史、Cookie 缓存和所有外部登录路径都完成迁移。

## 范围与证据

私有配置：`~/Library/Application Support/com.whattheport.app.local.zh/ai-usage/providers.json`，权限 0600，目录 0700。首次复制九个选定服务商；不复制外部钩子或其余服务商。后续通过 CODEXBAR_CONFIG 显式指向此文件，不覆盖原配置。原配置当前只有八个启用项；按已经确认的九个服务商范围，新应用保留 Antigravity 入口并已查到真实数据，不修改原应用开关。

构建 18 已真实验证九个入口、Cursor 多窗口和模式切换；安装版查询取得七个服务商的真实额度，OpenCode Go 仅估算，Claude 未取得有效读数。z.ai 有一次瞬时失败，独立重试成功。构建 20 对“环形”名称、接近 100% 的格式和重复周期标签进行收尾，并拒绝 Antigravity 离线兜底的非额度窗口，最终证据见 `.context/ai-usage/acceptance-build20.json`。

仍未迁移：完整历史、多账号管理、旧应用 Cookie 缓存的独立归属。CodexBar 安装、配置和历史均保留，不执行卸载。Claude 查询失败／超时，原因尚未确认，不能称为账号失效。


### Claude 官方订阅的后续核对

用户确认使用官方订阅。显式 OAuth 查询未找到可用凭据；显式 web 查询返回 `No Claude session key found in browser cookies.`。本机 Claude Code 的环境 API 地址是 MiniMax；`claude auth status` 虽显示已登录、firstParty，不能据此证明它能查官方订阅额度。只核对凭据类型与服务地址，未输出 token，也未将 MiniMax token 发给 Claude。

WhatThePort 私有配置中 Claude 的 source 已固定为 web，排除自动 CLI 回退。原 CodexBar 配置、MiniMax 环境和 Claude Code 登录均不改动。用户需提供可读取的官方网页登录会话后继续验收；不能把缺少会话说成额度耗尽或会员过期。更不能为了读数据，静默开启源码中默认关闭的“读取 Claude Code 钥匙串”授权。


### Chrome 登录后的验证

2026-10-03：用户确认 Chrome 已登录。在 Claude 官方网页内，以现有会话只读调用 organizations 与 usage，均返回 HTTP 200。已确认五小时窗口已用 0%，每周窗口已用 18%。未导出 Cookie、sessionKey、邮箱或组织 ID；原生应用此时仍没有读数。

`cookie refresh --provider claude` 的真实预检返回 blocked：Chrome 加密 Cookie 的导入需要显式 `--allow-keychain-prompt` 确认。已向用户说明解密钥匙的权限范围并请求授权。收到批准前不触发提示，也不清理缓存或修改钥匙串开关。证据：`.context/ai-usage/claude-chrome-login/browser-proof.json`。


### Vibe Island 对照与判断修正

本机运行 Vibe Island 1.0.51，bundle ID 为 app.vibeisland.macos。官方 changelog 说明：Claude 用量读取 Claude Code 本机登录；从 Claude 配置推导钥匙串项名称，而不列举钥匙串。当前程序包含 https://api.anthropic.com/api/oauth/usage 与 CLAUDE_CONFIG_DIR 等标记。官方 GitHub 是社区反馈仓库，没有公开核心实现，因此不称为已读其源码，也不能仅凭二进制字符串证明当前显示的读数来自哪一个分支。官网同时说明支持 compatible custom billing routes；本次未展开 Vibe Island 的用量面板，不把其当前显示直接认定为官方订阅。

更正先前判断：CLI 环境 API 指向 MiniMax，只证明当前调用路由，不能证明本机钥匙串没有另存 Claude 官方 OAuth 登录。CodexBar 的直接读取 Claude Code 凭据默认需要独立同意，这能造成“凭据未找到”，并非账号不存在。

Chrome Cookie 导入已获用户授权，并按 documented --allow-keychain-prompt 进行一次尝试；返回 failed，提示 Microsoft Edge cookie decryption declined。这是读取器的浏览器顺序／授权失败提示，不是 Claude 会员过期，也不声称 Chrome 的授权已成功。未输入密码，未修改钥匙串开关、Vibe Island 或 Claude Code 设置。若改走直接读取 Claude Code 登录项，则需要新的、明确的范围授权；不沿用 Chrome 解密批准。

来源：https://vibeisland.app/changelog/ 、 https://github.com/vibeislandapp/vibe-island 。


### 已授权的官方 OAuth 与安装版验证（构建 21）

用户明确同意改用同类 OAuth 路径。只读命名项 `Claude Code-credentials` 的真实探针成功，凭据未过期且有 user:profile 范围；用同一 Token 调官方 OAuth 用量接口成功。没有枚举其他钥匙串项，没有导出 Token，没有使用 Vibe Island 的私有数据或修改其设置。

新实现 ClaudeNativeOAuth 只通过 `/usr/bin/security find-generic-password -s Claude Code-credentials -w` 读这一项；内存解析后校验 Token 类型、过期和范围，并只传到当前查询子进程。移除 ANTHROPIC_BASE_URL / AUTH_TOKEN / API_KEY 等第三方路由变量，不改父进程或 Claude Code 配置。WhatThePort 私有配置中 Claude 的 source=oauth、nativeOAuthAllowed=true 是本次明确同意的记录。将 nativeOAuthAllowed 改为 false 即撤销本应用的读取；其余提供商不走这个读取器。当前仅支持默认命名项，不声称覆盖所有自定义 Claude 配置目录。官方登录过期时明确失败，不自动续期或改写 Claude Code 登录。

安装版 build21 的同一个真实 client/store 已通过不调用截图 API 的 --probe-ai-usage 路径，返回 OAuth ready、3 个窗口（五小时、每周、Fable）。证据：`.context/ai-usage/claude-native-installed21/result.json`。浏览器额度可能随后变化，验收不硬编码剩余百分比。62 项 Swift 测试通过。Native OAuth 查询及代码签名已验证；最终原生界面由用户查看，未再调用工具截图。

## 卸载 CodexBar 后（2026-10-03）

CodexBar 0.67.0 已卸载（Homebrew cask，未用 --zap）。它的配置、历史、缓存和网页数据已挪到 `~/Archives/codexbar-2026-10-03/`，钥匙串项 `com.steipete.codexbar.cache` 没有动。卸载前后都用安装版 build21 的 `--probe-ai-usage` 查了 9 个服务商（证据 `.context/ai-usage/codexbar-removal/before|after`）：卸载后 9 个都是 ready；卸载前 Antigravity 就是 unavailable，与卸载无关。

注意：随应用打包的 CodexBarCLI 运行时会自己写 `~/Library/Application Support/CodexBar`（Cursor 会话缓存）和 `~/Library/Caches/CodexBarCLI`。这两个目录现在归 WhatThePort 使用，清理时不要当作 CodexBar 残留删除。
