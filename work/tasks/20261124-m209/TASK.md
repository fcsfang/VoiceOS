# 209 设置页 P3：权限状态与阅读生成偏好

- 系统权限卡补「屏幕录制」（CGPreflightScreenCaptureAccess 实时状态 + 跳转）与「完全磁盘访问」（无法应用内检测，说明 + 跳转）。
- 新增「阅读与生成」卡：显示 AI 批注开关（voiceos.note.annotations.visible）、最近笔记区默认展开（voiceos.home.recentNotes.expanded），与阅读页 AppStorage 同键即时生效。
- 连接/备份/存储经盘点已完整，不重做。

## 验证
parse_exit=0；集成构建 127；解锁后上机核对。
