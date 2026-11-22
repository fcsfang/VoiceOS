# 182 配置缺失时的指路收尾

来源：阶段 2 审计候选 6 的剩余项（处理页模型卡只有文本模型；缺少本地语音状态与配置入口）。

## 改动
- FullRecordingView：模型缺失提示补「仍可先『只保存原件』，配置后再完整整理」。
- 处理情况页「模型与提醒事项」卡：新增本地 Qwen 转写状态行（已就绪 / 尚未配置且音频原文仍会先保存在本机），未配置时给「配置本地 Qwen 转写…」按钮（accessibilityIdentifier=processing.localSpeech.configure）。

## 验证
parse_exit=0；集成构建 75。
