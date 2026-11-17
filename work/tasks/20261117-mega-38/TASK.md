# 波 38：线索重命名、合并与隐藏（迁移 66）

来源：发现者 D2 提案 4（首页线索重命名与合并，L 成本）。五条静态关键词线索错配语料时用户无法纠正。本波加覆盖层：重命名 / 合并到 / 隐藏，均为用户显式操作，幂等可追溯。

## 完成判据

1. 迁移 66 新增 `recent_clue_overrides`（clue 主键、display_title、merge_into、hidden、updated_at、command_id 唯一）；旧库升级幂等，重复执行安全。
2. Store：`recentClueOverrides()` 读取；`setRecentClueTitle`、`mergeRecentClue`、`setRecentClueHidden` 三个写方法，command 前缀幂等（同 commandID 重放不重复写、返回既有结果）；覆盖行出现在 workspaceSnapshot 的 core 段（交互刷新后首页即时生效）。
3. Digest 应用覆盖：`RecentContentDigest.build` 增加 overrides 形参（默认空数组）；重命名改显示标题、合并把该线索的想法并入目标线索（目标也应用重命名后的标题）、隐藏整段不出现。近 14 天「最近想法」聚合不做覆盖（它按天聚合，不属于线索）。
4. 首页读器的线索段落头（digest.threads 渲染处）加悬停菜单：重命名（文本框）、合并到（其余线索下拉）、隐藏；隐藏后提供恢复入口（菜单里的「显示隐藏的线索」或等价最小方案，报告说明）。操作失败显示 model.status；成功即刷新。
5. swift build -j 2 与 swift test -j 2 一次通过（456 基础上新增覆盖应用与迁移测试）。

## 共享契约（两单元并行，签名先行，不得改名）

```swift
public struct RecentClueOverride: Equatable, Sendable {
    public var clue: String
    public var displayTitle: String?
    public var mergeInto: String?
    public var hidden: Bool
    public var updatedAt: String
}
// VoiceOSStore
public func recentClueOverrides() throws -> [RecentClueOverride]
public func setRecentClueTitle(clue: String, title: String?, commandID: String) throws
public func mergeRecentClue(_ clue: String, into target: String, commandID: String) throws
public func setRecentClueHidden(clue: String, hidden: Bool, commandID: String) throws
// RecentContentDigest
public static func build(thoughts: [String], duration: Double, tasks: [String] = [], overrides: [RecentClueOverride] = []) -> RecentContentDigest
// WorkspaceSnapshot 新增字段
public var recentClueOverrides: [RecentClueOverride] = []
// ControlCenter（U1 在 VoiceOSApp 实现）
func renameRecentClue(_ clue: String, title: String?) async -> Bool
func mergeRecentClue(_ clue: String, into: String) async -> Bool
func setRecentClueHidden(_ clue: String, hidden: Bool) async -> Bool
```

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| C1 核心覆盖层 | `work/m38-c1` / `.worktrees/m38-c1` | `Sources/VoiceOSCore/Database.swift`、`Sources/VoiceOSCore/RecentContent.swift`、`Sources/VoiceOSCore/WorkspaceSnapshot.swift`、`Tests/VoiceOSCoreTests/`（digest 与快照相关） | 判据 1、2、3 |
| U1 首页菜单 | `work/m38-u1` / `.worktrees/m38-u1` | `Sources/VoiceOSApp/RecentContentHome.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift` | 判据 4 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- C1：合并语义在 build 内完成（先应用重命名映射，再把 merge_into 源 thread 的 thoughts 附加到目标 thread 并按其 tags 排序或简单拼接，报告说明排序）；链式合并不追求（A 并入 B、B 并入 C 只做一跳，报告注明）；hidden 优先于合并。迁移写法照迁移 65 的模式（幂等守卫）。
- U1：菜单只用既有悬停菜单模式；重命名空串恢复默认（title=nil）；合并下拉列出其余线索的当前显示名；隐藏后的恢复放在同一菜单（「显示隐藏的线索」子菜单或顶部行内链接，报告说明）。写操作后调用 refresh()（交互作用域已含 overrides）。
- U1 不得改 RecentContent.swift 与核心；若断言需要核心字段，只用契约里声明的字段名。

## 验证基线

- 实时库线索分布（昨日统计）：五组静态线索覆盖 39 份有想法材料；13 份无想法。
- 用户可能在用机器：界面实拍与重启进空闲窗口。

## 结果（完成后填）

## 结果（2026-11-17 傍晚）

- C1：迁移 66（recent_clue_overrides，表存在加版本双守卫）；Store 四方法（command 幂等，同命令重放不重复写）；Digest.build 应用重命名/合并/隐藏（hidden 优先，链式合并一跳）；快照 core 段携带覆盖，交互刷新即生效；8 条新测试。
- U1：线索段落头悬停菜单（重命名 sheet、合并到子菜单、隐藏、显示隐藏的线索恢复），无障碍标签齐全；ControlCenter 包装函数按契约命名，失败弹 alert 或显示 status，成功 refresh。
- swift build -j 2 通过；swift test -j 2 461 项 0 失败（456 基础上净增 5）。
- 隔离副本（306MB 实时库快照）：启动即自 65 升至 66，recent_clue_overrides 表就位。界面菜单的实机核对被锁屏阻断（AX 全域不可见），留待解锁后补拍；渲染与交互由两单元报告的行号与代码路径保证。
