---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-7
owner: coordinator
---

# 并行大波第七批

## 目标

三条线：统一撤销扩展到材料操作（改名、回收站、归档）、剩余页面无障碍第二轮、性能基线脚本。基线 `main` 为 `aed56c6`，schema 60，包格式 51，270 项测试。

## 单元

### L1 统一撤销：材料操作

文件：`Sources/VoiceOSCore/ActionUndoStack.swift`、`Sources/VoiceOSApp/UndoSupport.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSCore/MaterialManagement.swift`、`Tests/VoiceOSCoreTests/ActionUndoStackChecks.swift` 追加。

- 撤销栈从「行动状态」泛化为「工作区变更」：条目为枚举（行动状态、材料处置、材料改名），同栈 LIFO、上限 10。
- 入栈：行动完成/放下/重开（现状）、材料改名、移入回收站、从回收站恢复、归档、取消归档。
- 撤销执行：行动回原状态；材料处置回原状态；改名回原名；失败（对象已变）跳过并提示。
- 菜单项文案改「撤销上一次变更」，⌥⌘Z 不变；任务页内撤销条保持现状。
- 测试：混合条目顺序与上限；材料处置逆操作；改名逆操作；对象变化时跳过。

### L2 剩余页面无障碍第二轮

文件：`Sources/VoiceOSApp/WorkspaceView.swift`、`WorkspaceActivityViews.swift`、`WorkspaceProcessingView.swift`、`WeeklyReviewView.swift`、`TaskInitiationView.swift`。

- 行内菜单与图标按钮补 `accessibilityLabel`；列表行读法分组（标题、来源、状态）；关键区块标题补 `.isHeader`。
- 不改布局与行为，不动其余文件。

### L3 性能基线脚本

文件：`scripts/perf/baseline.py`（新）。

- 脚本对指定资料库副本执行固定测量并输出 JSON：打开库并恢复、`workspaceSnapshot`、搜索固定词、镜像一次写入的耗时；用 `voiceos-check` 可复用的入口或在脚本内以 `swift test --filter` 的既有基准替代（读 VoiceOSCheck 目标后选择最小方案）。
- 支持 `--max-ms key=value` 阈值，超阈非零退出；不写仓库外文件。
- 不在 CI 使用（仓库无 CI），作为本地回归工具。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机：材料改名/移入回收站/归档后 ⌥⌘Z 撤销；基线下限检查与本机实测数值。
- 取不到的项目写明原因。

## 已知边界

- 撤销栈仍是单会话内存，重启即清。
- 无障碍只做标签与分组，不做 VoiceOver 实机走查。
- 基线脚本只测固定操作，不做 UI 帧率。

## 链接

- `docs/product/reference-products.md` 第 9.5 节
