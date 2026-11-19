# 波 101 任务 B：首次引导末步加「开始前检查」清单

分支 `work/m101-onboarding`（基于 main 4211b87，已 merge main，无额外变更）。

## 目标
首次引导五步原先只有说明文字，不覆盖模型配置、权限与外部依赖。末步新增一张状态清单，读取真实配置状态，每项给出可执行动作；任何未完成项都不阻塞「开始使用」。

## 改动 file:line
- `Sources/VoiceOSApp/Onboarding.swift:1-4`：新增 `AppKit`、`AVFoundation`、`VoiceOSPlatform` 导入，用于系统设置深链、麦克风授权与提醒事项状态读取。
- `Sources/VoiceOSApp/Onboarding.swift:21-25`：`OnboardingView` 接收 `@ObservedObject model: ControlCenter`，新增麦克风授权 `@State`，初始值来自本文件私有 helper。
- `Sources/VoiceOSApp/Onboarding.swift:78-80`：`stepExtra` 仅在末步（id 4）插入 `readinessChecklist`；前四步文案与内容不变。
- `Sources/VoiceOSApp/Onboarding.swift:83-110`：清单五行的组装与 `.task` 刷新。文本模型读取 `textModelConfigured`，未配置时调用 `model.chooseTextModel()`；本地语音读取 `speechConfigured`，未配置时路由到设置页；麦克风、提醒事项、系统通知分别读取真实状态。
- `Sources/VoiceOSApp/Onboarding.swift:112-123`：麦克风行。`authorized` 显示已就绪；`notDetermined` 给「授权」并调用 `AVCaptureDevice.requestAccess(for: .audio)`；`denied`/`restricted` 给「打开系统设置」并深链 `Privacy_Microphone`。
- `Sources/VoiceOSApp/Onboarding.swift:125-134`：提醒事项行。`reminderAccess.enabled` 且 EventKit 为 `fullAccess` 时显示清单名；系统权限被拒绝时给「打开系统设置」深链 `Privacy_Reminders`；否则显示「未连接」并给「打开设置」。
- `Sources/VoiceOSApp/Onboarding.swift:136-145`：系统通知行。复用现有 `noticeAuthorization` 三态与 `noticeAuthorizationDetail` 文案；仅 `denied` 时给「打开系统通知设置」。
- `Sources/VoiceOSApp/Onboarding.swift:147-173`：本文件私有 helper，集中读取麦克风与提醒事项授权、请求麦克风授权、跳转应用设置页及两个系统设置深链。未新增平台文件。
- `Sources/VoiceOSApp/Onboarding.swift:194-220`：私有 `OnboardingCheckRow`。每项一行，ready 用 `checkmark.circle.fill` 与强调色，未完成用中性 `circle`；可选动作按钮随行展示。
- `Sources/VoiceOSApp/Onboarding.swift:243`：sheet 构造传入 `model`，其余完成逻辑不变。

## 取舍
- 清单不新增模型基础设施：五项状态各有来源，直接逐行读取比造统一状态表更小；行组件只统一布局。
- 文本模型按任务口径直接调用 `chooseTextModel()`。本地语音没有直接弹出选择器，因为模型配置入口在设置页，任务允许「按钮跳到设置页」；跳转先 `finish()` 关闭引导，再设置 `pendingWorkspaceRoute = .settings`。
- 提醒事项未连接时跳到应用设置页，而不是直接调用 `connectReminders()`；设置页已有清单选择与暂停连接的完整流程，避免在引导里复制授权选择状态。系统权限已拒绝时才直接深链系统设置。
- 通知处于未请求态时只展示现有文案，不主动请求权限；现有产品行为是第一次完成长任务时询问一次。
- 「开始使用」按钮、步骤点、键盘默认动作、既有标识和五步文案均未改动。

## 无法直接操作的项及原因
- 本地语音未配置：只能展示「在设置 › 模型与服务中配置」并给「打开设置」。配置需要文件选择与持久化，入口在设置页；引导内没有复制该流程。
- 系统通知未请求：不提供直接请求按钮。现有逻辑在第一次完成长任务时询问一次；提前请求会改变既有授权时机。
- 提醒事项未连接：给「打开设置」而非直接连接。清单授权需要用户选择明确清单并保存版本化访问记录，由设置页承担；引导只负责指路。
- 麦克风被拒绝：macOS 不允许应用再次弹窗，只能深链系统设置，由用户手动允许。

## 测试与真实退出码
- `swift build -j 2; echo build_exit=$?` → `build_exit=0`（在 `/tmp/voiceos-swift-build.lock` 下执行，锁在本命令结束时释放）。
- `swift test -j 2; echo test_exit=$?` → `test_exit=0`，`Executed 654 tests, with 0 failures (0 unexpected)`（基线 654，未新增测试）。
- `git diff --check` → 退出码 0。
- 构建日志中本文件只有编译行，无本文件产生的警告或错误。
- 本轮测试结束后 23:01:33，另一并发进程（PID 8246，同款锁脚本）取得 `/tmp/voiceos-swift-build.lock`；该锁不属于本任务，未删除。

## 遗留风险
- 未启动应用做真实 UI 验证（按要求不重启）。编译与 654 项既有测试通过，但清单在引导 sheet 内的实际排版、系统弹窗、`NSOpenPanel` 覆盖 sheet、设置页跳转未在真机点击验证。
- 通知授权状态在清单出现时异步刷新一次；用户停留在 sheet 内修改系统通知设置后，行文案不会自动更新，需重新进入末步。
- 提醒事项授权在渲染时采样，未监听 EventKit 变化；授权在 sheet 打开期间变化时同样需重新进入末步。
- 设置页跳转依赖 `WorkspaceView` 既有的 `pendingWorkspaceRoute` 消费路径；本次未改该路径，也未做运行时验证。
- 清单新增五行会增高末步 sheet；未设置固定高度，依赖 SwiftUI 自适应，未实测小屏幕表现。