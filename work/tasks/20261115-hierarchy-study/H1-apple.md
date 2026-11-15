---
status: done
unit: H1
topic: Apple 应用信息层级实测
measured: 2026-11-15
system: macOS 27.2.1 (build 26B131), Darwin 27.2.0
baseline: main 69a5b5c
---

# H1 Apple 应用信息层级实测

目标：用户判定 VoiceOS 信息展示层级「非常糟糕」。本单元对五款已装 Apple 应用做真实实测，为后续重做 VoiceOS 视觉层级提供带数据的依据。只研究，未改任何代码，未写用户资料库。

## 0. 结论摘要

1. 五款应用共用一套三层文字阶梯：主文字（约 13 到 15pt，普通字重），次要文字（11 到 13pt，灰 #808080，对比度约 3.9:1），计数与区块头（11 到 13pt，更浅的灰，对比度 2.2 到 3.1:1）。大标题是例外，Reminders 42pt、Calendar 34pt，远大于 13pt 正文。
2. 分组主要靠留白和容器，不靠线。Settings 用 #F7F7F7 卡片（1.07:1 与白底）加 10pt 间隙分组；Notes 与 Reminders 行间完全没有分隔线；Mail 用 1pt #E5E5E5 细线；Calendar 用 1pt #C7C7CC 网格线。
3. 色彩几乎全部留给交互与状态：系统强调蓝 #3271EF 用于选中填充，Mail 未读点 #3E88F9，Calendar 今天红 #EA504C，Settings 提醒红 #EE2A2D。列表身份色只出现在 Reminders（列表色染标题、勾选圈、区块头）。
4. 渐进披露的标准形态：三栏（Notes、Mail）把字段拆到列表与详情；Settings 用「侧栏 → 英雄卡 → 分组卡 → 箭头详情」；Reminders 列表行只显示标题，详情藏在行内 info 按钮。列表行最多承载 4 类字段。
5. 五款应用里没有一组数字落在旧教科书的「13pt 正文、26pt 大标题、24pt 行高、斑马纹」上。行高实测 35 到 49pt（单行）与 68 到 99pt（多行），大标题 34 到 42pt。

测量条件说明：本机系统文字大小设为 XL（`com.apple.universalaccess` 的 `FontSizeCategory` 中 `global = XL`，五款目标应用均 `UseGlobal`，System Settings 不在该名单内）。因此下文的绝对 pt 值是 XL 下的值，比 HIG 内置表（默认档）大约大 2pt（正文 13 到 15）。同一台机器上运行的 VoiceOS 面对同一设置，这些值可直接采用。相对层级不受影响。

## 1. 测量方法

| 项目 | 方法 | 精度与说明 |
| --- | --- | --- |
| 字号 | 窗口截图（`screencapture -o -x -l <winid>`），Retina 2x，像素除以 2 得 pt。用 `/tmp/measure.py rows` 对文字做墨迹带（ink band）检测，量大写字高（SF Pro cap height = 0.7046 em）或汉字墨迹高（约 0.90 到 0.93 em）。再用 `/tmp/fontmatch.py` 以 `SFNS.ttf`、`PingFang.ttc` 渲染候选字号做包围盒比对 | 阈值取背景亮度减 0.22（浅色底），边缘反锯齿约 ±1px，即 ±0.5pt。每个数值在表格里标注「像素」 |
| 字重 | 同一墨迹带内统计水平墨迹段长度的中位数，作为笔画粗细代理，再对照同字号渲染结果 | 阈值会让笔画偏粗约 1px，只能区分「常规 / 中黑 / 粗」三档。标「推断」 |
| 行高、行距 | AX 框架 `AXPosition`、`AXSize`（单位 pt）取行与子元素矩形；截图量连续两行墨迹带基线差 | AX 值精确到 pt；基线差 ±0.5pt |
| 颜色 | 截图取文字核心最深像素、背景众数色 | 细笔画的反锯齿会让最深像素比真实字色浅，颜色均按实测记录，语义按角色标注 |
| 对比度 | WCAG 相对亮度公式，按 sRGB 计算 | 标准公式，见附带的 python 计算 |
| HIG 原文 | `curl developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`（网页是 JS 壳，正文在 JSON 接口） | 引文与 URL 见第 6 节 |

环境：内置 Liquid Retina XDR 3024x1964（2x），截图尺寸严格等于窗口 pt 尺寸 ×2。外观：Reminders、Notes、Mail、Settings 为浅色；Calendar 首次截图时窗口未激活且系统在傍晚切到深色（自动外观），因此 Calendar 的颜色用激活后的深色截图取，浅色值只作参考。测量日系统未改外观设置、未改文字大小设置。

## 2. 逐应用实测

每个应用先列文字阶梯表，再列间距、分组、颜色、渐进披露。

### 2.1 提醒事项（Reminders）

窗口 980x644pt，工具栏 52pt，侧栏 227pt。窗口标题文字不显示。

