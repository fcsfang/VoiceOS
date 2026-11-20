# 波 124-A：浅色调色板柔化

基线 `work/m124-palette`，工作树 `.worktrees/m124-palette`。用户反馈整体底色是灰色，侧边栏和各想法卡片接近白色，观感突兀。目标是让浅色模式的卡片在底色上柔和抬升，不再像白块贴上去。

## 改动

只改 `Sources/VoiceOSApp/WorkspaceTheme.swift` 第 22 行的浅色 surface 值。深色值、边框提高对比度分支和其他 token 均未动。

| token | 主题 | 改前 | 改后 | 理由 |
| --- | --- | --- | --- | --- |
| surface | graphite | 0xFCFCFD | 0xF7F7F8 | 与 canvas 0xF2F2F3 的差从 10 级收到 5 级，卡片抬升变柔和。 |
| surface | sage | 0xFFFFFF | 0xF8FAF5 | 纯白收成与 canvas 同色相的中性浅色（G+2、B-3），保留暖绿。 |
| sidebar | graphite | 0xECECEE | 0xECECEE（保持） | 任务允许保持；与新 surface 差 11 级，卡片上方的侧边栏仍分得清。 |
| sidebar | sage | 0xE9EDE6 | 0xE9EDE6（保持） | 与任务建议的 0xE8ECE5 只差 1 级，色相与 canvas 一致。 |
| selection | graphite | 0xE7E7E7 | 0xE7E7E7（保持） | 在新 surface 上对比 1.16:1，选中行可辨且不发黑。 |
| selection | sage | 0xE6EEE5 | 0xE6EEE5（保持） | 在新 surface 上对比 1.13:1，层次与改前基本一致。 |
| canvas、text、border、accent、状态色 | 两套 | 未动 | 未动 | 不在反馈范围内，且正文对比度依赖它们保持不变。 |

深色未动的原因：深色两套（graphite canvas 0x1E1E1E、surface 0x272727；sage canvas 0x1B1F1D、surface 0x242925）观感正常，反馈只针对浅色；改动会改变已验证的深色观感，没有收益。

## 约束核对

数值由一次性 Python 脚本按 WCAG 相对亮度公式算出，未入库。

- graphite 正文 0x202020 在 0xF7F7F8 上对比 15.22:1，满足 ≥ 12:1。改前为 15.89:1。
- sage 正文 0x26352D 在 0xF8FAF5 上对比 12.26:1，改前为 12.89:1，仍高于 12:1。
- graphite 边框 0xD5D5D8 在 0xF7F7F8 上对比 1.37:1，改前 1.43:1，hairline 仍可见。sage 边框 0xCCD6CA 在新 surface 上 1.42:1。
- 色相：graphite 新 surface 各通道差为 (0, 0, +1)，与 canvas 相同，保持中性。sage 新 surface 为 (0, +2, -3)，与 canvas 完全一致，未引入新色偏。

## 验证

- 只核对了常量和计算值，未构建、未启动 app。任务按波次要求不构建，改动是同一行内两个十六进制常量的替换。
- 对比度和色相数据见上，可复算。
- 目视验证需在安装后切到浅色模式，看卡片抬升、边框分隔与侧边栏层次。本波未做，是遗留风险。

## 未做与风险

- 未构建、未目视验证，只能安装后人工确认。
- sidebar 与 selection 保持原值。若目视后侧边栏与卡片间隔仍显突兀，可再试 graphite sidebar 0xEEEEF0 与 sage sidebar 0xE8ECE5。
- 未 push、未合并、未开 PR。