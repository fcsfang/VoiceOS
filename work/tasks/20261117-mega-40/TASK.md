# 波 40：跟进回执摘要持久化、搜索键盘摩擦

来源：发现者 B（启动解码 51.9MB 跟进 JSON，M）与 E（搜索返回后焦点丢失、方向键需先 Enter，S）。

## 完成判据

1. 启动不再解码全部 followup_json：写路径生成「回执摘要」（失败原因、retryAt、状态等 UI 所需字段，版本化）随跟进写入持久化（迁移 67 加列或小表）；启动快照读摘要，不再解析全文；旧数据在迁移时一次性回填（报告记录耗时与体积）。
2. 摘要与原文一致性：跟进新写入 / 重试 / 成功 / 失败各路径都更新摘要；摘要缺失或版本不符时回退解析原文并补写（自愈）。
3. 搜索：从结果返回后列表焦点保留（不因搜索框重新聚焦而丢失方向键可用性）；方向键在字段聚焦且结果非空时直接移动选中，无需先 Enter；搜索历史只在真正打开结果时写入（输入过程不写）。
4. swift build 与 swift test 真实退出码 0（471 项基础上新增一致性测试）。

## 共享契约

- R1：摘要结构 `FollowupReceiptDigest`（Codable、含版本号）；存储列/表名由实现选定并在报告记录；不改 `followupDigest`（sha）语义；不改变任何 UI 数据通道的字段含义。
- U1：只动搜索页键盘与焦点逻辑；不改变 180ms 防抖、不改变结果查询与过滤。
- 无冲突文件：R1 全部在核心与快照；U1 在 WorkspaceView 搜索段。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| R1 回执摘要 | `work/m40-r1` / `.worktrees/m40-r1` | `Sources/VoiceOSCore/Database.swift`、`Sources/VoiceOSCore/RecordingFollowup.swift`、`Sources/VoiceOSCore/WorkspaceSnapshot.swift`、`Sources/VoiceOSCore/Store.swift`（如需）、`Tests/VoiceOSCoreTests/`（跟进相关） | 判据 1、2 |
| U1 搜索键盘 | `work/m40-u1` / `.worktrees/m40-u1` | `Sources/VoiceOSApp/WorkspaceView.swift` | 判据 3 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- R1：迁移照 65/66 模式（幂等守卫）；回填在迁移事务内逐行解码写摘要（51.9MB 一次性，接受首启变慢一次）；读路径回退到原文解析的条件写清楚；测试覆盖摘要写读一致、版本失效回退、重试路径更新。
- U1：定位提示（发现者 E）：WorkspaceView.swift 约 1394-1398（返回后 100ms 搜索框聚焦）、2142-2153（方向键处理需 searchListFocused）、1488 防抖；最近搜索写入点在打开结果处收敛。
- 协调者纪律：构建与测试后台直跑并记录真实退出码。

## 验证基线

- followup_json 43 行 51,956,156 字符、最大单行 6,175,099，实测 parse 33ms/6.2MB 行（发现者 B）。
- 锁屏时界面实拍留待解锁。

## 结果（完成后填）

## 结果（2026-11-17 夜）

- R1：迁移 67 增加 `sources.followup_receipt_digest`（版本 1 摘要：result、thoughts/goals/tasks、state、error、retryAt、retryCount、responseIDs、createdAt，剥离逐字稿与 spans），迁移内一次性回填；所有写路径经 saveRecordingFollowup 同步摘要；读路径摘要命中不回读正文，缺失/版本不符回退解析并自愈。测试 5 条（命中不读正文、回填补写、版本失效回退、重试各阶段同步、迁移幂等与首次读取）。
- U1：搜索键盘根因修复——字段编辑器吞方向键，改为搜索页本地事件监听拦截；↑↓ 在字段聚焦且结果非空时直接步进选中，Enter 打开选中项或首项；最近搜索只在打开结果时写入。
- 验证（真实退出码）：swift build 0（Build complete! 66.04s）；swift test 0，476 项 0 失败（471 基础上新增 5）。
- 隔离副本（schema 66 的实时库快照）：首启自 66 升至 67，43 条正文全部回填摘要（43/43），跟进段首读 695.6ms；二启摘要命中 167.0ms（此前每启全量解析 51.9MB 约 0.3-0.6 秒，推断值，今有实测对比）。
- 事故记录：隔离验证脚本误杀正式应用一次（kill 列表含正式 PID），已在两分钟内恢复（新 PID 22714），无数据损失。