| 层级 | 实测字号 | 字重 | 颜色 | 依据 |
| --- | --- | --- | --- | --- |
| 内容大标题（当前列表名） | 42pt | 粗（semibold 到 bold） | 列表色 #5856CF | 像素：Latin 帽高 62px=31pt，7 个字母组成的词宽 322px；SF 600/700 在 42pt 渲染为 317/325px 宽、63/64px 高、笔画 12/14px，实测笔画 14px |
| 大标题右侧计数 | 42pt | 同标题 | 列表色 | 像素：数字高 61px，颜色与标题同 #5856CF |
| 列表内区块头（按列表分组视图） | 20pt | semibold | 列表色 | 像素：同一 7 字母词墨迹 151x30px；SF semibold 20pt 渲染 151x28px，完全吻合 |
| 行标题 | 15pt | 常规 | #272727（14.94:1） | 像素：4 个汉字墨迹宽 116px、高 28px；PingFang 15pt 渲染 118x28px。3 个汉字实测 86px，渲染 87px |
| 完成汇总「N项完成」 | 13pt | 常规 | #808080（3.95:1） | 像素：数字帽高 20px；13pt 数字渲染 18 到 20px |
| 侧栏区块头（我的列表） | 13pt | 中等 | #A0A09F 底 #EDEDEC（2.23:1） | 像素：汉字墨迹高 23px；PingFang 12pt 渲染 23px、13pt 渲染 24px，宽度指向 13pt |
| 侧栏行标题 | 15pt | 常规 | 近黑（最深 #000000） | 像素：3 汉字 86px，同 PingFang 15pt |
| 侧栏行计数 | 15pt | 常规 | #A0A09F（2.23:1） | 像素：数字高 22px |
| 智能列表卡片文字（今天/全部/旗标/紧急/完成） | 15pt | 中黑（推断） | 白到 70% 白，压在色块上；蓝色块上最深 #C8DCF5 | 像素：汉字高 28px；笔画中位 5px |

间距与几何（AX 实测）：
- 侧栏智能列表卡：89x69pt，2 列，列距与行距 6pt，圆角约 12 到 14pt（目测推断）。卡片填充色实测：今天 #8DB4E9、全部 #6D6D6D、旗标 #ECC199、紧急 #E391A6、完成 #9BA2A6。
- 侧栏列表行 41pt 高，图标 29x29pt，图标到文字 8pt，计数右对齐。区块头行 26pt。
- 主列表行 35 到 36pt 高。行内：勾选区 24x12pt（视觉直径约 20pt 的圆），标题文字框 21pt 高，上内边距 7pt，左侧内边距约 47pt（行起点 x=2466，文字 x=2513）。
- 内容大标题框 57pt 高，从工具栏下沿起 66pt 到列表起点。
- 汇总行 36pt；其下 1pt 分隔线 #E5E5E5（1.26:1），横贯内容宽度。
- 列表内区块头行 28pt，与上一段间隔约 17pt。
- 搜索框 226x38pt 胶囊，位于工具栏最右。

分组：行间无分隔线、无斑马纹。分组只靠 28pt 区块头加 17pt 间隔；列表身份由区块头的列表色承担。智能列表是唯一用「色块卡片」的元素，出现在侧栏顶部。

色彩语义：整个列表界面被列表色染：大标题、计数、勾选圈、区块头、右侧文字按钮「显示」均为 #5856CF（5.76:1 对白）。优先级、完成状态用系统色。侧栏选中态是浅灰圆角块。

渐进披露：大标题 + 计数常驻；行只显示标题与完成圈；详情藏在每行悬停出现的 info 按钮（22x11pt）弹层；已完成项折叠为「N项完成 · 清除」一行加「显示」。工具栏提供添加分区、添加提醒事项、搜索。

### 2.2 备忘录（Notes）

窗口 970x660pt，工具栏 52pt，三栏：侧栏 208pt、列表 200pt、编辑器 561pt。窗口标题不显示，工具栏内是两行标题块。

| 层级 | 实测字号 | 字重 | 颜色 | 依据 |
| --- | --- | --- | --- | --- |
| 工具栏标题（位置名） | 13pt | semibold | 实测最深 #4D4D4D | 像素：汉字墨迹高 24px；PingFang 13pt 渲染 25px |
| 工具栏副标题（N 个备忘录） | 11pt | 常规 | #808080（3.95:1） | 像素：汉字高 20px；PingFang 11pt 渲染 21px，宽度 111px 对实测 113px |
| 侧栏区块头（iCloud） | 11pt | 中等 | #878786 底 #EDEDEC（3.07:1） | 像素：Latin 帽高 18px（含 2px 反锯齿） |
| 侧栏文件夹行 | 15pt | 常规 | 近黑 | 像素：3 汉字 86px，PingFang 15pt 渲染 87px；行 40pt |
| 侧栏账号行 | 11pt | 常规 | #878784（3.07:1） | 像素：Latin 含降部 21px；行 19pt |
| 侧栏计数 | 15pt | 常规 | #9F9F9B（2.25:1） | 像素：数字高 22px |
| 列表区块头（过去7天/过去30天/九月） | 16pt | 粗 | #272727 | 像素：墨迹 111x29px；PingFang 16pt 渲染 112x29px，完全吻合；行 40pt |
| 列表行标题 | 13pt | semibold（推断） | #272727 | 像素：4 汉字 101px 宽、25px 高；PingFang 13pt 渲染 101x25px |
| 列表行日期 + 摘要 | 13pt | 常规 | #272727（窗口未选中时也深） | 像素：日期「2026/10/28」宽 128px、高 22px；SF 13pt 渲染 131px |
| 列表行文件夹元数据 | 13pt | 常规 | #808080（3.95:1） | 像素：3 汉字 69px 宽、23px 高，附 18x18 文件夹图标 |
| 编辑器时间戳 | 13pt | 常规 | #999999（2.86:1） | 像素：混合字串墨迹高 26px |
| 编辑器正文 | 15pt | 常规 | 实测最深 #454545（细笔画反锯齿所致，判为 label 色） | 像素：「提示词：」99x28px；PingFang 15pt 渲染 99x28px，完全吻合 |

