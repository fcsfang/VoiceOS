# 145-A 行/搜索/页签的选择与悬停动效（WorkspaceView / WorkspaceReadingViews）

## 背景
动效发现：WorkspaceRow、SearchResultRow、选中高亮、筛选页签的视觉切换都是瞬切，而同屏的行尾菜单/胶囊用 0.12s 淡入——同一手势两种节奏；两套页签控件指标还不一致。本单元使用波 144 已合入的 `WorkspaceMotion` 词表（hover 0.12 / selection 0.12，均 easeOut），调用点用 `reduceMotion ? nil : ...` 门控（文件内没有 `@Environment(\.accessibilityReduceMotion)` 的按需添加）。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/WorkspaceView.swift
- Sources/VoiceOSApp/WorkspaceReadingViews.swift

## 逐条

### 1. WorkspaceRow 悬停
- `WorkspaceRow`（WorkspaceView 约 170-225 行）：两个分支的背景 `hovered ? palette.hover : .clear` 都是瞬切。给行容器统一加 `.animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)`（两分支都要生效；如在两个分支各加也行）。

### 2. SearchResultRow 与选中高亮
- `SearchResultRow`（grep `struct SearchResultRow`）：hover 背景同样加 hover 动效。
- `WorkspaceSelectionHighlight`（约 3567 行）：`highlighted` 变化是选中态，加 `.animation(reduceMotion ? nil : WorkspaceMotion.selection, value: highlighted)`。

### 3. 手写 0.12 统一到词表
- `MaterialMenuRow`、`WorkspaceActionRowChrome`、`RecentSearchChip`、`WorkspaceSearchField` 胶囊等处的 `.easeOut(duration:0.12)` 全部换 `WorkspaceMotion.hover`（reduceMotion 门控保留，不要新增无门控动画）。

### 4. WorkspaceFilterTabs 页签
- `WorkspaceFilterTabs`（约 3681-3727 行）：给页签内容加 `.animation(reduceMotion ? nil : WorkspaceMotion.selection, value: selection)`，使下划线/文字权重/颜色的切换有 0.12s 过渡。

### 5. 两套页签指标对齐（WorkspaceReadingViews）
- `WorkspaceTabs.filterTab`（约 60-84 行）与 `WorkspaceFilterTabs` 是同一控件的两份实现：下划线高度 1→2、`VStack` spacing 3→4、选中文字色 `palette.accent`→`palette.text`（与 WorkspaceFilterTabs 一致），并加同样的 selection 动效。
- `WorkspaceTabs.chip`（约 40-56 行）的选中背景切换加 `.animation(reduceMotion ? nil : WorkspaceMotion.selection, value: selection)`。
- 不改标签文案、排版尺寸与可访问性标识。

## 约束
- 只改动画/词表引用与页签指标对齐，不改业务逻辑与文案；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 每条先 grep 核实现状；机制不符的跳过并记录证据。

## 回报
提交哈希、逐条完成/跳过及原因、parse 退出码、diff --stat。