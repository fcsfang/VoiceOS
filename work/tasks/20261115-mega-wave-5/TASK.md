---
status: done
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-5
owner: coordinator
---

# 并行大波第五批

## 目标

- 接线层补两处：外部完成确认后为重复任务生成下一次；App Intents 扩展「打开今天的行动」「打开搜索」。
- 菜单栏「今日一览」：列出今天与逾期的开放任务（各最多 3 条），点击打开对应任务页。用于替代 WidgetKit 小组件的核心价值；WidgetKit 因沙盒与 App Group 签名约束另行评估。
- 两轮只读审查回看第三、四批的新代码与产品一致性，产出下一批修复清单。

基线 `main` 为 `d12aec1`，schema 60，263 项测试。

## 单元

### J1 接线层：外部完成后继、意图扩展、今日一览

文件：`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSCore/ExternalActionCompletion.swift`、`Sources/VoiceOSApp/AppIntents.swift`、`Tests/VoiceOSCoreTests/RecurrenceChecks.swift`（追加）。

- 外部完成确认：登记完成成功后，若该行动仍有 `action_recurrence` 行，调用 `completeActionWithRecurrence`（alreadyCompleted 分支）生成下一次；行删除保证幂等。
- AppIntents.swift：新增 `OpenTodayActionsIntent` 与 `OpenSearchIntent`；端点协议加 `openTodayActions()` 与 `openSearch()`；`ApplicationDelegate` 实现为打开主窗口并发出导航请求。
- 导航：`ControlCenter` 增加 `@Published pendingWorkspaceTaskID` 与 `pendingWorkspaceSearch`；WorkspaceView 在任务出现时消费并跳到任务页，搜索请求打开搜索页并聚焦搜索框。
- 菜单栏「今日一览」：`menuNeedsUpdate` 里插入分区，逾期与今天各最多 3 条（用 `ActionTimeSurface` 口径，只取 task、state open、validity current），点击激活应用并跳任务页；当天没有任务时显示「今天没有待办」。
- 测试：外部完成生成后继；菜单条目挑选纯函数（若抽成函数）配测试。

### R1 新代码缺陷审查（只读）

范围：`Recurrence.swift`、`EntityIndex.swift`、`PortablePackage` 49/50、`Store.recover/reverifySource/importMedia`、`TextCapture` 去重、`VoiceOSApp` 的镜像/Spotlight/备份/剪贴板/文件夹监听、`AppIntents.swift` 与 `scripts/app/build.py` 元数据步骤、`FeynmanCompare`、`ReverifyControls`、撤销与重新跟进路径。输出按用户可见影响排序的缺陷清单。

### R2 产品一致性审计（只读）

对照 `docs/product/reference-products.md` 第 9 节与当前实现：重复任务与提醒联动语义、恢复核对与认知冻结文案、撤销与重新跟进的可发现性、今日一览缺位、空状态与错误文案。输出需要产品决定的清单与建议。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机：菜单栏今日一览条目与点击跳转；外部完成确认后出现下一次行动；意图元数据含三个意图。
- 取不到的项目写明原因。

## 已知边界

- 今日一览只读，不提供完成操作。
- WidgetKit 小组件不实现：小组件必须是沙盒 .appex，并靠 App Group 受限 entitlement 与应用共享数据；本机只有 Apple Development 签名、没有 provisioning profile，按现有签名链评估为高成本高风险（评估，非实测）。菜单栏今日一览承接「扫一眼今天的任务」的价值。
- 两个只读审查的修复留到下一批。

## 结果

2026-11-15 J1 与协调者修复集成到 `work/mega-5`：J1 `2d72791`（原 `755bf9b`），协调者修复与测试修正随后。两轮只读审查返回 12 条缺陷与 10 条产品问题。

集成期直接修复：外部完成的冻结态行动允许生成重复后继；重新核对不复活已回收来源；抓取提交后标题与元数据失败降级为日志；Spotlight 首次索引前清理域内旧条目；文件夹监听连续失败三次后跳过并指数退避；恢复包校验 `task_initiations`；实体索引随转写版本刷新并可自愈；待核对空状态与处理问题分离；构建脚本元数据步骤容错并修正版本解析。

`swift build -j 2` 通过；`swift test -j 2` 264 项 0 失败（新增外部完成等价后继测试）。

发行构建：元数据零告警，`extract.actionsdata` 含 `CaptureTextIntent`、`OpenTodayActionsIntent`、`OpenSearchIntent` 三个意图；隔离副本冒烟启动正常。锁屏环境下菜单今日一览点击、Shortcuts 动作发现与 VoiceOver 不可得。

留到第六批：重复任务与提醒事项联动的两处语义缺陷（外部完成不生成后继的上游路径、同标题屏障拦截后继同步）、重复完成后的撤销级联、意图冷启动就绪等待、全景六表进迁移包、产品文案与可发现性十条。

## 链接

- 2026-11-15 已合并为 `118e0bb`（PR #162）。

- `docs/product/reference-products.md` 第 9.2、9.4、9.5 节
