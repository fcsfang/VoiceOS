# 2026 年技术基线

VoiceOS 必须基于 2026 年的技术现实来设计，而不是 2021-2023 年的限制。

## LLM 上下文窗口

### GPT-6 系列

来源：[GPT-6 Astra Brings 1.05M-Token Context](https://facerate.ai/blog/gpt-6-astra-news-generic)、[OpenAI raises GPT-6.1 Sol default context length to 500,000 tokens](https://cryptobriefing.com/openai-gpt-6-1-sol-500k-context/)

- **GPT-6 Astra**: 1,050,000 token 上下文窗口
  - 最大输入：922,000 tokens
  - 最大输出：128,000 tokens
- **GPT-6.1 Sol**: 默认 500,000 tokens（可扩展到完整 1,050,000）
  - 2026 年 10 月从 272,000 提升到 500,000

### Claude Opus 5

来源：[Claude Opus 5: Benchmarks, Pricing & Full Guide](https://coursiv.io/blog/claude-opus-5)、[What's new in Claude Opus 5](https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5)

- **上下文窗口**: 1,000,000 tokens（这是默认和最大值）
- **最大输出**: 128,000 tokens
- **发布日期**: 2026 年 7 月 24 日
- **定价**: $5/M input tokens, $25/M output tokens
- **API model ID**: `claude-opus-5`

## 语音识别

### Whisper v4 (OWSM v4)

来源：[OWSM v4: Improving Open Whisper-Style Speech Models](https://arxiv.org/pdf/2506.00338.pdf)、[Deploy Whisper v4 and Production ASR](https://www.spheron.network/blog/whisper-v4-asr-gpu-cloud-production-guide/)

- **准确率**: 在多语言基准测试中超越或匹配 OpenAI Whisper 和 MMS
- **性能优化**: faster-whisper 实现达到原始速度的 4-8 倍
- **实时能力**: 在 RTX 4090 上，使用 INT8 量化可将 3 秒音频延迟降至 15ms 以下
- **语言支持**: 约 99 种语言，包括地区方言
- **鲁棒性**: 对口音、背景噪音和技术术语有很强的适应性

**关键结论**: 本地实时转写在消费级硬件上完全可行（Mac M4）

## 原生音频处理

### OpenAI Realtime API & GPT-Live

来源：[Introducing gpt-realtime and Realtime API updates](https://openai.com/index/introducing-gpt-realtime/)、[Build more natural voice experiences with GPT-Live-1](https://openai.com/index/introducing-gpt-live-1-in-the-api/)

- **原生音频**: 单个模型直接处理和生成音频，无需链式调用 STT + LLM + TTS
- **GPT-Live-1**: 2026 年发布，专为生产级语音代理设计
- **能力**:
  - 同时处理输入和输出音频流
  - 支持打断（barge-in）
  - 自然的轮流对话
  - 实时工具调用
  - 保留语音细微差别（语调、情绪）
- **性能**: 配合 GPT-6 Astra 中等推理力度，首次尝试完成率 83.6%（客户支持任务）

**关键结论**: 不再需要"录音 → 转写 → 理解"的链式架构，可以直接"音频 → 理解"

## 对 VoiceOS 的启示

### 1. 字符/Token 限制已过时

| 年份 | 主流模型 | 上下文 | VoiceOS 限制 | 问题 |
|------|---------|--------|------------|------|
| 2021 | GPT-3 | 4K tokens | 无 | - |
| 2023 | GPT-4 | 128K tokens | 4000 字符 | 强制分段处理 |
| 2026 | GPT-6, Opus 5 | 1M tokens | 40000 字符？ | 仍然过度保守 |

**正确做法**: 
- 移除硬编码的字符限制
- 根据实际使用的模型动态决策
- 1M tokens ≈ 750K 英文单词 ≈ 250K 中文字符
- 40000 字符在 2026 年完全是小意思

### 2. 分段处理系统可能完全不需要

当前代码中的分段处理系统（`segmented_processing_batches`、`segmented_extraction_attempts`、`segmented_aggregation_attempts`）是为了应对小上下文窗口而设计的。

**2026 年的现实**:
- 一小时语音 ≈ 9000 单词 ≈ 6000 中文字 ≈ 12K tokens
- GPT-6 可以一次性处理 92 万 tokens
- 相当于一次处理 **77 小时的连续对话**

**结论**: 除非是极端长的会议录音（> 10 小时），分段处理完全不必要。

### 3. 可以跳过转写步骤

**当前架构**: 录音 → Whisper 转写 → GPT 理解 → 提取知识/行动

**2026 年可行架构**: 录音 → GPT Realtime API → 直接理解和提取

**优势**:
- 保留语音细微差别（犹豫、强调、情绪）
- 更低延迟
- 更少的 token 消耗（不需要先生成完整转写文本）
- 更自然的对话式交互

**权衡**:
- 依赖云端 API（需要网络连接）
- 成本可能更高（需要实际测算）
- 失去可编辑的转写文本（但可以要求模型同时输出）

### 4. 本地处理是可行选项

**Whisper v4 + 本地 LLM**:
- Mac M4 可以实时运行 Whisper（15ms 延迟）
- 本地 LLM（Llama 3.2, Qwen）可以处理理解任务
- 完全离线，无隐私风险
- 但质量可能不如 GPT-6/Opus 5

**混合方案**:
- 默认本地处理（快速、隐私）
- 用户可选云端增强（更好的理解）
- 符合产品愿景的"本地优先"设计决策

## 重新审视 VoiceOS 架构

### 当前问题

1. **过度防御的字符限制**: 4000 → 40000 仍然太保守
2. **不必要的分段系统**: 为 2021 年的模型设计的
3. **强制转写步骤**: 可以用原生音频 API 替代
4. **复杂的状态管理**: 为处理异步分段而存在的状态机可以简化

### 符合愿景的 2026 年架构

**愿景**: 让人能够毫无负担地表达，让有价值的思想被忠实理解

**技术实现**:
1. **捕获表达**: 
   - 本地实时 Whisper v4（15ms 延迟）
   - 或直接保存音频文件
   
2. **理解与归属**:
   - 选项 A: 原生音频 → GPT-Live-1/GPT-6（保留语音细微差别）
   - 选项 B: 转写文本 → GPT-6/Opus 5（1M token 窗口，不需要分段）
   
3. **形成知识和行动**:
   - 单次 LLM 调用提取所有信息
   - 不需要复杂的分段-提取-聚合流程
   
4. **跟踪后续变化**:
   - 保持现有的版本控制和关联机制
   
5. **适当时机反馈**:
   - 主动反馈系统（需要验证是否已实现）

### 需要删除或简化的部分

- [ ] 整个分段处理系统（除非用于 > 10 小时的极端场景）
- [ ] 硬编码的字符/token 限制
- [ ] 为分段而存在的复杂状态机
- [ ] 过度的快照验证和指纹机制（部分可能是必要的安全边界，需要审计）

### 需要添加的部分

- [ ] 原生音频输入支持（Realtime API）
- [ ] 本地 Whisper v4 集成
- [ ] 动态模型能力检测（查询 API 的实际限制）
- [ ] 更简单的单次处理流程

## 下一步行动

1. **审计现有代码**: 哪些模块是为了应对小上下文窗口而存在的？
2. **MVP 优先**: 先用最简单的方案跑通闭环，不要被历史架构束缚
3. **分阶段重构**:
   - Phase 1: 移除字符限制，用模型能力决策
   - Phase 2: 简化/移除分段系统
   - Phase 3: 引入原生音频处理
   - Phase 4: 添加本地处理选项

**记住**: 我们在 2026 年，不是 2021 年。代码应该反映现实的技术能力，而不是历史的技术限制。
