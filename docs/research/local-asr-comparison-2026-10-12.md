# 本地转写模型替换评估

状态：进行中。对应路线 W02/W09、M2→M3 个人录音闭环；不是新产品方向。

## 问题与边界

Apple SpeechAnalyzer 在真实本人音轨出现疑似错字、技术词和口语结尾异常。需要比较替代模型，不能仅凭模型榜单或更流畅的文字宣布准确率提升。分段认知另有数字引用错误，已独立处理，见 [ADR030](../adr/030-local-quote-grounding.md)。

保持原音视频、旧逐字稿和既有认知不变。音频仅本地处理，不调用云端转写或文本模型，不创建提醒事项。候选运行在 runtime 下独立 Python 环境，没有替换系统 Python 或应用默认端口。

## 候选与取舍

| 候选 | 评估理由 | 代价/限制 |
|---|---|---|
| Apple SpeechAnalyzer（基线） | 已接入、速度快、原生分发与片段定位 | 当前自然中文技术口述出现疑似错误 |
| Whisper large-v3 / MLX | 开源多语言、本地 Apple Silicon 推理、原生识别片段时间 | 权重约 3.08 GB；速度/内存待实测；可能幻觉、繁简变化与漏句 |
| Qwen3-ASR 1.7B 8bit / MLX Audio | 中文及混合技术口述候选；官方支持中文方言、多语言 | 权重约2.46 GB；社区转换版需独立验证；基本转写没有词级对齐，chunk 时间不能冒充精准出处 |
| 云端转写 | 可在后续作为质量候选 | 本轮没有原始音频云端授权，不测试、不作为默认 |

官方模型卡的公开评测不等于这些量化转换模型在本人素材上的效果。不会因为模型更新就直接设为默认。

## 固定样本与复现

仅使用第一期视频第二条音轨（本人），不是混音轨：偏移 120 秒、45 秒；偏移 300 秒、45 秒。首段含 AI/Agent/编写代码，第二段含 Codex/项目/bug。两段均有停顿与口语。原件不变，派生 mono/24kHz PCM 留在忽略的 runtime。此轮未加热词、未用 GPT 润色，以免混淆声学识别与事后猜测。

Apple 基线：`voiceos-check speech-eval <runtime-audio> <new-runtime-json>`，直接调用产品 NativeSpeechPort 并校验来源时间范围，不创建资料库。

Whisper：`runtime/asr-evaluation-venv/bin/python scripts/probes/local-whisper.py <audio> runtime/asr-evaluation-20261012/large-v3 <new-json>`。

Qwen：`runtime/qwen-asr-evaluation-venv/bin/python scripts/probes/local-qwen-asr.py <audio> runtime/asr-evaluation-20261012/qwen3-asr-1.7b-8bit <new-json>`。

推理脚本强制 Hugging Face 离线、拒绝覆盖旧结果；模型先单独下载。Whisper 关闭上一窗口文字条件以降低重复传播；这也是需要记录的识别策略，不代表所有设置下的性能。

模型固定版本：

- `mlx-community/whisper-large-v3-mlx`，revision `49e6aa286ad60c14352c404340ded53710378a11`，mlx-whisper 0.4.3，MIT。
- `mlx-community/Qwen3-ASR-1.7B-8bit`，revision `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`，mlx-audio 0.5.8，Apache-2.0。

环境实际依赖清单及私有逐字稿保存至 `runtime/asr-evaluation-20261012/`；不提交个人完整文字、权重或环境。

## 接入门槛

当前已复跑Apple：第一段45秒约1.05秒、193 scalars；第二段45秒约0.84秒、180 scalars。5秒数字静音约0.28秒，返回“我”（1字符），存在无声幻觉，不能把非空文字一律视为有效表达。基线结构范围检查通过不代表声音忠实性。候选结果仍待模型下载和推理完成。

先比较明显技术词、否定/条件、漏句、无声幻觉、冷启动耗时与时间定位。当前没有人工听写参考，不能给出 CER/WER 或声称音频忠实性已验收。若候选有优势，再以可选 SpeechPort 接入，固定模型/运行策略身份，保存新转写版本，不覆盖旧稿，不自动重新执行未知文本请求。Qwen 若无对齐，应明确显示粗时间范围或无精确定位，不能伪造词级时间；后续可评估单独 ForcedAligner。

## 资料

- [MLX Whisper 实现与使用](https://github.com/ml-explore/mlx-examples/tree/main/whisper)
- [Whisper MLX 固定版本](https://huggingface.co/mlx-community/whisper-large-v3-mlx/tree/49e6aa286ad60c14352c404340ded53710378a11)
- [Qwen3-ASR 官方模型卡](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)
- [Qwen MLX 固定版本](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/tree/a8379a2e2f9e313c9292cdf1af4055ab56d50d55)
- [MLX Audio Qwen 适配器](https://github.com/Blaizzy/mlx-audio/tree/main/mlx_audio/stt/models/qwen3_asr)
