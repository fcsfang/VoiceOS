# 波 73 任务书（2026-11-18）：voiceos-check ax 子命令（应用自带操控通道）

## 背景（调研结论 2026-11-18，用户需求 #1 的杠杆）

调研推荐的主通道：把确定性下沉到应用侧，扩展 voiceos-check 提供 AX 子命令（AX dump / click --identifier / set-value / wait / scroll-to），配合 accessibilityIdentifier（波 70/71 已铺），让 agent 不依赖第三方 MCP、不靠截图 grounding、输出 JSON 可断言。实测佐证：裸 AX 脚本按 `nav.monitor` 标识 AXPress 一次打开监测页；容器标识掩蔽问题波 71 在修。

CLI 结构：`Sources/VoiceOSCheck/Check.swift` 以 `<command> <data-dir> ...` 分发并在开头构造 VoiceOSStore；ax 子命令不需要 data-dir，需在 store 初始化前分支（参照 `ingest-podcast` 的处理方式）。

## 完成判据

1. 新增子命令组（在 store 初始化前分派，无需 data-dir；usage 同步更新）：
   - `voiceos-check ax dump --pid <pid> [--identifier <前缀>] [--json]`：遍历目标应用 AX 树，输出 role、identifier、title、description、value、frame（x/y/w/h）、可用动作；`--json` 输出单个 JSON 对象（含 `elements` 数组与 `truncated` 标志），默认给摘要文本。
   - `voiceos-check ax click --pid <pid> --identifier <id>`：找到元素后优先 `AXPress`，无该动作时返回明确错误（不盲点坐标）。
   - `voiceos-check ax set-value --pid <pid> --identifier <id> --value <text>`：写 `AXValue` 并回读校验，不一致报错。
   - `voiceos-check ax wait --pid <pid> --identifier <id> --timeout <秒>`：轮询至出现（默认 5 秒，100ms 间隔）。
   - `voiceos-check ax scroll-to --pid <pid> --identifier <id> [--max-pages N]`：在包含该标识所在滚动容器（或最大 AXScrollArea）上逐页 `AXScrollDownByPage`，出现即停（解决 SwiftUI 懒加载）。
2. 健壮性：对每个 AX 元素设置 1.5 秒 messaging timeout；`kAXErrorCannotComplete` 重试一次；`kAXErrorInvalidUIElement` 重新获取元素一次；不无限重试。退出码：0 成功；2 未找到；3 AX 错误（stderr 给中文原因）。
3. 纯逻辑进库、命令薄壳：AX 驱动与参数解析放 `Sources/VoiceOSPlatform/AXDriver.swift`（可单测），`Sources/VoiceOSCheck/AXCommands.swift` 只做接线与输出。
4. 测试（≤3 个，纯逻辑，中文断言）：参数解析（dump/click/wait 的必填与默认值、未知选项报错）；元素记录的 JSON 编码字段齐全；identifier 前缀过滤逻辑。
5. `swift build -j 2` / `swift test -j 2` 真实退出码 0（先 merge main；基线以合并波 71/72 后为准，至少 610）。
6. 结果里给 coordinator 一条实机验证命令序列（安装后：`ax dump --identifier nav.` 应见 7 个；`ax click --identifier nav.monitor`；`ax dump --identifier monitor.runCheck`）。

## 文件所有权

- `Sources/VoiceOSCheck/Check.swift`（仅分派与 usage 增量）
- `Sources/VoiceOSCheck/AXCommands.swift`（新）
- `Sources/VoiceOSPlatform/AXDriver.swift`（新）
- `Tests/VoiceOSCoreTests/AXDriverChecks.swift`（新）
- 不碰 App 视图（波 71 领地）、不碰 Core 提醒相关文件（波 72 领地）、不碰 ArticleExtractor；不加迁移。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；不重启应用；不 push、不合并、不重建 dist。
- 分支 `work/m73-axcli`，提交回报。

## 结果（2026-11-18）

分支 `work/m73-axcli`，代码提交 `7cb7e20`。本结果所在提交为第二个 docs 提交。

### 子命令与用法

