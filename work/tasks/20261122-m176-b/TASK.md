# 176-B 通知点开直达材料页

来源：产品文档阶段 2「整理好后无需去全局行动找刚才的结果 / 完成后回到本次内容」。原通知回调只设置 model.selected，不导航到材料页。

## 改动
NoticeDelegate.didReceive：默认点击与「打开材料」动作都改为 ControlCenter.requestWorkspaceSource(sourceID)（经 pendingWorkspaceSourceID → go(.source(id))），窗口未打开时同时 openMainWindow()。

## 评审修复（177 波并入）
- 主窗口被关闭重建时 WorkspaceView 尚未挂载，pendingWorkspaceSourceID 只由 onChange 消费会丢失；改在 onAppear 的 consumePendingNavigation 里补消费。
