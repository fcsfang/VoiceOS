# 波 95 任务 A：材料列表行价值化与「需要查看」计数口径统一

## 背景

用户要材料列表扫一眼就知道这份材料带来什么提醒、什么帮助，并且界面上的数字可信。发现者用真实数据证实：材料行副标题堆着日期、表达来源、仅本地、分组提示等过程元数据；行尾只有疑点/在读，没有待办数；侧栏「有 185 项需要查看」实际是 183 条转写疑点加 2 个布尔，处理页「转写疑点」badge 却显示 24 份材料；提醒事项 badge 是未回读加失败的总和，副标题只写未回读；材料行操作失败的胶囊只在悬停时可见。

## 改动

### Core（构建期预计算，查询 O(1)）

- `Sources/VoiceOSCore/RecordingContext.swift:108` `SourcePageIndex.openActionIDsBySourceID`：按来源保存开放任务的 id 集合。
- `Sources/VoiceOSCore/RecordingContext.swift:179` 构建期一次遍历非 dismissed 行动，只收 `kind=task`、`state=open`、`validity=current` 且未被暂停核对的行动，按 claim 引用的来源去重入索引。
- `Sources/VoiceOSCore/RecordingContext.swift:257` `openActionCount(for:)`：按来源集合合并集合并计数；组合材料行对成员来源取并集，同一行动只计一次。视图逐行查询为字典读取。

### 材料页

- `Sources/VoiceOSApp/WorkspaceView.swift:1889` 副标题只保留日期；`我的表达/外部资料/AI 交付`、`仅本地`、`分组待重新判断` 折入 `:1894` 的行级 `.help`。
- `Sources/VoiceOSApp/WorkspaceView.swift:1890` 行尾优先显示 `N 条待办`（`:1891`）；有疑点时保留 `· 疑点 N` 后缀；无待办时回退到原「疑点/在读/已读」。
- `Sources/VoiceOSApp/WorkspaceView.swift:2892` `MaterialMenuRow` 读取失败偏好 `MaterialRowFailurePreferenceKey`（`:2923`），失败后紧凑菜单保持可见（`:2903`、`:2917`），重试入口不再随鼠标移开消失；成功路径仍是悬停或键盘聚焦才显示。
- `Sources/VoiceOSApp/MaterialManagementView.swift:69` 只新增一行偏好发射（`failure != nil`），沿用该文件已有的 `Failure` 本地状态与 `InlineFailurePresentation` 文案。这是本波唯一超出文件所有权清单的改动，原因见下。

### 处理页与侧栏口径

- `Sources/VoiceOSApp/WorkspaceProcessingView.swift:80` `WorkspaceAttentionSnapshot` 增加 `transcriptIssueCount` 与 `otherCount`；`:201` 从现有分解派生，没有新增扫描。
- `Sources/VoiceOSApp/WorkspaceView.swift:248` 侧栏文案改为带单位分解：`转写疑点 183 · 其他 2`；只有其他事项时保留 `N 项需要查看`。
- `Sources/VoiceOSApp/WorkspaceProcessingView.swift:478` 「转写疑点待核对」badge 从材料份数改为疑点条目数，与副标题和侧栏同单位。
- `Sources/VoiceOSApp/WorkspaceProcessingView.swift:545` 提醒事项副标题同时列出未完成回读与回读失败；badge 仍是两者之和，文案与计数一致。

### 测试

- `Tests/VoiceOSCoreTests/MaterialRowTodoCountChecks.swift:49` 材料行只计当前开放且未被暂停的任务；`:62` 已完成、已停止、历史记录与问题不计，`:63` 多材料引用各计一次，`:64` 暂停核对不计。
- `Tests/VoiceOSCoreTests/MaterialRowTodoCountChecks.swift:67` 组合材料行合并成员时按行动去重；`:72` 同一行动只计一次。

## 验证（真实退出码）

- `swift build -j 2; echo build_exit=$?` → `build_exit=0`。
- `swift test -j 2; echo test_exit=$?` → `test_exit=0`，`Executed 645 tests, with 0 failures`（基线 643，本波新增 2）。
- 首次构建在 `WorkspaceProcessingView.swift:547` 报 `type '()' cannot conform to 'View'`。原因是 ViewBuilder 分支内不能写赋值语句。改为单一三元表达式后重跑，构建与测试均通过。

## 口径选择与取舍

- 侧栏采用「转写疑点 N · 其他 M」。N 是现有 `transcriptReviewPoints` 的疑点条目和，M 是其余布尔与失败计数的和，点击仍进入同一处理页。
- 处理页转写疑点 badge 采用条目数而非材料份数。副标题继续写「X 份材料…Y 条疑点」，两处数字不再相差一个数量级。
- 材料行待办数的定义与行动页「我的待办」一致：task、open、current、未被暂停核对。组合材料按成员来源并集、按行动 id 去重。
- 行尾优先展示待办数，但保留疑点后缀。没有待办时回到原有阅读状态。
- 失败胶囊沿用 `MaterialManagementControls` 的私有 `Failure` 状态，只增加偏好发射。不复制操作逻辑，不新增持久化状态。

## 文件所有权例外

`Sources/VoiceOSApp/MaterialManagementView.swift:69` 新增一行 `.preference(...)`。该文件的 `Failure` 是 `@State private`，WorkspaceView 无法读取；若不发射失败偏好，材料行就无法在鼠标移开后保留失败与重试。改动只有这一行，未动操作、文案或状态结构。若父级要求严格不碰该文件，需要改为在 WorkspaceView 复制紧凑控件，代价是重复操作逻辑，故未采用。

## 遗留风险

- 未重启应用，未做真实 GUI 验证。失败胶囊常驻依赖 SwiftUI 偏好从 overlay 内容向上传播，代码路径与既有 `TimelineAnchorKey` 用法一致，但未在运行中的应用里肉眼确认。
- 失败偏好只在失败后保持。重试成功或行重建后恢复悬停显示。
- 归档或回收站材料若仍有开放任务，行尾也会显示待办数。当前数据下未观察到，属于口径一致而非特判。
- 未做迁移，未改 schema，未 push，未合并 main。