间距与几何（AX 实测）：
- 侧栏行 40pt，账号行 19pt，区块头行 19pt；侧栏选中态为浅灰圆角块（实测 #D7D7D6）。
- 列表行 68pt，三段文字：标题框 18pt、元数据行 17pt、文件夹行 17pt；行内上内边距 7pt，段间距约 1pt（均为行高框相接）。区块头行 40pt。
- 列表无行分隔线。列表底白，侧栏 #EDEDEB。
- 编辑器：时间戳在顶部居中，正文框从工具栏下约 40pt 起；正文行距 37 到 38px（18.5 到 19pt），段落间距约 48px（24 到 25pt）。
- 选中行整行填充 #FAE496（Notes 黄），文字近黑 #262317（12.43:1）。

分组：没有卡片、没有细线。分组靠 40pt 区块头行加白底；列表和编辑器之间只有 1px 分栏的滚动条。行选中是唯一的色块。

色彩语义：整个应用基本单色，唯一强调是黄色（文件夹图标、选中行）。时间戳、文件夹元数据用灰阶表达层级。

渐进披露：三栏导航（文件夹 → 笔记列表 → 编辑器）。列表行承载标题、日期、摘要、所属文件夹 4 类字段；编辑器隐藏文件夹，只保留顶部时间戳；工具栏放格式、清单、表格、媒体、共享。

### 2.3 邮件（Mail）

窗口 1276x772pt，工具栏 52pt，侧栏 263pt、列表 406pt、阅读栏 593pt。窗口标题不显示，工具栏内两行标题块。

| 层级 | 实测字号 | 字重 | 颜色 | 依据 |
| --- | --- | --- | --- | --- |
| 工具栏标题（邮箱与账户） | 14pt | semibold | 实测最深 #4D4C4D | 像素：混合字串墨迹带 27px（含降部）；14pt 的反锯齿带约 27px |
| 工具栏副标题（N 封邮件，N 封未读） | 11pt | 常规 | #808080（3.95:1） | 像素：汉字高 21px |
| 侧栏区块头（个人收藏） | 11pt | 中等 | #878786（3.07:1） | 像素：汉字高 20px；行 19pt |
| 侧栏邮箱行 | 15pt | 常规 | 近黑 | 像素：汉字高 28px；行 40pt |
| 侧栏计数 | 11pt | 常规 | #6E7071（在 #D7D7D6 选中块上） | 像素：数字高 16px；无胶囊底 |
| 发件人（未读） | 17 到 17.5pt | 粗（未读加重） | #272727 | 像素：帽高 24.5px、x 高 18.5px；SF 17pt semibold 渲染宽 225px 对实测 236px（18pt 为 239px） |
| 日期 | 15pt | 常规 | #808080 | 像素：汉字高 28px |
| 主题 | 16pt | 常规 | #272727 | 像素：x 高 16.5px；SF 16pt 渲染宽 605px，实测 622px（含分词差异） |
| 摘要（2 行） | 15pt | 常规 | #808080（3.95:1） | 像素：行高 29px，两行基线差 38px=19pt |
| 阅读栏空态（未选择邮件） | 22pt | 常规 | #BDBDBD（1.88:1） | 像素：5 汉字宽约 209px；PingFang 22pt 渲染 216px；大字号才允许的低对比空态 |

间距与几何（AX 实测）：
- 列表行 99pt：发件人框 22pt、主题框 21pt、摘要框 40pt（2 行），上内边距 7pt，文本左内边距 37pt（行 x=671，文本 x=708）；未读点直径约 9pt，位于行左 13pt。
- 行间 1pt #E5E5E5 分隔线（1.26:1）。
- 侧栏行 40pt；区块头行 19pt；选中行是内缩圆角块 #D7D7D6。
- 列表选中行：内缩圆角蓝块 #A5C9E9，文字 #191F24（9.61:1）；选中块与未选中行之间没有额外间距，选中时盖住分隔线。
- 工具栏右侧是搜索图标按钮，阅读栏工具栏 52pt 高。

分组：列表靠 1pt 细线分行，无卡片、无斑马纹。未读状态用蓝点加粗字重表示。选中是 inset 圆角色块。

色彩语义：未读点 #3E88F9；选中蓝 #A5C9E9；其余全灰阶。计数为灰色纯文本，不用胶囊。

渐进披露：三栏。列表行承载发件人、日期、主题、两行摘要；完整正文在阅读栏（为避免把邮件标为已读，本次未打开任何邮件，阅读栏内部层级未测）。空态在阅读栏居中显示大号浅灰提示。

