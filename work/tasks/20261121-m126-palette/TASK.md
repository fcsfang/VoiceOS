# 126-A 表面配色二轮：卡片不再像白块

## 背景
用户复查 124 后反馈「白色突兀感并没有消失」。124 只把 surface 从 0xFCFCFD 收到 0xF7F7F8（与 canvas 差 5 级），在屏幕上仍读作灰底 + 白卡。

## 决定
卡片由「比底色亮」改为「几乎与底色同层」：靠 1px 边框与圆角分组，不靠亮度差。

- graphite（浅色）：surface 0xF7F7F8 → 0xF4F4F5（差 2 级）；sidebar 0xECECEE → 0xEFEFF1（比 canvas 低 1 级，不再是一块独立灰板）。
- sage（浅色）：surface 0xF8FAF5 → 0xF3F5F0；sidebar 0xE9EDE6 → 0xEDF0EA。
- 深色两套不动（用户只报了浅色问题，深色差值本就小）。

## 实测对比度
- surface/canvas 1.02（原约 1.06）· sidebar/canvas 1.03 · border/surface 1.33（卡片边仍可辨）
- 正文 14.82:1（graphite）/ 11.74:1（sage）· selection/surface 1.13（仍是表面之间最强的一档）

## 风险
- 若实机仍觉不分层，下一步是把卡片改成纯描边无填充（路径 b），不再动色值。
