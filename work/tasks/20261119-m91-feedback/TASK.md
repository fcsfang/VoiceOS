# 波 91 任务书（2026-11-19）：失败反馈就地化

## 背景（发现者 B 报告 B1 剩余部分）

- 任务详情主按钮（标记已完成/不再跟进/改天）失败只写页面私有 `error`，渲染在长页最底部（折叠区之后）。`WorkspaceActivityViews.swift:618`、按钮区 `:424-480`。
- 材料归档/移入回收站失败只写全局 `status`，材料列表完全看不到，行内 spinner 停止后无反馈。`VoiceOSApp.swift:203-217`、`MaterialManagementView.swift:58-64`。
- 全局 `error` 条无重试/关闭，且任何导航都会清空（`WorkspaceView.swift:546,2461-2464`），错误可能在用户看到前消失。

## 完成判据

1. 任务详情（WorkspaceTaskView/WorkspaceDeliveryView）主操作失败时，在该按钮组附近显示行内错误（warning 色 + 简短原因），提供「重试」按钮（重复该操作）；页面底部全局 error 展示保留不动，但不再承担唯一反馈。
2. 材料归档/回收站：失败在材料行就地反馈（行内文字或 toast），不依赖全局 status；成功保持现状。
3. 不引入新的全局状态通道；所有反馈复用既有模型错误字段或本地 @State。
4. 行为、标识、键盘零变化（除新增文案与重试按钮）；不加迁移。
5. 测试 ≤2（纯逻辑，中文断言，如失败文案映射）；build/test 真实退出码 0（基线 635）。
6. 结果给 file:line 清单与判据落点。

## 文件所有权

`Sources/VoiceOSApp/WorkspaceActivityViews.swift`、`Sources/VoiceOSApp/MaterialManagementView.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`（仅错误映射，最小增量）、对应测试。不碰其他文件。

## 约束

16GB：锁 `/tmp/voiceos-swift-build.lock`；先 merge main；不写实时库；不重启应用；不 push、不合并。分支 `work/m91-feedback`。

## 结果

- 分支：work/m91-feedback（基于 main 666b14c；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：ac4706d「fix(反馈): 任务详情与材料操作失败就地可见并可重试」（5 文件，173 增 22 删）。docs 提交为本文件补记。
- 归因（任务书背景与判据，行号为改动后）：
  - 任务详情主按钮：`Sources/VoiceOSApp/WorkspaceActivityViews.swift:242` 新增本地 `mainActionFailure`；`983-987` 的 `noteMainActionFailure` 经 `InlineFailurePresentation` 生成简短文案；按钮组下方 `518-525` 就地渲染 warning 文案与「重试」。失败写入点：`995`（标记完成/重新跟进）、`1014`（打开日期与提醒）、`1022`（不再跟进/放下）、`1030`（留到以后）、`1038`（重新跟进/重新打开）、`826`（想清楚/标记达成）。页面底部既有 `error` 展示未动。
  - 交付页主操作：`WorkspaceActivityViews.swift:75` 起在按钮组下方渲染同一警告与「重试」；`107-127` 新增 `retryExecution` 与 `attachToTopic`，按钮改为调用它们（`73`、`93`）；底部 `error` 展示保留。
  - 材料行反馈：`Sources/VoiceOSApp/MaterialManagementView.swift:92-102` 把操作失败原因写入本地 `Failure`；完整样式在按钮行下显示文案与「重试」（`42`、`77-83`），列表胶囊内显示「操作名 + 失败」与「重试」（`62-68`，完整原因在 `.help` 与辅助功能标签）。操作名映射在 `85-90`。成功文案不变。
  - 错误映射：`Sources/VoiceOSApp/VoiceOSApp.swift:203-224` 的 `manageMaterial` 改为一并返回失败原因（`@discardableResult`，成功仍写既有 `status`）；`5173-5177` 的 `retryAssistant` 返回 Bool。其余调用点靠 discardable 保持原样。
  - 纯逻辑文案：`Sources/VoiceOSCore/InlineFailurePresentation.swift:5-22`，取原因首行、空原因回落「请重试。」、超过 60 字截断。
- 测试：`Tests/VoiceOSCoreTests/InlineFailurePresentationChecks.swift:4-19` 两项纯逻辑测试（操作名加原因映射；单行截断与空原因回落），断言为中文。
- 验证：merge_exit=0；build_exit=0（`swift build -j 2`，`Build complete! (111.02s)`）；test_exit=0（`swift test -j 2`），637 项 0 失败（基线 635 加新增 2），44.04 秒。构建与测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir），已释放；`git diff --check` 退出码 0；未写实时库、未重启应用、未 push、未合并。
- 判据落点：
  - 判据 1：任务详情与交付页主操作失败在按钮组附近显示 warning 文案与「重试」，重复原操作；底部错误展示未动。
  - 判据 2：材料归档、移入回收站、恢复失败在材料行就地可见并可重试，不再依赖全局 `status`；成功保持现状。
  - 判据 3：无新全局通道，全部用本地 `@State` 与既有 `model.status`、`model.assistantStatus`。
  - 判据 4：除新增文案与重试按钮外，行为、标识、键盘未变；未加迁移。
  - 判据 5：测试 2 项，纯逻辑，中文断言；真实退出码见验证。
  - 判据 6：file:line 见上。
- 所有权说明：新增的纯文案映射放在 `Sources/VoiceOSCore/InlineFailurePresentation.swift`，超出任务书文件清单。原因与波 89 相同：XCTest 目标只依赖 VoiceOSCore 与 VoiceOSPlatform，`VoiceOSApp` 是可执行目标，纯逻辑放在 App 文件里无法被测试；替代是改 `Package.swift`（改动面更大）或不加测试（与判据 5 冲突）。
- 遗留风险：
  - 材料列表的紧凑控件位于行尾悬停胶囊，可见性由 `WorkspaceView.swift:2894` 的 `MaterialMenuRow`（`2912` 的 `opacity`）控制，失败文案与重试随胶囊显示，鼠标移开后收起。要常驻需改 `WorkspaceView.swift`，不在本波所有权内。
  - 交付页「取消代办」与任务页子任务、预计时长、反馈保存等非主按钮操作仍只写页面底部 `error`，不在本波点名的失败区域。
  - 移入回收站的重试不再二次确认（首次操作已确认）；完成类重试按当前状态重新计算目标状态。
- 注释复查：Comment Sicko 报告 0 删除、0 MUST KILL，保留 `InlineFailurePresentation` 的公共 API 文档注释 1 处。
- 未执行：deslop（cursor-team-kit 插件未安装）；未做运行期点击验证（约束不重启应用）。