- `voiceos-check ax dump --pid <pid> [--identifier <前缀>] [--json]`：遍历目标应用 AX 树，输出 role、identifier、title、description、value、frame、actions。`--json` 输出单个对象，含 `elements` 数组与 `truncated` 标志。
- `voiceos-check ax click --pid <pid> --identifier <id>`：优先 `AXPress`。元素没有该动作时报错，不点坐标。
- `voiceos-check ax set-value --pid <pid> --identifier <id> --value <文本>`：写 `AXValue` 后回读，不一致报错。
- `voiceos-check ax wait --pid <pid> --identifier <id> [--timeout <秒>]`：默认 5 秒，100ms 轮询。
- `voiceos-check ax scroll-to --pid <pid> --identifier <id> [--max-pages <页数>]`：在最大 `AXScrollArea` 上逐页 `AXScrollDownByPage`，默认最多 10 页。
- 退出码：0 成功，2 未找到，3 AX 错误，1 参数错误。错误写 stderr，中文说明。

### 判据落点

- 判据 1：子命令组在 store 初始化前分派（`Sources/VoiceOSCheck/Check.swift`），不需要 data-dir，usage 同步两行。dump 支持前缀过滤与 `--json`。
- 判据 2：每个元素设置 1.5 秒 messaging timeout。`kAXErrorCannotComplete` 与 `kAXErrorInvalidUIElement` 各重试一次，不无限重试。`kAXErrorAPIDisabled` 直接给出授权路径。退出码按 0/2/3 映射，参数错误为 1。
- 判据 3：AX 驱动、参数解析、记录模型在 `Sources/VoiceOSPlatform/AXDriver.swift`。`Sources/VoiceOSCheck/AXCommands.swift` 只做解析调用与输出。
- 判据 4：`Tests/VoiceOSCoreTests/AXDriverChecks.swift` 三项：参数解析（必填、默认值、未知选项）、元素 JSON 字段齐全、identifier 前缀过滤。
- 判据 5：先 `git merge main --no-edit`，main 为 `e95ca3f`，已是最新。基线 `swift test -j 2` 610 项 0 失败。改后 `swift build -j 2` 退出码 0，`swift test -j 2` 退出码 0，613 项 0 失败。
- 判据 6：命令序列见「实机冒烟」。

### 实机冒烟（未重启应用）

运行中的 dist 应用为 pid 9796。以下命令由本轮构建的 `.build/debug/voiceos-check` 执行，全部只读：

- `voiceos-check ax dump --pid 9796 --identifier nav. --json`：退出码 0，7 个元素（`nav.home` 到 `nav.settings`），`truncated` 为 false，元素均带 `AXPress`。
- 文本模式同前缀：7 行摘要，退出码 0。
- `wait` 等待不存在的标识 0.3 秒：退出码 2。
- `click` 与 `set-value` 指向不存在的标识：退出码 2，未触达界面。
- 未知选项 `--bogus x`：退出码 1。

未执行 `click`、`set-value`、`scroll-to` 的真实动作，避免改动用户正在使用的界面。coordinator 可按下列顺序验证：

```bash
PID=$(pgrep -f 'VoiceOS.app/Contents/MacOS/VoiceOS' | head -1)
voiceos-check ax dump --pid "$PID" --identifier nav. --json
voiceos-check ax click --pid "$PID" --identifier nav.monitor
voiceos-check ax wait --pid "$PID" --identifier monitor.runCheck --timeout 3
voiceos-check ax dump --pid "$PID" --identifier monitor.runCheck
```

预期：第一条见 7 个元素；点击进入消息监测；`wait` 退出码 0；最后一条见 `monitor.runCheck`。

### 遗留风险

- AX 权限属于运行 voiceos-check 的宿主终端，属于 TCC 授权。换终端或重签应用后需要重新授权；未授权时退出码 3，并提示「系统设置 > 隐私与安全性 > 辅助功能」。
- 目标应用忙碌时，每个元素的属性读取有 1.5 秒 messaging timeout。重试一次后仍失败则整次命令以退出码 3 结束，不静默返回空结果。遍历较大树时 dump 可能明显变慢。
- 遍历上限 4000 个元素，超出时 JSON 的 `truncated` 为 true，摘要文本会注明截断。
- SwiftUI 懒加载列表只实体化可视区附近元素，dump 看不到未实体化行。先 `scroll-to` 再 dump。
- `scroll-to` 只向下翻页，不做回到顶部。存在多个滚动容器时取面积最大的 `AXScrollArea`，可能与目标所在容器不同。
- 分段控件仍按中文标题寻址，沿用波 70 的限制。
- `click` 与 `set-value` 依赖元素自身报告的动作和可写位。SwiftUI 若报告 `AXValue` 不可写，命令明确报错，不做坐标兜底。
