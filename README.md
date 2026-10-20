# VoiceOS

VoiceOS 将自然表达连接到有来源的知识、行动和结果反馈。产品方向见[愿景 v1.1](docs/VoiceOS：产品愿景与概念设计文档%20v1.1/VoiceOS_产品愿景与概念设计文档_v1.1.md)，开发与交付规则见 [AGENTS.md](AGENTS.md)。

## 当前迁移批次

这一批恢复原话版本、内容处理授权、观点审阅、任务与提醒事项连接、结果反馈和资料包恢复。用户原话、外部资料与 AI 候选保持不同归属。任务完成和实际收获分别记录。

这是历史实现的分批迁移。完整的后续录音、讨论和工作区功能仍在后续批次中。本轮不新增历史开发探针、云调用回执和个人验证资料；已公开的基线历史仍保留。

## 构建与验证

需要 macOS 26 和已安装的 Xcode 工具链。

```bash
swift build -j 4
swift test -j 4
```

测试使用合成资料和模拟模型、提醒事项端口。通过测试不代表真实录音质量或真实 Apple 提醒事项已验收。

## 本地命令行

```bash
swift run voiceos-check read /path/to/library
swift run voiceos-check import /path/to/library /path/to/recording.wav
swift run voiceos-check transcribe /path/to/library
swift run voiceos-check export /path/to/library /path/to/new-package media
swift run voiceos-check restore /path/to/new-library /path/to/package
```

省略导出命令末尾的 `media` 时仅导出结构化资料。恢复目标必须是新目录。转写需在本机提供语音识别权限，不自动上传原始录音。

模型配置从本地文件显式读取。不要提交 `.env`、凭据、个人录音、数据库或运行日志；配置格式见 `.env.example`。
