# 149-B 播放时钟不再失效整页（WorkspaceSourceView）

## 背景
性能发现：材料页把 `SourcePlaybackClock` 以 `@StateObject` 持有，CLOCK 每 300ms 发布一次。`@StateObject` 同时是观察者，于是整个材料页（原文摘录、大纲分段、全记录扫描、所有行）在每个 tick 全部重新求值；实际只有回听标签与播放条需要跟着时钟走，且它们已各自以 `@ObservedObject var clock` 观察。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/WorkspaceSourceView.swift

## 改动
- 约 343 行 `@StateObject private var playback=SourcePlaybackClock()` 改为 `@State private var playback=SourcePlaybackClock()`。
- 理由（写一句代码注释）：页面本身不读 `playback.milliseconds`（仅用 `.onReceive(playback.$milliseconds)` 订阅与写回），`@State` 持有引用类型不会让页面在发布时重渲染；需要随 tick 更新的子视图（回听标签、播放条）已用 `@ObservedObject` 自订阅。
- 先 grep 核实页面体内除 `.onReceive` 订阅与 `playback.milliseconds = next` 写回外没有任何直接读 `playback.milliseconds` 的求值路径；若存在，改为让对应子视图读取（或放弃本改动并在回报中说明）。
- 不改播放逻辑、UI 与心跳间隔（1500ms/300ms 自适应已由 148-B 落地）。

## 验证
- `xcrun --sdk macosx swiftc -parse` 退出码 0；不跑 swift build/test。
- 回报：提交哈希、grep 证据（页面无直接读）、parse 退出码、diff --stat。