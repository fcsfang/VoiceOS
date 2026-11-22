# 180 只保存原件与等待转写的诚实提示

来源：阶段 2 审计候选 1（完整录音缺「只保存原件」入口）与候选 6（模型缺失时导入状态与真实不符）。

## 改动
- ControlCenter.saveFullRecordingOnly(_:track:)：提取本人音轨 → importPersonalAudio 保存原件，不转写不整理；完成记录 fullRecordingCompletedSourceID 并发「录音已保存」通知。
- FullRecordingView：本人音轨时显示「只保存原件」（help 说明之后可再完整整理）；已有保存成果时显示「打开这份材料」。
- 导入文案：未配置本地 Qwen 时，导入结果行与完成通知改为「配置本地 Qwen 后可转写」，不再说正在转写。
- 材料页：queued 且未配置 Qwen 时显示「等待本地转写模型」并在正文区提供「配置本地 Qwen 转写…」按钮。

## 验证
parse_exit=0；集成构建 73。
