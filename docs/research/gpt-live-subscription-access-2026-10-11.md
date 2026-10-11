# GPT-Live、Codex 与独立 VoiceOS 的接入边界

日期：2026-10-11。官方文档核查；没有读取登录凭据、进行 OAuth 注册、创建 Live 会话或上传音频。账号实际权益未测试。

用户确认首版逐轮语音＋文字，同时说明最初希望使用 GPT-Live，当前没有其 API，希望尝试 Codex 额度。保留此体验目标，不把缺少实时接口理解为应将整个 VoiceOS 改成 Codex 内的专用功能。

## 当前可确认的三条路径

| 路径 | 文档证据 | 对 VoiceOS 的实际意义 | 尚未验证 |
|---|---|---|---|
| ChatGPT/Codex 宿主内语音 | ChatGPT Voice 由 GPT-Live 支持，可在 Chat/Work/Codex 对话中使用；受计划、工作区和发布状态影响 | 可在支持的宿主中进行实时语音讨论，不能由此推断独立应用获得同一语音接口 | 本账号的宿主语音入口与额度归属；宿主对话内容/原始音轨如何可靠回到 VoiceOS |
| 独立应用的 GPT-Live API | WebRTC 接入 `/v1/live/sessions`，要求具有 GPT-Live 访问权限的项目 API Key | 后续单独语音适配器可以接入；现有文本密钥不证明有 Live 权限 | 实际项目权限、费用、网络、音频授权与录音持久性 |
| 独立本地应用的 ChatGPT 订阅文本推理 | 官方 Sign in with ChatGPT 允许符合条件的开源/本地应用，经用户授权使用计划额度调用 Responses；也可通过 Codex app-server | 存在官方的订阅文本接入方案，不必一概断言“订阅只能在 Codex 内使用” | VoiceOS 是否符合接入条件、注册/同意、账户模型与实际请求权限；不是已经实现 |

第三条目前是预览：HTTP 请求必须 `store:false`、`stream:true`，完整历史由客户端提供；音频/视频输入、Files 上传和转写 API 不受此流程支持。官方说明没有建立该 OAuth 流程调用 GPT-Live 音频会话的支持；不能把文本额度接口当实时语音接口，也不能把模型目录当访问成功。具体限额错误可以在流开始后出现，只有终止成功事件才算完成。

来源：[ChatGPT Voice](https://learn.chatgpt.com/docs/features/voice)、[GPT-Live WebRTC](https://developers.openai.com/api/docs/guides/voice-webrtc)、[订阅接入概览](https://developers.openai.com/siwc/token-sharing-open-source)、[预览限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)、[模型与完整推理](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)、[Codex app-server 接入](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)。以未来实施时重新核查的官方协议为准。

## 工程取舍与推进

近期实施 P07：VoiceOS 主动逐轮采集→独立本地保存→本地转写→已授权文本模型→文字回复。使用现有文本 API 配置；基础会话、出处、认知/任务和迁移仍归 VoiceOS 管理。此路径不需要先取得 GPT-Live API，不因此阻塞基础 B。

保留可替换的讨论模型端口。未来订阅文本适配需要独立 OAuth 注册/同意、权限核对、令牌刷新/安全存储、流式结束和额度错误处理；不能直接将现有非流式 API Key 请求切换到 OAuth 令牌，也不复制 Codex 自己的认证缓存冒充 VoiceOS 注册。

GPT-Live 后续独立评估会话生命周期、原始音轨保存、引用/归属和派生限制。语音流失效不能破坏已保存原件；语音建议不能直接变成用户承诺。未获得真实 Live 权限前，只记录接入设计，不自动创建付费语音会话。

通过 Codex 语音作为临时前台属于额外适配方案：需显式的 VoiceOS 数据读写契约、来源限制和回执；宿主声音可用不证明 VoiceOS 获得原始录音、完整历史或闭环。若要把它作为首版唯一 B 入口，将改变独立控制中心的交付边界，应另行产品确认。当前没有作此变更。
