# VoiceOS

让自然表达被忠实理解、长期记住、恰当唤起，并与现实行动形成持续循环。
产品定义见[愿景 v1.1](docs/VoiceOS：产品愿景与概念设计文档%20v1.1/VoiceOS_产品愿景与概念设计文档_v1.1.md)，开发方式见 [AGENTS.md](AGENTS.md)。

当前以本地 `main` 推进功能，优先跑顺一次技术访谈的完整闭环：
录音 → 转写 → 理解 → 观点和任务 → Apple 提醒事项 → 结果回流。

## 构建和运行

```bash
python3 scripts/app/build.py --semantic-model runtime/bge-coreml-2026-10-11
python3 scripts/app/run.py
```

构建使用本机已有开发签名与本地模型资源，不下载模型。
数据默认保存在 `~/Library/Application Support/VoiceOS`；文本模型使用项目本地 `.env`。
本地转写按应用保存的 Qwen/Apple 选择运行。

需要独立试用库时：

```bash
python3 scripts/app/run.py --data-dir runtime/dev
```

## 最小验证

```bash
swift test -j 4
```

只保留少量核心集成流程，覆盖表达、录音、历史复用、纠错、英语反馈和重开续用。
模型和提醒事项使用模拟端口，真实模型质量、麦克风和 Apple 提醒事项体验通过实际使用验证。
开发时只运行受影响的流程；UI 改动构建并实际操作一次。

## 代码入口

- `Sources/VoiceOSApp`：原生界面和功能连接。
- `Sources/VoiceOSCore`：表达、知识、任务及本地存储。
- `Sources/VoiceOSPlatform`：录音、转写、检索和提醒事项。
- `Sources/VoiceOSCheck`：导入、转写、查看和导出恢复的简单命令行入口。
- `scripts/app`：构建和启动；`scripts/asr`：Qwen 本地转写；`scripts/models`：模型转换工具。

旧工程文档保留作按需参考，不要求每次开发阅读、更新或运行历史探针。
