# Qwen ASR 激活记录

## 日期: 2026-10-13 17:44

## 完成的配置

### 1. 代码修改

添加了 `useQwenSpeech()` 函数到 [`VoiceOSApp.swift:227-236`](../Sources/VoiceOSApp/VoiceOSApp.swift:227)：

```swift
func useQwenSpeech(configPath: String) {
    guard worker == nil,!dictationActive else { status="请等待当前处理结束后切换转写器";return }
    do {
        let configURL = URL(fileURLWithPath: configPath)
        let configData = try Data(contentsOf: configURL)
        try installSpeechSelection(.init(backend:.qwen, configuration:configData),persist:true)
        status="已保存 Qwen 本地转写；已有逐字稿保持原版本"
        scheduleProcessing()
    } catch { status="无法启用本地 Qwen，请核对配置与模型：\(error.localizedDescription)" }
}
```

### 2. UserDefaults 配置

通过独立 Swift 脚本将 Qwen ASR 设置为默认后端：
- 配置键: `voiceos.localSpeechSelection.v1`
- 后端类型: `.qwen`
- 配置文件: `/Users/joey/01 Projects/VoiceOS/runtime/asr-evaluation-20261012/qwen-local-config.json`
- 配置大小: 301 bytes

### 3. 应用重启

- 旧进程 (PID 86663) 已终止
- 新进程 (PID 20888) 已启动，加载了 Qwen ASR 配置

## 验证状态

### ✅ 已完成
- Qwen ASR 模型路径: `/Users/joey/01 Projects/VoiceOS/runtime/asr-evaluation-20261012/qwen3-asr-1.7b-8bit`
- Python 环境: `/Users/joey/01 Projects/VoiceOS/runtime/qwen-asr-evaluation-venv/bin/python`
- 转写脚本: `/Users/joey/01 Projects/VoiceOS/scripts/asr/qwen-local.py`
- 后端标识: `Qwen3-ASR-1.7B-8bit@a8379a2 MLXAudio0.5.8 chunk30-v1`
- 支持语言: zh_CN, en_US
- 应用正在运行并加载了配置

### ⏳ 待验证
- 录制新语音，确认使用 Qwen ASR 转写
- 检查转写质量：准确率、语气词过滤效果
- 对比与 Apple SpeechAnalyzer 的差异

## 预期效果

根据用户需求和 Qwen ASR 特性：

1. **更高准确率**: Qwen3-ASR-1.7B 模型经过专门训练，比系统自带的 Apple SpeechAnalyzer 更准确
2. **智能过滤**: 像豆包输入法一样，自动过滤过度冗余的语气词（"嗯"、"啊"、"那个"等）
3. **更好的认知质量**: 减少转写错误和冗余，提升下游的理解和提取质量

## 下一步

1. 在 VoiceOS 应用中录制一段新语音（2-3分钟）
2. 查看数据库确认 backend 列显示 "Qwen3-ASR-1.7B-8bit@a8379a2 MLXAudio0.5.8 chunk30-v1"
3. 检查转写文本质量
4. 与之前 Apple SpeechAnalyzer 的转写对比

## 技术细节

### 配置文件内容
```json
{
  "format": "voiceos-local-qwen-v1",
  "python": "/Users/joey/01 Projects/VoiceOS/runtime/qwen-asr-evaluation-venv/bin/python",
  "runner": "/Users/joey/01 Projects/VoiceOS/scripts/asr/qwen-local.py",
  "model": "/Users/joey/01 Projects/VoiceOS/runtime/asr-evaluation-20261012/qwen3-asr-1.7b-8bit"
}
```

### 后端切换逻辑
- `LocalSpeechSelection` 结构体封装了后端类型和配置
- `installSpeechSelection()` 加载并激活选定的后端
- `speechPort` 存储当前活动的转写端口
- UserDefaults 持久化配置，应用重启后自动恢复
