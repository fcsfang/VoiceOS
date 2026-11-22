# 165-A 监测状态按页面可见性重载（VoiceOSApp / WorkspaceMonitorView）

## 背景（性能发现）
每次数据刷新成功后都会 `reloadMonitorState()`（N+1 查询 + 最多 30 份报告 JSON 解码），即使监测页从未打开。监测页自身 onAppear 已强制 `reloadMonitorState()`，因此关闭期间的刷新重载是纯浪费。

## 改动
- ControlCenter 新增非发布属性 `monitorPageVisible`（默认 false）。
- refresh 成功路径：`await reloadMonitorState()` → `if monitorPageVisible { await reloadMonitorState() }`。
- WorkspaceMonitorView：onAppear 置 true（随后自身 reload 不变），新增 onDisappear 置 false。

## 影响与验证
- 页面打开时行为不变（onAppear 照旧加载）；关闭期间 monitor 状态由打开时刷新补齐。
- 两文件 parse 退出码 0；集成构建与全量测试见 STATUS。