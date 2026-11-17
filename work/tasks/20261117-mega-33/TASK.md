# 并行波 33：导入结果与失败留存、键盘覆盖最后一层、启动模板记忆

来源：材料导入、交互质感与任务执行三路发现的收尾项。

## 完成判据

1. 批量导入逐文件结果：一次导入多份时，结束显示逐文件列表（成功 / 失败原因 / 不支持的格式），不再只报最后一条错误；单份导入行为不变。
2. 核对失败跨重启留存：转写核对失败写入持久层（presentation 小字段或 sources.error，选择写进报告），启动时回填失败字典；处理页「完整转写核对未完成」重启后仍可见，重试成功即清除。
3. 长任务本地通知：批次或单份核对完成、导入处理完成时发本地通知（成功一句、失败带原因）；首次请求授权的时机与文案克制；无权限时退回菜单栏图标状态，不反复弹。
4. 主题网格键盘：↑↓ 在结构分区之间移动、Return 打开当前分区卡片、分区标题 header trait、卡片带「小主题：标题，N 条认识」标签。
5. 首页时间线键盘：↑↓ 选择材料并同步右侧阅读区、Return 打开材料、分线程标题 header trait；不影响现有鼠标选择与恢复逻辑。
6. 启动模板记忆：上次的 mode、allowCloud 与执行偏好经 AppStorage 继承，下次进入直接沿用；复制交付后提供「记下这一步」（打开结果记录或创建待办，选最简通道）。
7. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（441 项基础上新增）。

## 共享契约

- 失败留存：写点唯一（核对失败捕获处）；读取在启动装配处回填；清除在成功核对路径；不新增 schema，用 presentation JSON 内字段。
- 通知：UNUserNotificationCenter；授权请求只在首次有可通知事件前；通知文案含材料名与结果。
- 键盘：沿用行动列表的 FocusState + onKeyPress 模式；首页同步阅读区通过既有选中通道（RecentContentHomeSelection 或本地状态）。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| E1 导入与留存 | `work/m33-e1` / `.worktrees/m33-e1` | `VoiceOSApp.swift`、`RecordingPresentation.swift` | 判据 1、2、3 |
| F1 键盘覆盖 | `work/m33-f1` / `.worktrees/m33-f1` | `WorkspaceTopicReadingView.swift`、`RecentContentHome.swift` | 判据 4、5 |
| G1 启动模板 | `work/m33-g1` / `.worktrees/m33-g1` | `TaskInitiationView.swift` | 判据 6 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- E1：导入循环在 importFiles（VoiceOSApp）；失败留存避免新增表；通知若被系统拒绝，菜单栏已有的处理状态（查看处理）即退路，不重复求权。
- F1：首页键盘选中必须同步右侧阅读区与 RecentContentHomeSelection；时间线滚动跟随选中；不破坏恢复锚点逻辑。
- G1：AppStorage 键前缀 voiceos.initiation；「记下这一步」复用结果记录或创建待办的最小入口（先看现有通道再定）。

## 验证基线

- 实时库：79 材料、50 份核对含 26 份 239 疑点、失败核对（内存态）重启即失、主题网格 91 小节、首页 79 条时间线。
- 锁屏仍在，交互截图待解锁统一补拍。