### 2.4 系统设置（System Settings）

窗口 754x766pt，工具栏 52pt，侧栏 246pt。窗口无标题文字；工具栏只有返回、前进段控件（73x36pt）。

| 层级 | 实测字号 | 字重 | 颜色 | 依据 |
| --- | --- | --- | --- | --- |
| 英雄卡标题（通用） | 20pt | 粗 | #262626 | 像素：2 汉字墨迹高 38px；PingFang 20pt 约 37px；笔画中位 7px |
| 英雄卡说明 | 13pt | 常规 | #7C7C7C 底 #F7F7F7（3.90:1） | 像素：汉字高 24px |
| 分组卡行标题 | 13pt | 常规 | #262626（14.9:1） | 像素：「关于本机」4 汉字 24px 高；行 48 到 49pt |
| 侧栏账户名 | 13pt | 常规 | 近黑 | 像素：汉字高 25px |
| 侧栏账户副题（Apple账户） | 11pt | 常规 | #878786（3.07:1） | 像素：混合字串高 22px |
| 侧栏条目 | 15pt | 常规 | 近黑 | 像素：汉字高 28px；行 40pt；图标块 26 到 32pt |
| 侧栏选中标签 | 15pt | 常规到中黑 | 白（实测最亮 #B6CCF9，反锯齿压在 #3271EF 上） | 像素：汉字高 27px；选中块 48pt 高、内缩 10pt、圆角约 10pt |
| 侧栏提示标题（有软件更新可用） | 15pt | 常规 | 近黑，右侧红点 | 像素：汉字高 28px；行 40pt |
| 侧栏提示详情（AppleCare 两行） | 15pt | 常规 | #878786（3.07:1） | 像素：两行基线差 39px=19.5pt；行 68pt |
| 红色提醒徽标 | 数字约 11pt | 中黑 | 白字底 #EE2A2D（4.20:1） | 像素：圆点 18x17pt |

间距与几何（AX 实测）：
- 侧栏：搜索框 226x28pt 胶囊，上距窗口顶 61pt；条目行 40pt，图标块约 26 到 28pt 圆角方块，组间距 13pt；账户行 46pt；提示行 40 或 68pt。
- 内容：滚动区宽 508pt；英雄卡 468x147pt，左右内边距 20pt，图标 56pt；分组卡宽 468pt，卡间距 10pt；行高 48 到 49pt；卡内 1pt 分隔线 #EBEBEB（1.11:1），左右内缩 10pt；行内图标块约 28pt，图标到文字约 14pt；箭头 #B7B7B7，距卡右缘约 12pt。
- 卡底 #F7F7F7，内容区白 #FFFFFF；卡圆角约 16pt（目测推断）。

分组：标准的分组卡。一张卡放 1 到 7 行，卡内细线分隔，卡间 10pt 留白。英雄卡单独成块，与第一张分组卡间隔 10pt。没有任何树形缩进。

色彩语义：应用图标色块（侧栏的彩色圆角方块：Wi-Fi 蓝 #418FF9、电池绿、通用灰等）承担条目识别；正文全灰阶；红 #EE2A2D 只给需要处理的提醒；选中用系统强调蓝 #3271EF（白字 4.43:1）。

渐进披露：侧栏 → 内容区英雄卡（图标、标题、一句话说明）→ 分组卡 → 右侧箭头进入详情。工具栏返回、前进负责层级回溯。System Settings 不在系统文字大小名单内，实测正文 13pt 与 HIG 默认 Body 一致，可视为未随 XL 放大。

### 2.5 日历（Calendar）

窗口 1512x873pt，工具栏 52pt，侧栏 228pt，月视图占满其余宽度。窗口无标题文字。

| 层级 | 实测字号 | 字重 | 颜色 | 依据 |
| --- | --- | --- | --- | --- |
| 月份大标题（2026年11月） | 34pt | 粗 | 近黑（浅色实测 #272727；深色 #DFDFDF） | 像素：数字帽高 47 到 48px（34pt × 0.7046 × 2 = 47.9px）；汉字「年」墨迹 58px；笔画中位 10 到 12px |
| 星期头（周一…周日） | 15pt | 常规 | #272727（浅色，窗口未激活） | 像素：2 汉字墨迹高 28px |
| 日格内农历（初四） | 13pt | 常规 | 浅色 #272727；深色 #DDDDDD | 像素：汉字高 26px |
| 日格内日期数字（12日） | 15pt | 常规到中黑 | 近黑；他月 #BDBDBD（1.88:1） | 像素：含「日」的墨迹高 28px |
| 事件条标题 | 15pt | 常规 | 近黑 | 像素：4 汉字 115px 宽、28px 高；行高 19pt |
| 事件时间 | 13pt | 常规 | #929292（3.11:1） | 像素：数字帽高 20px |
| 全天事件药丸文字（立冬） | 15pt | 常规 | 浅色 #28567A 底 #D6EBFC（6.35:1）；深色药丸底 #2A4860 | 像素：药丸高约 19 到 20pt，全圆角；左侧圆形星标 #54ACF3 |
| 今天标记 | 26pt 圆 | 数字粗 | 深色激活：红 #EA504C，白字；浅色未激活：灰 #BCBCBC，白字 | 像素：圆直径 26pt；红 (234,80,76) |
| 侧栏日历名 | 13pt | 常规 | 浅色 #727271（4.30:1，窗口未激活）；深色浅灰 | 像素：2 汉字 24px 高；行 32pt |
| 侧栏区块头（iCloud） | 11pt | 中等 | #878786 | 像素：同 Notes/Mail 的 11pt 账户头 |
| 迷你月标题 / 星期缩写 | 11pt / 9pt | 常规 | #797978 / #B3B3B2 | 像素：标题墨迹 19px；周数 12px |
| 迷你月日期数字 | 11pt | 常规 | #B3B3B2（他月） | 像素：数字高 16px |

