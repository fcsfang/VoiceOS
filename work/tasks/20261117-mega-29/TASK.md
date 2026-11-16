# 并行波 29：全景分片复用、无障碍修复、主题页首屏与变更历史

来源：全景失败根因调查（21 次尝试 0 成功）与键盘无障碍审计（12 条），加主题页发现剩余项。

## 数据事实

- 全景主因：重试复用边界停在整单元；三个超大单元（20041/26900/34198 字符）跨 21 次尝试从未复用，53 条瞬时上游错误反复触发全量重跑，最后以「N 个完整单元未能核对」聚合抛出。引文缺失为模型非逐字输出（约 18%），转写更正是另一条「依据已变化」失败（约 18%）；两者都因版本失效放大代价。
- 无障碍：材料行与行动行的「⋯」菜单只在 hovered 时创建（键盘与读屏不可达）；focusRing 浅色 2.2–2.4:1（需 3:1）；⌘1–5 与 ⌘[ 视图层与菜单层双注册；tertiary 小字 3.0–3.5:1（需 4.5:1）；减少动态效果设置全仓未读取。
- 主题页概览不显示阅读卡片（首屏像目录不像内容）。

## 完成判据

1. 全景分片级复用：`PanoramaSliceGenerationInput` 携带 evidence 键，已完成分片跨尝试复用；失败单元只重跑失败分片。分片生成只下发 target 内的观点（原文仍全量），消除 target 外观点归属这一确定性拒绝类。测试覆盖两个场景：两个输入仅差无关来源文本时已完成分片不新增步骤；target 外观点不再导致单元失败。
2. 行菜单键盘与读屏可达：材料行与行动行「⋯」菜单常驻渲染（视觉用 opacity 保留悬停观感，命中与 AX 始终可用）。
3. 焦点环对比 ≥3:1（focusRing 用 accent 或 ≥0.85 不透明度）；tertiary 小字 ≥4.5:1 或功能信息改用 secondaryText。
4. ⌘1–5 与 ⌘[ 只保留菜单注册，删除视图层快捷键。
5. 减少动态效果被尊重：toast 滑入与撤销条滑入在 reduce motion 下不动画；侧栏导航项有选中语义（isSelected）；清空搜索与 toast 关闭按钮命中区域 ≥24×24。
6. 主题页概览首屏直接显示前 2–3 张阅读卡片（按钮改为「查看全部 N 张卡片」）。
7. 任务详情加「变更历史」折叠区：ActionStore 提供只读 actionRevisions(actionID:)，列出状态、备注、操作者、时间（先不做恢复按钮）。
8. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（423 项基础上新增）。

## 共享契约

- 全景分片复用：复用键 = 分片输入 JSON 的 digest + evidence 键；`panorama_steps` 的读取按 attempt 键（现状）扩展到 evidence 键复用已完成分片；`PanoramaSliceGenerationInput` 增字段不改表。
- 无障碍：`WorkspaceTheme` 的 focusRing 与 tertiaryText 是唯一调色入口，改令牌不改调用点；reduce motion 用 `@Environment(\.accessibilityReduceMotion)` 在修饰器内读取。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| U 全景修复 | `work/m29-u` / `.worktrees/m29-u` | `ThoughtPanoramaStore.swift`、`PanoramaSlicing.swift`、`ResponsesPanoramaPort.swift`、`PanoramaModelInput.swift`、其测试 | 判据 1 |
| V 无障碍修复 | `work/m29-v` / `.worktrees/m29-v` | `WorkspaceTheme.swift`、`WorkspaceView.swift`、`WorkspaceDesign.swift` | 判据 2、3、4、5 |
| W 主题页与历史 | `work/m29-w` / `.worktrees/m29-w` | `WorkspaceTopicReadingView.swift`、`ActionStore.swift`、`WorkspaceActivityViews.swift`、其测试 | 判据 6、7 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- U：根因调查已给出两处修复的位置（ThoughtPanoramaStore 单元循环的 manifest 校验按 scoped 输入；PanoramaSlicing 的 SliceGenerationInput 增 evidence 键；ResponsesPanoramaPort 的 claims 改用 payloadForScope）。单元 review 与 repair 的复用键保持 attempt 级；全局步骤的 evidence 键复用不动。修复后失败单元重试只补失败分片。
- V：行菜单改为常驻 `opacity(hovered ? 1 : 0.01)`？不行，需要 AX 可见：取「始终渲染但视觉透明」不改变观感也不破坏悬停提示的替代是常驻渲染 + `opacity(hovered || focused ? 1 : 0)`，focus 状态用 FocusState 或 onHover 同步；关键约束是 AX 树与 Tab 顺序里始终存在。若 SwiftUI 对 opacity(0) 元素仍保留 AX，则在行 focus 时提升不透明度。实现选择写进报告。
- W：概览卡片直接复用现有 readingCard 渲染（WorkspaceTopicReadingView 内已有），只改概览分支；变更历史用 action_revisions 的 note/actor/created_at/state，折叠区放在「记录与依据」附近；ActionStore 的读取 API 按 actionID 返回按时间倒序。

## 验证基线

- 实时库 panorama_attempts 21 条（17 failed、4 unknown、0 completed）；三个超大单元 UUID 跨尝试重复出现。
- 锁屏仍在，交互截图待解锁统一补拍。
