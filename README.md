# VoiceOS

VoiceOS 将自然表达连接到有来源的知识、行动和结果反馈。产品方向见[愿景 v1.1](docs/VoiceOS：产品愿景与概念设计文档%20v1.1/VoiceOS_产品愿景与概念设计文档_v1.1.md)，开发与交付规则见 [AGENTS.md](AGENTS.md)。

## 当前迁移批次

当前历史迁移累计保留此前批次能力。本批：恢复完整内容整理、任务工作区和反馈入口，并吸收已有开发工具与历史测试精简。

这是历史实现的分批迁移，当前产品检查点为 `3742927`。后续未提交功能保留在本地快照，需单独确认范围。本轮不新增历史开发探针、云调用回执和个人验证资料；已公开的基线历史仍保留。

## 思考全景

首页从当前已授权、完成完整理解的全部材料及节目依赖生成长期问题全景，近期只高亮。每个问题和 AI 候选联系保留当前原话版本、精确范围、来源入口及材料和观点覆盖清单。唯一逐字引文可由应用定位，重复引文必须已有正确范围。生成和独立语义核对取得不同回执后才发布，语义拒绝最多针对性修复一次并重新独立核对。原话、归属、许可、完成状态或当前观点变化后旧图停止展示。失败与结果未知需明确重试，重开不会静默重发。

沿问题或联系进入讨论时，应用校验当前快照并原子保存完整会话入口，只返回 AI 候选的未发送可编辑草稿。普通讨论、回复与成果整理共用完整表达/节目上下文，包含实际已有 AI 回复。默认不再受 4000/12000 字或 40 轮输入限制；显式预算不足会拒绝，不裁剪原文。全景是主 SQLite schema42 的可重建派生资料，不随现有业务迁移包导出。

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