间距与几何（AX 实测）：
- 月网格：单元格 183 到 184x123pt，6 行 x 7 列；网格线 1pt #C7C7CC（1.68:1 对白）；周头文字在每个列内右对齐，距列右缘约 27pt。
- 日格内：日期行（农历 + 数字）在格顶，左右内边距约 14pt；事件条从农历行下起，每条约 19pt，事件条左缘与格左缘留约 14pt；时间右对齐。
- 事件条的颜色标记是 2x17pt 圆角竖条（实测 #5BA9D8 深色模式）或同心圆图标；全天事件是整行药丸，左侧星标圆约 13pt。
- 侧栏：行 32pt，复选框 16x16pt，账户头行 19pt；迷你月网格单元 26x24pt，左上角显示周数（9pt）。
- 工具栏：视图切换 242x38pt（日/周/月/年四段，各 60pt 宽），选中的「月」是灰色胶囊；今天按钮 58x27pt 胶囊，两侧上月/下月箭头 27x27pt；加号按钮 40x52pt；搜索 38x38pt。

分组：月视图本身就是分组容器，1pt 网格线只画单元边界，不画行内线。事件用颜色标记加文字，全天事件用底色药丸。选中日历用浅灰圆角色块，今天用红色圆，两者是仅有的状态色块。

色彩语义：事件颜色来自日历颜色（示例事件条 #5BA9D8 蓝），今天红 #EA504C 是唯一固定的状态红；他月日期、周数、迷你月都是低对比灰，用来降级。深色模式下所有这些语义保持，背景 #232423、网格线 #4D4D4D。

渐进披露：工具栏切换日/周/月/年；月格只显示日期、农历和最多两条事件（超出按日历规则折叠，本次窗口内未见更密集单元）；点格子进入日视图（本次未展开测）；侧栏复选框控制显示哪些日历；迷你月提供跨月导航。

## 3. 提炼的层级规则（可直接照做）

以下所有 pt 值均为本机 XL 文字大小下的实测值。若 VoiceOS 跟随系统文字大小，直接用这些值；若固定字号，按括号内的默认档参考值实现（正文 13、次要 11、区块头 11）。默认档参考值来自 HIG 内置表与本机 13 到 15 的放大关系，属于推断，仅在表格中明确标注。

### 3.1 字号阶梯

| 用途 | 推荐值（XL 实测） | 默认档参考 | 字重 | 说明 |
| --- | --- | --- | --- | --- |
| 页面大标题 | 34pt（Calendar），最多 42pt（Reminders） | 26 到 34（推断） | 粗 | 只用于页面级标题；与正文拉开至少 2.2 倍 |
| 工具栏双行标题块 | 主 13 到 14pt + 副 11pt | 11 到 13 | 主 semibold，副 regular | 主副两行都放在 52pt 工具栏内；副标题用 #808080 |
| 内容区块头 | 16pt（Notes 列表），20pt（Reminders 分组） | 13 到 16 | 粗或 semibold | 需要分组时用，颜色可以是 label 色或身份色 |
| 侧栏区块头 | 11 到 13pt | 11 | medium | #878786 底 #EDEDEC；不要大写化 |
| 行标题 | 13 到 15pt | 13 | regular（未读或强调可 semibold） | 单行列表用 13，宽松列表用 15 |
| 正文 / 阅读文本 | 15pt，行高 18.5 到 19pt | 13，行高 16 | regular | 行高约为字号的 1.24 到 1.27 倍 |
| 次要文字（日期、摘要、元数据） | 13 到 15pt | 11 到 13 | regular | #808080 对白 3.95:1；#929292 对白 3.11:1 |
| 计数 / 三级文字 | 11 到 15pt | 11 | regular | #9F9F9B 到 #A0A09F，对侧栏底 2.2 到 2.6:1；只承载非关键信息 |
| 空态大字 | 22pt | 17 | regular | 只在大面积空白里用 #BDBDBD（1.88:1） |

阶梯比例（取整）：42/34（标题）: 20（区块头）: 15（正文/行）: 13（次要）: 11（三级）。相邻两级字号差至少 1 到 2pt，并用字重或颜色二次区分。

### 3.2 行高与间距

