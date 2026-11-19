# 波 101 任务 A：设置页顺序与关键配置状态

分支 `work/m101-settings`，基于 `main` 4211b87（含波 99 与收件箱补丁）。两次提交。

## 改动

### 1. `Sources/VoiceOSPlatform/NativeDictation.swift`

- `:5` 新增公开枚举 `MicrophoneAuthorization`（granted / denied / notDetermined）。
- `:17` 新增只读查询 `NativeDictation.authorizationStatus()`，映射 `AVCaptureDevice.authorizationStatus(for:.audio)`；请求逻辑未改。

### 2. `Sources/VoiceOSApp/VoiceOSApp.swift`

- `:849` 新增 `@Published var reminderLastError`，连接/保存/暂停失败时写入，成功时清空。
- `:861` 新增计算属性 `reminderPermission`，暴露提醒事项四态所需的系统授权。
- `:1027` 新增 `@Published private(set) var microphoneAuthorization`。
- `:1045` `refreshMicrophoneAuthorization()`；`:1046` `requestMicrophoneAccess()`，触发系统请求后刷新状态。
- `:3388` / `:3397` 连接成功清空、失败记录最近错误。
- `:3408` / `:3414` 保存连接成功清空、失败记录。
- `:3429` 创建 VoiceOS 清单失败记录。
- `:3437` / `:3441` 暂停成功清空、失败记录。

### 3. `Sources/VoiceOSApp/WorkspaceView.swift`

- `:1699` `reminderConnectionStatus` 四态：需要授权 / 系统已拒绝 / 未连接 / 清单名。
- `:1706` `reminderReviewCount` = 链路异常 items + 回读失败 failures。
- `:1711` `microphoneStatus` 三态文案。
- `:1721` 标题后先放「模型与服务」；`:1729`「连接与自动入口」。
- `:1723` 文本模型副标题改为 `model.modelSummary`（文件名 · provider）。
- `:1731` 新增「消息监测」行，跳转监测页。
- `:1732` Apple 提醒事项行改为常显四态状态；`:1734` 最近错误以 warning 色显示。
- `:1739` 有异常时显示「N 条提醒待核对」，点击进入现有处理情况页。
- `:1741`-`:1750` 新增麦克风权限行：未请求「授权麦克风」、已拒绝「打开系统设置」、已允许仅状态文案；进入设置页时刷新。
- `:1758` / `:1769` 外观与键盘快捷键移动到模型、连接之后；`:1786` 资料与历史保持其后。

## 验证（真实退出码）

- `swift build -j 2`：`Build complete! (131.33s)`，`build_exit=0`
- `swift test -j 2`：`Executed 654 tests, with 0 failures`，`test_exit=0`
- 构建与测试共用锁 `/tmp/voiceos-swift-build.lock`；首次抢锁时被其他构建占用（age=324s），等待后取得。测试结束时锁目录已不存在，未残留。

## 遗留风险

- 「消息监测」行只能跳到监测页，不能直达其「设置」分段：`WorkspaceMonitorView.swift:25` 的 `showsSettings` 是视图内 `@State`，该文件归其他波，未改。
- `reminderLastError` 仅内存保存，下次成功操作会清空；重启后不再显示。
- 麦克风状态在进入设置页和发起授权后刷新；停留在页面时在系统设置中改动权限，需要重新进入才更新。
- 视图层改动，未加测试（基线 654 项保持 0 失败）。