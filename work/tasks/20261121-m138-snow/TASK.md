# 138 新增第三主题「雪白」

## 背景
用户：现有纸白观感可以，保存为现有主题；再开一个更白、不带暖色的主题。

## 决定
- graphite（石墨）：保持现有纸白暖调（canvas 0xFAFAF9），副标题相应改为「纸白暖调，柔和专注」。
- 新增 snow（雪白）：纯中性白、更冷更亮——canvas 0xFBFBFC、surface 0xFFFFFF、sidebar 0xF3F3F5、text 0x1A1A1C、selection 0xEDEDEF、border 0xE3E3E6、accent 0x3B4654；深色 canvas 0x1D1D1F / surface 0x262628 / sidebar 0x151517 / selection 0x323234 / border 0x47474A。
- sage 不变。调色板属性由三元表达式改为按主题 switch，保证三主题穷尽。
- 主题选择沿用 @AppStorage("voiceos.workspaceTheme")，设置页三张预览卡自动出现。