| 元素 | 实测值 | 出处 |
| --- | --- | --- |
| 紧凑单行列表行 | 35 到 36pt（文字 15pt） | Reminders 列表 |
| 标准侧栏行 | 40 到 41pt（文字 15pt，图标 26 到 32pt） | Notes、Mail、Settings、Reminders |
| 紧凑侧栏行（账户、区块头） | 19pt（文字 11pt） | Notes、Mail、Calendar |
| 设置行 | 48 到 49pt（文字 13pt，图标 28pt） | System Settings |
| 三行列表行 | 68pt（13pt 标题 + 两行 13pt 元数据） | Notes 列表 |
| 四行列表行 | 99pt（17pt + 16pt + 两行 15pt） | Mail 列表 |
| 单元格（日历） | 123pt 高，183 到 184pt 宽 | Calendar |
| 工具栏高度 | 52pt | 全部五款 |
| 区块头行高 | 26 到 28pt（Reminders）、40pt（Notes 列表） | 实测 |
| 区块间距 | 10pt（卡片间）、13pt（侧栏组间）、17pt（Reminders 区块头前） | 实测 |
| 页面左右内边距 | 20pt（Settings 内容区）、10 到 16pt（侧栏） | 实测 |
| 行内上下内边距 | 7pt（Reminders、Notes、Mail） | AX 实测 |
| 正文段落间距 | 24 到 25pt（约 1.3 倍行高） | Notes 编辑器 |
| 空态居中 | 阅读栏居中，无背景 | Mail |

规则：行高本身承担分组。单行行高 = 文字行高 + 约 14 到 16pt 内边距；多行行高 = 行高总和 + 14pt。

### 3.3 分组容器

1. 卡片（高信息密度设置页）：卡底 #F7F7F7，页面白；圆角约 16pt；卡间 10pt；卡内 1pt 分隔线 #EBEBEB（1.11:1），左右内缩 10pt；行高 48 到 49pt。适用于「一组同质设置项」。
2. 分隔线（消息列表）：1pt #E5E5E5（1.26:1），只在行之间，无斑马纹，无外框。
3. 纯留白（提醒清单、笔记列表）：没有线。分组靠 28 到 40pt 区块头加 17 到 40pt 间隔。
4. 网格线（日历）：1pt #C7C7CC（1.68:1），只画单元边界；不要用它画列表行。
5. 色块（智能列表、选中态）：整块圆角填充。导航选中用系统强调 #3271EF；内容选中用低饱和身份色（Notes #FAE496、Mail #A5C9E9）。
6. 计数：默认是右对齐纯文本，15pt 三级灰，没有胶囊。只有「需要处理」场景用红色圆点徽标（#EE2A2D，白字 11pt）。
7. 身份色：仅 Reminders 用列表色染区块头、勾选圈与标题（示例色 #5856CF，对白 5.76:1）。其它应用保持单色，颜色只给状态。

### 3.4 色彩语义与对比度

| 角色 | 实测值 | 对比度 |
| --- | --- | --- |
| 主文字（浅色） | #272727 | 14.94:1 对白 |
| 主文字（深色） | #DDDDDD | 11.47:1 对 #232423 |
| 次要文字（浅色） | #808080 | 3.95:1 对白 |
| 次要文字（侧栏底） | #878786 | 3.07:1 对 #EDEDEC |
| 三级 / 计数 | #9F9F9B、#A0A09F | 2.2 到 2.6:1 |
| 系统强调选中 | #3271EF | 白字 4.43:1 |
| 未读点 | #3E88F9 | 图形，无文字要求 |
| 今日 / 提醒红 | #EA504C、#EE2A2D | 白字 4.2:1 以上 |
| 卡片面 | #F7F7F7 对白 | 1.07:1 |
| 侧栏面 | #EDEDEC 对白 | 1.17:1 |
| 细线 | #E5E5E5、#EBEBEB | 1.11 到 1.26:1 |
| 网格线 | #C7C7CC | 1.68:1 |
| 空态大字 | #BDBDBD | 1.88:1，仅 22pt 大字可用 |

规则：文字只用四级灰阶（主、次、三级、空态），强调色只出现在选中填充、未读标记、今天、需要处理的徽标这四类语义。彩色必须带非彩色的第二线索（字重、位置、图标形状）。

### 3.5 渐进披露与导航

1. 三栏：侧栏（导航）→ 列表（标题、日期、摘要、元数据，最多 4 类字段）→ 详情（正文）。Notes 与 Mail 是标准范例。
2. 侧栏最多两层。Notes、Mail、Calendar 的账户头（11pt）是第二层的唯一形式；更深的层级交给中间列表。
3. 详情入口：Settings 用右侧 chevron；Reminders 用行内 info 按钮；Calendar 用单元点击；Mail、Notes 用列表选中。
4. 窗口标题：五款应用全部不在标题栏显示应用名或窗口名。Notes、Mail 用「主标题 + 副标题」双行工具栏块；Reminders 用内容区大标题；Settings、Calendar 没有标题文字。遵循 HIG「不要用应用名做窗口标题」。
5. 页面级大标题只在单列表应用使用（Reminders 42pt、Calendar 34pt）；多栏应用用 13 到 14pt 工具栏标题块，把大字号留给内容。

## 4. 在 macOS 26/27 上已经过时的旧规则

