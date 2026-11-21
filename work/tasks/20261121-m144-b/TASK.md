# 144-B 动效词表与共享悬停反馈（WorkspaceDesign）

## 背景
动效发现：全仓共享的 hover 修饰符与按钮风格大多是「瞬间切换」，而 5 处手写表面用 0.12s 淡入，导致同一交互在不同控件上手感不一；三处临时提示条三种动效。本单元负责在设计系统里定义唯一动效词表，并让设计系统自带的悬停/按钮反馈先行使用。

## 文件清单（只允许动这一个）
- Sources/VoiceOSApp/WorkspaceDesign.swift

## 逐条

### 1. 动效词表
在 WorkspaceDesign.swift 定义（internal，其它波内单元依赖，签名不得改）：
```swift
enum WorkspaceMotion {
    /// 指针悬停/按下：立即响应但不闪跳。
    static let hover = Animation.easeOut(duration: 0.12)
    /// 选中、激活等选择态变化。
    static let selection = Animation.easeOut(duration: 0.12)
    /// 展开/收起。
    static let expand = Animation.easeOut(duration: 0.16)
    /// 撤销条、toast 等临时浮层进出。
    static let transient = Animation.easeOut(duration: 0.2)
    /// 区块跳转与视口恢复。
    static let scroll = Animation.easeOut(duration: 0.18)
}
```
附注释说明「一处定义，按交互类别取用；reduceMotion 由调用点沿用 `reduceMotion ? nil : ...` 关闭」。

### 2. 共享悬停反馈统一为 hover 动效
- `WorkspaceHoverHighlight`（约 367-378 行）：加 `@Environment(\.accessibilityReduceMotion)` 与 `.animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)`。
- `WorkspaceButtonBody`（约 540 行起）：同样对 `hovered` 变化加 hover 动效（reduceMotion 关闭）；`isEnabled` 变化不需要动画。
- `WorkspaceIconButton`（约 142-160 行，若内部有 hovered 状态）：同样处理。
- 该文件里其它 `@State private var hovered` 驱动的背景/透明度变化一并套用 hover 词表。
- 不改任何颜色、尺寸或布局。

### 3. 本文件内的手写 0.12s 动画改为引用词表
- `grep -n "easeOut(duration: 0.12)" Sources/VoiceOSApp/WorkspaceDesign.swift`，把手写时长换为 `WorkspaceMotion.hover`（reduceMotion 门控保持原样）。
- 若发现临时浮层（toast/撤销条）的实现也在本文件，套 `WorkspaceMotion.transient`；不在本文件的不动。

## 约束
- 只加/改动画与词表，不改视觉参数与业务；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：提交哈希、逐条完成情况、WorkspaceMotion 最终定义、parse 退出码、diff --stat。