# 163-D 监测卡缩进、导出播报与逾期分钟冻结（WorkspaceView / WorkspaceMonitorView）

## 背景（评审 CONFIRMED / 修 161 回归）
1. 161 把监测设置三卡换成 WorkspaceSettingsCard 时未给内容加 20pt 缩进，控件与分隔线贴卡边。
2. 导出时唯一进度指示被 accessibilityHidden，VoiceOver 只听到两个禁用按钮；备份半边经核实不成立，只修导出。
3. ActionPageCache 以分钟桶缓存 surface，分钟内跨过到期瞬间时逾期分类与「逾期 M」计数冻结到下一分钟。

## 改动
- 监测三卡内容 VStack 补 `.padding(.horizontal, 20).padding(.bottom, 14)`。
- 导出 ProgressView 由 accessibilityHidden 改为 `.accessibilityLabel("正在导出")`。
- 行动页新增 `actionSurfaceRevision`（并入缓存键）；构建 surface 后调度「最近一个分钟内的到期瞬间」定时 tick，到点自增代际触发重算；日期瞬时解析用 Core 的 ActionTimeFormatting 静态格式器。

## 验证
两文件 parse 退出码 0；行为验证随 163 集成构建；分钟桶其余行为不变（跨分钟后照常重建）。