1. 「macOS 不支持文字大小调整」。HIG typography 仍写着 "macOS doesn't support Dynamic Type"，但本机系统级文字大小（辅助功能）已把 global 设为 XL，Body 从 13 放大到 15（Notes 编辑器实测 15pt）。实现必须用文字样式并测试大字号，不能写死 13pt。
2. 「macOS 大标题 = 26pt（HIG Large Title）」。26pt 是 AppKit 的内置样式常量：Reminders 实测大标题 42pt，Calendar 34pt。内容页标题显著超出该表。
3. 「侧栏区块头 11pt 大写灰字」。实测全部为 11 到 13pt、混合大小写、#878786（3.07:1）；Reminders 内容區区块头则是 20pt 列表色。不要做全大写。
4. 「表格用斑马纹」。五款应用没有一处斑马纹。Mail 用 1pt 细线，Notes 与 Reminders 无线，Settings 用卡片。
5. 「窗口标题栏写窗口名」。Reminders、Notes、Mail、Calendar 都隐藏窗口标题，改为工具栏双行标题块或内容大标题。HIG 本身也建议不要用应用名做标题。
6. 「计数要装进胶囊徽标」。macOS 侧栏计数是右对齐纯文本（11 到 15pt，2.2:1 的三级灰）。胶囊/圆点只用于提醒红点和智能列表卡片上的色块文字。
7. 「系统强调蓝 = #007AFF」。实测选中蓝 #3271EF，未读蓝 #3E88F9；填充更深、更偏靛蓝。旧色值直接照搬会与系统控件不一致。
8. 「内容分隔线约 #DEDEDE，行高 24 到 28pt」。实测分隔线 1pt #E5E5E5 或 #EBEBEB（1.1 到 1.3:1），单行行高 35 到 49pt。容器层级主要靠面差（#F7F7F7 对白 1.07:1），不靠深色线条。
9. 「每一行都要有分隔线」。Reminders 与 Notes 完全没有行线；Settings 只有卡内细线且左右内缩 10pt；Calendar 只有网格线。
10. 「共用一套固定字号阶梯」。五款应用在公共骨架（11/13/15）之上各自定大标题与行高：Mail 列表 99pt、Notes 68pt、Reminders 35pt、Settings 48pt。阶梯是共同的，行高和标题是场景化的。

HIG 的 macOS 内置样式表（默认档）仍可作为代码常量使用：Large Title 26/32、Title 1 22/26、Title 2 17/22、Title 3 15/20、Headline 13/16、Body 13/16、Callout 12/15、Subheadline 11/14、Footnote 10/13、Caption 1/2 10/13。实测应用的正文行高（15pt 字号配 18.5 到 19pt 行高，约 1.24 倍）比该表的 Body（13/16，1.23 倍）保持同样的比例，说明行高系数没有变化，变的是基准字号。

## 5. 与 VoiceOS 后续实施相关的落点

- 先定三个常数：正文 15pt（或随系统文字大小的 Body）、次要 13pt、三级 11pt；行高系数 1.24 到 1.27。
- 页面最多两级标题：页面大标题（单列表页面才用，34 到 42pt）与区块头（16 到 20pt）。多栏界面不要用大标题，用工具栏双行标题块。
- 分组优先选一种容器，不要混用：设置类页面用 #F7F7F7 卡片 + 10pt 卡距 + 1pt #EBEBEB 卡内线；列表类页面用留白或 1pt #E5E5E5 细线，不要三种一起上。
- 选中态用一个色块加圆角：导航用 #3271EF，内容用低饱和身份色；计数默认纯文本，不要胶囊。
- 颜色只给四类语义：选中、未读/进行中、今天/紧急、需要处理的徽标。其它一律灰阶。
- 空态用 22pt #BDBDBD 居中文本，这是唯一允许低于 3:1 的文字场景。

## 6. HIG 原文引用

以下引文均于 2026-11-15 用 curl 从 JSON 接口抓取。网页地址列在每条后面。

1. 默认与最小字号：「Platform / Default size / Minimum size ... macOS 13 pt 10 pt」。
   https://developer.apple.com/design/human-interface-guidelines/typography
2. 文字阶梯与文字样式：「Adjust font weight, size, and color as needed to emphasize important information and help people visualize hierarchy. Be sure to maintain the relative hierarchy and visual distinction of text elements when people adjust text sizes.」
   同上。
3. 「In general, avoid light font weights. For example, if you're using system-provided fonts, prefer Regular, Medium, Semibold, or Bold font weights...」
   同上。
4. macOS 内置文字样式表：「Large Title Regular 26 32 Bold / Title 1 22 26 / Title 2 17 22 / Title 3 15 20 / Headline Bold 13 16 / Body Regular 13 16 / Callout 12 15 / Subheadline 11 14 / Footnote 10 13 / Caption 1 10 13 / Caption 2 10 13」。
   同上。
5. 对齐与分组：「Align elements to make them easier to scan, and use indentation to convey hierarchy... People assume that aligned items are related to each other... Group related items to clearly express related information or functions.」
   https://developer.apple.com/design/human-interface-guidelines/layout
6. 列表简洁与详情分流：「Keep item text succinct so row content is comfortable to read... If each item consists of a large amount of text, consider alternatives... you could list item titles only, letting people choose an item to reveal its content in a detail view.」
   https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
