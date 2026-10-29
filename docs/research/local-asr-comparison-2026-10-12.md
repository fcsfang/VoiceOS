# 本地转写模型替换评估

**2026-10-12 当前覆盖：** Qwen已由用户确认，成为默认待配置的本地转写方案，选择快照持久保存并在重启前恢复；Apple仅明确备选，无静默回退。原生本人音轨导入保存376字符、无文本调用；两段新本人音轨完成真实文字理解，后续BGE召回1份历史后判断无直接关联，未外写任务。以下Apple启动默认/选择不持久为早前记录。详见[最新证据](evidence/qwen-native-cognition-2026-10-12.json)与[当前进度](../planning/overnight-progress.md)。完整自然案例A仍未验收。

状态：小样本对比完成，Qwen候选已可选接入并在当前应用运行启用；整体准确率与长录音待验收。对应路线 W02/W09、M2→M3 个人录音闭环。

## 问题与边界

Apple SpeechAnalyzer 在真实本人音轨出现疑似错字、技术词和口语结尾异常。需要比较替代模型，不能仅凭模型榜单或更流畅的文字宣布准确率提升。分段认知另有数字引用错误，已独立处理，见 [ADR030](../adr/030-local-quote-grounding.md)。

保持原音视频、旧逐字稿和既有认知不变。音频仅本地处理，不调用云端转写或文本模型，不创建提醒事项。候选运行在 runtime 下独立 Python 环境，没有替换系统 Python。应用保留Apple启动默认值，本次运行已明确选用Qwen。

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

| 本机单次测试 | 第一段45秒 | 第二段45秒 | 5秒数字静音 |
|---|---|---|---|
| Apple | 1.05秒/193字 | 0.84秒/180字 | 返回“我” |
| Qwen基础候选 | 9.51秒/197字 | 40.67秒/191字 | 返回“嗯。” |
| Whisper基础候选 | 10.63秒/178字 | 8.40秒/164字 | 返回广告语，时间末端29.98秒越界 |

计时是脚本内加载/识别耗时，未包含完整Python启动；Apple不是同一运行机制。候选推理串行运行，未计算均值/p95；Qwen第二段较慢原因未确定。进程RSS不包括全部GPU统一内存，不能直接当内存预算。

两候选均把疑似“携代码”识别为“写代码”；Qwen保留更多口语，第二段Codex拼写正确，Whisper写为Codeus并删去较多口语。第一段开头Apple“技术”、Whisper“基础”、Qwen“基准”不同，没有听写参考不能判谁正确；末尾口语仍有异常。三者均有数字静音幻觉，不能把非空文字一律视为有效表达。

脱敏结构证据：[首段](evidence/comparison-45s-2026-10-12.json)、[第二段](evidence/comparison-second-45s-2026-10-12.json)、[静音](evidence/comparison-silence-2026-10-12.json)。Whisper时间越界保持失败观察，不裁剪后伪称合格。

## Qwen接入结果

优先采用Qwen为可选试用端口，保留Apple备选，不宣称“最佳模型”或整体准确率提高。原生菜单为“本地转写器→启用本地 Qwen…”，选择本机 `runtime/asr-evaluation-20261012/qwen-local-config.json`。该JSON仅含Python、runner和模型绝对路径，没有API密钥。本次选择只影响当前应用运行，重启后回到Apple；不会自动重做完成的旧稿。

生产候选runner为 `scripts/asr/qwen-local.py`：固定mlx-audio 0.5.8和权重SHA256，每次校验；强制离线，无热词；独立识别最多30秒真实音频块、块内1024生成token用尽则整次拒绝，保存块范围。仅全零数字静音跳过，背景噪声/低声不是已验证VAD。长文件全量解码的资源上限、跨块漏句和精确对齐仍需后续改进。

`LocalQwenSpeechPort`直接复用现有转写持久工作器，写入真实backend身份；不新增schema。配置切换在应用worker/录制空闲时进行，工作器运行期间固定端口，无自动云端或Apple回退。结果校验文字完整覆盖、时间范围和后端身份；取消终止本次子进程，失败保留原件。CLI：`voiceos-check transcribe-qwen <isolated-root> <python> <runner> <model-directory>`。

独立库真实首段保存199字、两个0–30/30–45秒范围；静音保存0字/空spans，integrity通过，模型尝试/行动/认知均0。第二段chunk30单独转写191字，时间范围有效。原生CUA验证选择、两份展示、日常资料库恢复与既有提醒事项回读，本次运行已启用Qwen；没有原生新录音→Qwen的完整执行证据。编译、116项选中检查和稳定签名/严格校验通过，未重跑全套回归。

接入证据：[Qwen本地端口](evidence/qwen-local-port-2026-10-12.json)、[采用决策](../adr/031-local-qwen-speech-candidate.md)。原件、旧逐字稿、认知与行动未覆盖；旧unknown/rejected文本请求不重发。

先比较明显技术词、否定/条件、漏句、无声幻觉、冷启动耗时与时间定位。当前没有人工听写参考，不能给出 CER/WER 或声称音频忠实性已验收。若候选有优势，再以可选 SpeechPort 接入，固定模型/运行策略身份，保存新转写版本，不覆盖旧稿，不自动重新执行未知文本请求。Qwen 若无对齐，应明确显示粗时间范围或无精确定位，不能伪造词级时间；后续可评估单独 ForcedAligner。

## 资料

- [MLX Whisper 实现与使用](https://github.com/ml-explore/mlx-examples/tree/main/whisper)
- [Whisper MLX 固定版本](https://huggingface.co/mlx-community/whisper-large-v3-mlx/tree/49e6aa286ad60c14352c404340ded53710378a11)
- [Qwen3-ASR 官方模型卡](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)
- [Qwen MLX 固定版本](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/tree/a8379a2e2f9e313c9292cdf1af4055ab56d50d55)
- [MLX Audio Qwen 适配器](https://github.com/Blaizzy/mlx-audio/tree/main/mlx_audio/stt/models/qwen3_asr)
