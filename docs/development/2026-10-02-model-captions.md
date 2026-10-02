# 大模型字幕接入：构建 13（尚未验收通过）

## 用户要求

- 云端识别使用 StepAudio 2.5 ASR，走 Step Plan，不能改成按量接口。
- 识别提供本机模型选择，翻译改用大模型。
- 不把 API 成功、编译成功当作字幕质量验收。

## 当前实现

- 云端：`https://api.stepfun.com/step_plan/v1/audio/asr/sse`，`stepaudio-2.5-asr`；不做供应商或按量接口回退。
- 本机：复用现有 SenseVoice-Small。旧记录中的 Fun-ASR-Nano 已不存在，没有安装 Whisper 或新模型。
- 翻译：同套餐 `step-3.7-flash`，独立字幕段绑定原文与译文。读取 `~/.config/ai-providers/env.local` 中 STEPFUN_API_KEY，不复制密钥。
- 捕获：ScreenCaptureKit，16 kHz mono PCM；六秒或 0.6 秒静音切段，队列最多两段，满时明确失败。停止会取消采集、ASR 和翻译任务。本机临时 WAV 在进程结束后删除。
- UI：识别模型、语音语言、云端发送提示；最新段在上方，原译文配对，不再使用苹果 Speech 或系统翻译。
- 文档已同步。字幕窗口没有网站演示等价视图，没有添加营销屏幕。

## 已通过

- 云端模型列表实际包含两种指定模型。
- 完整测试音频经 Step Plan ASR 正确识别，含末句 Closing the window stops audio capture。本机同段音频 0.77 秒完成，但末句有识别错误，不能据此宣称本机模型准确率足够。
- Step 3.7 Flash 最小翻译请求成功，保留模型名称。
- 45 项 Swift 测试、网站 build、签名校验通过。
- 构建 13 已安装，安装包与构建产物可执行文件 SHA-256 均为 `ff055a8515878007c4ba7f9b64dc8a2ee69208f3bc838b21e1db5efed17a5236`。运行路径是 `/Applications/WhatThePort 中文版.app`，旧构建 12 保留在 `.context/delivery/installed-build12-original.app`。
- 重置仅中文版的 ScreenCapture 授权，重启系统设置消除旧文件列表缓存，再通过键盘确认当前 `/Applications` 路径添加授权，系统“退出并重新打开”后实际开始采集。
- 从安装版播放同一英语测试音频，获得真实 ASR 与两段译文，证据是本次工具返回的 AX 状态和截图。

## 验收失败与下一步

1. **六秒切段截断句子**：`Each service has its own` 与 `process tree` 分开；`closing` 与 `the window` 分开。这导致不自然译文。音频分析显示原测试样本句间静音为 0.28–0.30 秒，当前 0.6 秒阈值错过这些句间停顿。下一步调低阈值并复验同一真实路径，不能仅增大分段长度掩盖延迟。
2. **译文可能为空**：第一段界面显示“翻译模型没有返回文字”。进一步用更高 token 上限请求同一文本，completion_tokens 达 1709、耗时 13.21 秒，最终文字非空。原上限 800 可能不足，但尚未从原失败响应确认 finish_reason，不能把此推测写成确定原因。下一步检查返回结束原因和 token 预算，验证延迟与空结果。
3. 本机 ASR 的完整采集路径、中文原文、关闭后的资源释放、长时间播放及网络错误验收未完成。
4. 设置截图的自动快照被截断，没有覆盖替换现有公开图。新字幕截图尚未保存为仓库图片。

目前仍是未验收的本地版本。没有提交、推送或发布。源码已保留，不能描述为质量问题已解决。