7. macOS 列表样式：「macOS defines a bordered style that uses alternating row backgrounds to help make large tables easier to use.」「Consider using alternating row colors in a multicolumn table.」「Use an outline view instead of a table view to present hierarchical data.」
   同上。注：实测五个应用均未使用交替行背景，该条只适用于多列宽表。
8. 侧栏层级：「In general, show no more than two levels of hierarchy in a sidebar. When a data hierarchy is deeper than two levels, consider using a split view interface...」「Group hierarchy with disclosure controls if your app has a lot of content.」「A sidebar's row height, text, and glyph size depend on its overall size...」
   https://developer.apple.com/design/human-interface-guidelines/sidebars
9. 工具栏标题与分区：「Provide a useful title for each window... If titling a toolbar seems redundant, you can leave the title area empty.」「Don't title windows with your app name.」「Item groupings: leading edge, center area, trailing edge... Elements that let people return... appear at the far leading edge, followed by the view title... an optional search field」。
   https://developer.apple.com/design/human-interface-guidelines/toolbars
10. 标签色彩层级：「Use system-provided label colors to communicate relative importance. The system defines four label colors that vary in appearance to help you give text different levels of visual importance.」
    https://developer.apple.com/design/human-interface-guidelines/labels
11. 语义色与强调：「Dynamic color... is semantically defined by its purpose... some colors represent view backgrounds at different levels of hierarchy and other colors represent foreground content, such as labels, links, and separators.」「Avoid redefining the semantic meanings of dynamic system colors.」「reserve it for elements that truly benefit from emphasis, such as status indicators or primary actions.」
    https://developer.apple.com/design/human-interface-guidelines/color
12. Liquid Glass：「Liquid Glass forms a distinct functional layer for controls and navigation elements — like tab bars and sidebars — that floats above the content layer... Don't use Liquid Glass in the content layer.」
    https://developer.apple.com/design/human-interface-guidelines/materials
    同一主题的侧栏不透明度说明在 color 页：「Liquid Glass appears more opaque in larger elements like sidebars to preserve legibility over complex backgrounds and accommodate richer content.」
    https://developer.apple.com/design/human-interface-guidelines/color
    https://developer.apple.com/design/human-interface-guidelines/materials
13. 窗口状态：「The system gives main, key, and inactive windows different appearances... inactive windows don't use [color]」。Calendar 浅色截图里今天标记变灰、侧栏文字变浅，即该条的表现。
    https://developer.apple.com/design/human-interface-guidelines/windows

## 7. 取不到的项目与原因

1. Mail 阅读栏内部层级（邮件头、正文、附件）。打开邮件会把未读邮件标为已读，属于写用户数据，故未打开。列表层级已测。
2. Reminders 提醒详情弹层。未打开，避免碰到用户数据；行内 info 按钮的几何已从 AX 获得（22x11pt）。
3. Calendar 日、周、年视图的文字与行高。只测了月视图；切换视图属于只读操作但会改变当前用户的视图状态，本次未做。
4. 悬停态、焦点环、右键菜单、拖拽反馈。静态截图与 AX 树无法覆盖。
5. 精确字重。AX 不暴露 `AXFontSize`，字重只能从笔画中位数推断，误差约 ±1px；表中按「常规 / semibold / 粗」三档标注，个别标「推断」。
6. 深色模式的完整数据。只有 Calendar 捕获到激活的深色状态（系统自动外观在傍晚切换）；Reminders、Notes、Mail、Settings 只有浅色。深色下语义色值只记录了 Calendar 的样本（背景 #232423、网格线 #4D4D4D、今天红 #EA504C、药丸底 #2A4860）。
7. 提高对比度、降低透明度、其它强调色设置下的变体。未改系统设置，无法测量。
8. System Settings 是否响应系统文字大小。它不在 `FontSizeCategory` 名单内，实测正文 13pt 与 HIG 默认 Body 一致，判断为不响应 XL，但未通过切换设置验证。
9. 完整的分段控件、开关、下拉框尺寸。本次重点在文字层级与分组，控件只记录了工具栏出现的位置与大小。

## 8. 证据文件

- 截图：`/tmp/hier-apple-reminders.png`、`/tmp/hier-apple-reminders-all.png`、`/tmp/hier-apple-notes.png`、`/tmp/hier-apple-notes2.png`、`/tmp/hier-apple-mail.png`、`/tmp/hier-apple-settings.png`、`/tmp/hier-apple-calendar.png`（浅色未激活）、`/tmp/hier-apple-calendar2.png`（深色激活）。
- AX 树：`/tmp/ax-reminders.txt`、`/tmp/ax-reminders-all.txt`、`/tmp/ax-notes.txt`、`/tmp/ax-mail.txt`、`/tmp/ax-settings.txt`、`/tmp/ax-calendar.txt`。
- 测量工具：`/tmp/measure.py`（墨迹带与颜色）、`/tmp/fontmatch.py`（字号校准）、`/tmp/axdump`（AX 树，源码 `/tmp/axdump.swift`）。重跑方式：`python3 /tmp/measure.py rows <png> <x> <y> <w> <h> --runs`。
- 截图尺寸严格为窗口 pt 尺寸的 2 倍（例：Reminders 980x644pt 对应 1960x1288px）。
