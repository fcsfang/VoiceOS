# 波 37：复盘闭环、首页整理入口与跨材料想法

来源：发现者 D2（首页最近阅读与复盘回路）。三条都零 schema，全部复用既有数据与写通道。

## 完成判据

1. 每周回顾「本周完成」：未记录结果的行提供就地「记录结果」入口（复用现有结果编辑组件与 saveFeedback 写通道，命令幂等），保存后该行状态即时更新、不再显示待补结果；有结果的行行为不变。
2. 首页读器遇到无想法的材料时，显示「整理这份材料」入口，调既有 reidentify 通道（守卫：模型已配置且材料非 localOnly），处理中禁用并显示状态；材料页原有入口保留。
3. 首页时间线上方新增「最近想法」段：把近 14 天各材料的想法按天聚合展示（纯函数、零 schema），每条可打开原话（复用 openOriginal/openSpan 通道），空数据整段隐藏；与现有时间线选中与恢复互不干扰。
4. 首页「任务进展」组头显示「N 项结果待填」徽标（口径 visibleOutcomeFollowups，N=0 时不显示）。
5. swift build -j 2 与 swift test -j 2 一次通过（454 项基础上新增聚合纯函数测试）。

## 共享契约

- 结果写通道：只用现有 saveFeedback 与 OutcomeFollowup 组件（WorkspaceActivityViews 的既有内联编辑器），不新建写路径、不改核心。
- 聚合纯函数放 VoiceOSCore（RecentContent 相关文件），输入取现有 home snapshot 数据；不得引入 schema 或持久化。
- 「最近想法」段与时间线共享选中状态时必须避免互相覆盖：段内点击直接打开 span，不改变时间线选中。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| V1 复盘闭环 | `work/m37-v1` / `.worktrees/m37-v1` | `Sources/VoiceOSApp/WeeklyReviewView.swift`、`Sources/VoiceOSApp/WorkspaceActivityViews.swift` | 判据 1 |
| W1 首页 | `work/m37-w1` / `.worktrees/m37-w1` | `Sources/VoiceOSApp/RecentContentHome.swift`、`Sources/VoiceOSCore/RecentContent.swift`、`Tests/VoiceOSCoreTests/RecentContentHomeSnapshotChecks.swift` | 判据 2、3、4 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- V1：就地面板一次只展开一行（与任务详情 f 键行为对齐）；写成功后刷新，失败显示原因；不要把 78 项全塞进周回顾，只给该行入口。
- W1：「整理这份材料」按钮放在读器空态；reidentify 的处理器在 VoiceOSApp（模型配置名/清除标志已存在），失败时显示 model.status。最近想法段用按天分组（日期 + 条数），每条标题一行截断、来源名小字；纯函数签名与测试在核心。
- W1 首页任务进展组头徽标：用 model.visibleOutcomeFollowups.count；与波 35 行动页徽标同口径。

## 验证基线

- 实时库：52 份可用材料 13 份无想法；完成 80、有结果 9（缺 71）；近 7 天完成 21。
- 用户可能在用机器：界面实拍与重启进空闲窗口。

## 结果（完成后填）
