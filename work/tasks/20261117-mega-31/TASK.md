# 并行波 31：设置与数据健康、目标进展与详情键盘

来源：搜索设置专项与主题/行动发现的剩余项。数据事实：备份 7 份共约 1.9GB 但设置页只有一行状态，没有恢复入口与体检；模型配置摘要硬编码 `gpt-6.1-sol · provider`，路径不可见、无清除；62 个目标页只有「有没有下一步」，没有进展可视化；详情页全键盘不可达。

## 完成判据

1. 设置页「资料与历史」加「检查资料库」：一次点击跑完整性检查（integrity_check 与 foreign_key_check）、原件存在性扫描、最新备份 quick_check，结果一行中文（正常 / N 项问题并列出关键项）。
2. 备份恢复入口：设置页备份行旁「从最近备份新建资料库」——取最新备份 DB 加当前库的 assets 克隆组成新根，走既有新库+新窗口流程；成功后在 Finder 指向新库或给出路径；不触碰现库。
3. 模型配置可观察：设置页模型行显示配置文件名字，悬停显示完整路径，行菜单加「更换配置…」与「清除配置」；清除后摘要复位、modelConfigured 变为 false、相关入口按未配置处理。
4. 目标进展：目标详情页头显示「下一步 N · 已完成 M · 最近推进于 X」（数据来自子行动、完成修订与反馈，只读派生）；无数据时显示「还没有下一步」，与行动页停滞横幅口径一致。
5. 详情键盘：任务详情支持 x/空格 完成、s 改期（打开既有改期通道）、f 记结果（打开结果记录）；问题与目标详情保持现状；按键提示并入现有快捷帮助。
6. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（428 项基础上新增）。

## 共享契约

- 体检：复用 VoiceOSStore.integrityCheck、DatabaseBackup 的 quick_check 与 sources 原件枚举；不改表。
- 从备份新建：backup 目录里最新文件为 DB；新根目录 = 备份 DB 复制（clonefile 失败回退普通复制）+ 当前 assets 克隆；沿用迁移包恢复的新窗口流程（自寻现有实现），失败给中文原因。
- 模型配置：配置摘要与路径均从现有存储读取（自寻 LocalTextModel 配置文件位置），清除调用既有断开路径或新增 store/model 方法（文件所有权内）。
- 目标进展：ActionStore 增加只读 `goalProgress(actionID:)`（nextSteps、completedSteps、lastActivityAt），按 parent_id 子行动与 action_revisions 派生；详情页只消费。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| C1 设置与数据健康 | `work/m31-c1` / `.worktrees/m31-c1` | `WorkspaceView.swift`、`VoiceOSApp.swift`、`DatabaseBackup.swift` | 判据 1、2、3 |
| C2 目标进展与详情键盘 | `work/m31-c2` / `.worktrees/m31-c2` | `ActionStore.swift`、`WorkspaceActivityViews.swift`、其测试 | 判据 4、5 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- C1：「从最近备份新建资料库」必须带 assets（备份只含 DB），否则材料会被完整性检查隔离；新窗口流程复用 PackageRestoreView 的既有实现。体检输出要可复跑（同一按钮再点刷新）。模型配置清除要同时复位菜单栏/助理入口的可用性。
- C2：goalProgress 的 completedSteps 以 parent_id 指向该目标且 state=completed 的行动计数；lastActivityAt 取该目标与其子行动修订的最大 created_at。详情键盘用 @FocusState + onKeyPress 挂在整页，不劫持文本框输入；按键只在无文本焦点时生效。

## 验证基线

- 实时库：备份 7 份约 1.9GB、62 个目标（0 个子行动）、18 条开放待办、模型配置存在且 AI 入口可用。
- 锁屏仍在，交互截图待解锁统一补拍。
