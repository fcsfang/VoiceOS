# H3 VoiceOS 现状层级审计

状态：只读审计完成。未改代码，未写资料库，未重启应用。基线 `69a5b5c`。

## 1. 方法与口径

- 运行实例：`pgrep -fl dist/VoiceOS.app` 返回 pid 46418，路径 `/Users/joey/01 Projects/VoiceOS/dist/VoiceOS.app/Contents/MacOS/VoiceOS`。
- 主窗口：`/tmp/winid 46418` 返回 id 2660，layer 0，980×949 点。
- 截图：`screencapture -o -x -l 2660`，输出 1960×1898 像素，即 2x Retina。截图在 `/tmp/hier-voiceos-*.png`。
- 导航：把目标文字写入 `/tmp/ax-target.txt`，在终端面板执行 `/tmp/axclick 46418 press`。Bash 工具没有辅助功能权限，AX 调用放在终端面板，与项目记忆一致。每次导航返回 `pressed-deep <文字>: true`。
- 字号口径：全部来自代码常量。应用文字大小设置为「标准」，缩放系数 1.12（`WorkspaceTextScale.swift:16-23`，设置页截图确认「标准」选中）。渲染点数 = 代码字号 × 1.12。截图为 2x，可用像素高度交叉核对，但本文不把像素测量当作独立证据。
- 颜色口径：全部来自 `WorkspaceTheme.swift` 的石墨主题色值。没有做取色器采样。
- 行号以基线 `69a5b5c` 的工作区文件为准。

## 2. 逐页截图清单

| 页面 | 状态 | 文件 | 截图里的关键事实 |
| --- | --- | --- | --- |
| 任务详情 | 行动 → 已完成 → 打开一条 | `/tmp/hier-voiceos-task-detail.png` | 面包屑「行动 / 任务与结果」与 eyebrow「行动 · 已完成」重复；标题 33.6pt；两张卡片头 23.5pt |
| 首页 | 最近 | `/tmp/hier-voiceos-home.png` | 264pt 时间线；右侧 30.2pt 衬线标题；线程头 17.4pt；笔记 16.2pt；目标标签 11.2pt |
| 行动 | 已完成 | `/tmp/hier-voiceos-actions-done.png` | 7 个筛选 chip；「完成后的结果」与「已完成」两张同形卡片 |
| 行动 | 全部 | `/tmp/hier-voiceos-actions-all-filter.png` | 「选择 / 保存当前视图 / 每周回顾」三颗同级按钮；结果、AI 助理、待办三类卡片同形 |
| 材料 | 日常材料 | `/tmp/hier-voiceos-materials.png` | 33.6pt 标题 + 15.7pt 灰色「68 份」；5 个筛选 chip；裸分隔线列表 |
| 阅读详情 | 打开一篇材料 | `/tmp/hier-voiceos-reading.png` | 标题带字面 `#`；正文保留 `**`、`##`、`-`；内容卡片从窗口 31% 处才开始 |
| 主题 | 全部 | `/tmp/hier-voiceos-topics.png` | 两列卡片；标题 22.4pt；摘要 15.7pt；页脚 12.3pt；有摘要的卡片明显更高 |
| 设置 | 外观 | `/tmp/hier-voiceos-settings.png` | 33.6pt「设置」与 23.5pt「外观」同色同重，读起来像两个页标题 |

## 3. 实际层级参数

### 3.1 字号阶梯

应用里 `vosFont` 共出现 23 个不同字号：9、10、10.5、11、12、12.5、13、13.5、14、14.5、15、15.5、16、17、18、19、20、21、22、27、28、30、62。统计方式：`rg -o "vosFont\(([0-9.]+)"` 后排序去重。相邻两级大量只差 0.5 或 1 点。

| 角色 | 代码位置 | 字号 × 1.12 | 字重 | 用在哪 |
| --- | --- | --- | --- | --- |
| 页标题 A | `WorkspaceView.swift:42` | 30 × 1.12 = 33.6 | semibold 无衬线 | 首页之外的一级页：材料、行动、主题、设置、阅读 |
| 页标题 B | `WorkspaceDesign.swift:38` | 27 × 1.12 = 30.2 | medium 衬线 | 记录想法、助理、反思等工具页 |
| 阅读标题 C | `RecentContentHome.swift:105,147` | 27 × 1.12 = 30.2 | semibold 衬线 | 首页右栏 |
| 工具页内标题 | `AssistantExecutionView.swift:169` 等 | 22 × 1.12 = 24.6 | medium 衬线 | 交付正文、主题问题 |
| 区块标题（实际） | `WorkspaceReadingViews.swift:57`、`WorkspaceView.swift:1155`、`WorkspaceSourceView.swift:31` | 21 × 1.12 = 23.5 | semibold | 所有卡片头、设置分组、阅读折叠区 |
| 区块标题（token） | `WorkspaceTextScale.swift:70` | 20 × 1.12 = 22.4 | semibold | 声明了但未被使用 |
| 页标题（token） | `WorkspaceTextScale.swift:69` | 28 × 1.12 = 31.4 | semibold | 声明了但未被使用 |
| 列表行标题 | `WorkspaceView.swift:90` | 16 × 1.12 = 17.9 | semibold | 材料、行动、设置资源行 |
| 正文 | `WorkspaceSourceView.swift:296` | 16 × 1.12 = 17.9 | regular | 阅读正文 |
| 正文 token | `WorkspaceTextScale.swift:72` | 16 × 1.12 = 17.9 | regular | 声明了但几乎未用 |
| 首页线程头 | `RecentContentHome.swift:179` | 15.5 × 1.12 = 17.4 | semibold | 首页右栏分块 |
| 首页笔记 | `RecentContentHome.swift:189` | 14.5 × 1.12 = 16.2 | regular | 首页右栏正文 |
| 首页摘要 | `RecentContentHome.swift:150` | 16 × 1.12 = 17.9 | regular 衬线 | 首页右栏摘要 |
| 筛选 chip | `WorkspaceReadingViews.swift:26` | 15 × 1.12 = 16.8 | semibold | 所有页面筛选 |
| 侧栏导航 | `WorkspaceView.swift:469` | 15 × 1.12 = 16.8 | regular 或 semibold | 五个一级入口 |
| 主题卡标题 | `WorkspaceTopicReadingView.swift:388` | 20 × 1.12 = 22.4 | semibold | 主题网格 |
| 主题卡摘要 | `WorkspaceTopicReadingView.swift:390` | 14 × 1.12 = 15.7 | regular | 主题网格 |
| 元数据 | `WorkspaceView.swift:91`、`WorkspaceDesign.swift:251` | 13 × 1.12 = 14.6 | regular | 行副标题、状态、日期 |
| 行尾操作 | `WorkspaceView.swift:94` | 12 × 1.12 = 13.4 | medium | 「阅读结果」「查看进度」 |
| 面包屑 | `WorkspaceView.swift:485` | 系统 `.caption` ≈ 11 × 1.12 = 12.3 | regular | 窗口头 |
| 首页元数据 | `RecentContentHome.swift:70` | 11 × 1.12 = 12.3 | regular | 时间线时间 |
| 主题卡页脚 | `WorkspaceTopicReadingView.swift:396` | 11 × 1.12 = 12.3 | medium | 「N 份材料」 |
| eyebrow | `WorkspaceView.swift:41` | 13 × 1.12 = 14.6 | medium | 页标题上方来源与状态 |
| 首页目标标签 | `RecentContentHome.swift:196` | 10 × 1.12 = 11.2 | regular，tracking 1.4 | 「想慢慢做到」 |
| Hero eyebrow | `WorkspaceDesign.swift:35` | 10 × 1.12 = 11.2 | semibold，monospace，tracking 2 | 工具页英文眉题 |

### 3.2 颜色角色

| 角色 | 色值 | 位置 | 实际用途 |
| --- | --- | --- | --- |
| 主文字 | `#202020` | `WorkspaceTheme.swift:24` | 页标题、区块标题、行标题、正文、元数据基色 |
| 次要文字 | 主文字 72% 透明度，白底约 `#5E5E5E` | `WorkspaceTheme.swift:26` | 行副标题、状态、面包屑、操作文字 |
| 强调色 | `#3A4A5C` | `WorkspaceTheme.swift:27` | 主按钮底色、选中 chip 底色、链接文字、行图标 |
| 选中底色 | `#E7E7E7` | `WorkspaceTheme.swift:28` | 侧栏选中、行选中、图标底、计数胶囊 |
| 边框 | `#D5D5D8` | `WorkspaceTheme.swift:31` | 卡片、chip、搜索框 |
| 成功 | `#2E7D52` | `WorkspaceTheme.swift:46` | toast 对勾 |
| 警告 | `#9A5B13` | `WorkspaceTheme.swift:44` | 底部「有事项需要查看」 |

关键事实：主文字与区块标题使用同一颜色和同一字重。次要文字只有一种灰度，元数据、状态、可点击操作全部落在这一级。

### 3.3 间距与容器

| 参数 | 值 | 位置 |
| --- | --- | --- |
| 内容宽 | 860 | `WorkspaceDesign.swift:6` |
| 阅读栏宽 | 720 | `WorkspaceDesign.swift:7` |
| 页边距 | 32 | `WorkspaceDesign.swift:8` |
| 区块间距 | 24 | `WorkspaceDesign.swift:9` |
| 卡片圆角 | 16 | `WorkspaceDesign.swift:12` |
| 行圆角 | 12 | `WorkspaceDesign.swift:13` |
| 卡片内边距 | 22 | `WorkspaceReadingViews.swift:71` |
| 卡片头到分隔线 | 18 | `WorkspaceReadingViews.swift:68` |
| 行标题到副标题 | 8 | `WorkspaceView.swift:89` |
| 紧凑行标题到副标题 | 2 | `WorkspaceDesign.swift:246` |
| 行内边距 | 竖 10，横 10 | `WorkspaceView.swift:95` |
| 图标框 | 30×30 | `WorkspaceView.swift:87` |

## 4. 逐页主任务判断

| 页面 | 应有主任务 | 截图上的实际重心 | 判断 |
| --- | --- | --- | --- |
| 首页 | 从最近内容里挑一条来读 | 右栏已选文章的 33.6pt 衬线标题 | 入口列表被内容压住，页面没有自己的页标题 |
| 行动 | 看今天要做的待办 | 「完成后的结果」卡片排在最前，与待办、AI 助理同形 | 主任务不明确 |
| 材料 | 找到并打开一份材料 | 标题与 5 个筛选 chip | 基本明确，列表缺日期分组 |
| 主题 | 挑一个主题进入 | 两列卡片 | 明确 |
| 设置 | 改设置 | 「设置」与「外观」两个大字头 | 明确，但分组头过响 |
| 阅读详情 | 读正文 | 两行工具栏、来源眉题、标题、状态行 | 正文被推到 31% 处，且保留 Markdown 字符 |
| 任务详情 | 处理这一条任务 | 两张同形卡片「重复」「子任务」 | 内容结构清楚，顶部上下文重复 |

## 5. 排序后的缺陷清单

### 高：主路径难以扫读

#### D1 行动页所有区块同权，筛选与操作 chip 泛滥

- 现象：`/tmp/hier-voiceos-actions-all-filter.png`。页标题下先排 7 个筛选 chip（全部、我的待办、AI 助理、已完成、问题与目标、待核对、历史记录），右上角再排「选择」「保存当前视图」「每周回顾」。「完成后的结果」「AI 助理的工作」「我的待办」三块都是白底、16pt 圆角、23.5pt 标题、灰色计数胶囊，连卡片内边距都一样。已完成筛选下只剩两张同样式的卡片。
- 代码：筛选定义 `SavedViews.swift:9-10`；筛选 chip 15 semibold + 选中填强调色 `WorkspaceReadingViews.swift:24-33`；页头按钮 `WorkspaceView.swift:846-854`；卡片结构 `WorkspaceReadingViews.swift:49-74`；`完成后的结果` `WorkspaceView.swift:856-864`；`AI 助理的工作` `WorkspaceView.swift:865-875`；`我的待办` `WorkspaceView.swift:908-912`。
- 伤害：用户打开行动页，第一眼看到的是三颗同级按钮加七个 chip，找不到「今天该做什么」这个唯一主任务。卡片同形让结果、AI 工作、待办互相抵消。
- 最小修改方向：只保留一个主区块，开放待办置顶且不用卡片壳；结果与 AI 工作降为次级区块或收进折叠。筛选改成一行文字标签或下拉，页头只留一个主操作。不改任何交互。

#### D2 类型尺度失守，23 个字号互相只差 1 点

- 现象：全应用 `vosFont` 有 23 个字号，13/13.5/14/14.5/15/15.5 六档连续出现，20 与 21 并存。页标题有三套声音：33.6pt 无衬线 semibold、30.2pt 衬线 medium、30.2pt 衬线 semibold。区块标题 23.5pt 与页标题只差 10pt。
- 代码：字号统计见 3.1；三套标题分别在 `WorkspaceView.swift:42`、`WorkspaceDesign.swift:38`、`RecentContentHome.swift:105,147`；`WorkspaceText` 声明了 6 档 token（`WorkspaceTextScale.swift:68-75`），但 `pageTitle`、`sectionTitle`、`body`、`caption` 在应用里没有实际调用，只有 `meta` 和 `rowTitle` 被 `WorkspaceDesign.swift:133,171,251,267` 使用。
- 伤害：每一级只比下一级大 1 到 2 点，扫读时眼睛没有可依赖的台阶。token 文件形同虚设，页面各写各的字号，层级无法统一。
- 最小修改方向：收成 5 档并全局替换。建议页标题 28、区块标题 15、行标题 15、正文 15、元数据 12，只保留一套页标题声音。删掉不用的 token 或让视图只能取 token。

#### D3 元数据、状态与可点击操作共用同一灰度同一字号

- 现象：材料行尾的「在读」、行动行尾的「阅读结果」、行副标题「11月13日 16:09 · AI 交付」、状态「分析已就绪」全部是 12 到 13pt 的次级灰。点得动和点不动的元素看起来一样。`/tmp/hier-voiceos-materials.png` 与 `/tmp/hier-voiceos-actions-all-filter.png` 可以直接对照。
- 代码：行副标题 13 secondary `WorkspaceView.swift:91`；行尾文字 12 medium secondary `WorkspaceView.swift:94`；材料阅读状态 `WorkspaceView.swift:1185,1194-1200`；行动来源与状态拼成一句 `WorkspaceView.swift:1207-1222`；次要色只有一档 `WorkspaceTheme.swift:26`。
- 伤害：用户无法判断「阅读结果」是状态还是入口，也无法一眼分出日期、来源、完成状态。次级信息过响，主标题反而被拖平。
- 最小修改方向：给三类信息三个明确槽位。状态用 12pt 次级色加一个小图标或色点。可点击操作只保留强调色和箭头。副标题只留一个事实，日期右对齐。不改交互。

#### D4 阅读详情原样输出 Markdown，正文被两层工具栏压低

- 现象：`/tmp/hier-voiceos-reading.png`。标题显示成 `# 你想放宽的，可能不是执行边界，而是思考边界`。正文卡片里直接显示 `**严格倒不是坏事**`、`## 目前需要拆开的，是“没发现”和“没行动”`、`- **你的使用体验**`。窗口头下面还有一条工具栏「开始按天读 / 更多」，再下面才是来源眉题、标题、状态行。正文卡片从窗口约 31% 处开始。
- 代码：阅读标题直接用 `source.displayTitle`，没有走 `displayTitle()` 去井号 `WorkspaceSourceView.swift:278`；工具行的定义 `WorkspaceSourceView.swift:235-273`；状态行 13pt `WorkspaceSourceView.swift:288`；转写正文整段作为普通 Text `WorkspaceSourceView.swift:296`；已有的去井号 helper 在 `WorkspaceView.swift:67-74`。
- 伤害：Markdown 符号污染每一行，原文自带的标题层级被抹平成同字号段落，读者只能在字面星号里找结构。工具行和状态行把正文推低，阅读页的主任务被压到第二屏边缘。
- 最小修改方向：标题走 `displayTitle()`。正文按 Markdown 渲染标题、列表与强调，或至少剥掉标记再分层。工具行并进窗口头，状态行降到元数据级。不改交互。

#### D5 区块标题与页标题同色同重，只靠 1.43 倍字号区分

- 现象：设置页「设置」33.6pt 与「外观」23.5pt 都是 semibold、都是 `#202020`，截图上像两个页标题在排队。任务详情页的「重复」「子任务」卡片头同样接近页标题。阅读页「原文与回听」也在一屏内与标题争夺第一眼。
- 代码：页标题 30 semibold `WorkspaceView.swift:42`；区块标题 21 semibold `WorkspaceReadingViews.swift:57`、`WorkspaceView.swift:1155`、`WorkspaceSourceView.swift:31`；两者都未指定颜色，继承主文字色。
- 伤害：标题、区块头、卡片头形成三个连续的大黑块，页面没有唯一顶点。设置页的六个分组头会被误读成六个并列页。
- 最小修改方向：区块头降到 15 到 17pt，或保持 21pt 但改成次级灰并去掉 semibold。页标题保持唯一的最大黑字。只改字号、字重、颜色。

### 中：次级页面与列表质量

#### D6 首页阅读栏混用衬线与非衬线，线程头与笔记只差 1.2pt

- 现象：`/tmp/hier-voiceos-home.png`。文章标题与摘要是衬线，线程头「职业与学习」和笔记是系统无衬线。线程头 17.4pt semibold，笔记 16.2pt regular，字号只差 1.2pt。目标标签「想慢慢做到」11.2pt 加字距，单独成一档。
- 代码：`RecentContentHome.swift:179`（15.5 semibold）、`189`（14.5 regular）、`150`（16 衬线）、`196`（10 tracking）。
- 伤害：同一栏里字体和字号同时变化，线程边界只能靠一条细线和 1.2pt 差异识别。读者很难区分摘要、线程标题、笔记三层。
- 最小修改方向：一栏只用一个字体家族。线程头拉到 17 到 18pt semibold，笔记保持 15 到 16pt，摘要与笔记同级。只改字体与字号。

#### D7 首页时间线的时间位置在同一列表里翻转

- 现象：`/tmp/hier-voiceos-home.png`。材料类行是标题在上、时间在下；「任务进展」类行是时间在上、标题在下。同一列里两种顺序。
- 代码：反馈行走 `time → title` `RecentContentHome.swift:63-66`；材料行走 `title → time` `RecentContentHome.swift:67-71`。
- 伤害：纵向扫时间或扫标题时，视线每几行就要换一次锚点。
- 最小修改方向：统一为标题在上、时间在下，反馈行也照此排。只改顺序。

#### D8 列表行的来源与状态串成一句，来源被截到 12 字

- 现象：行动行副标题形如「来自『语音输入法为何成为 AI 时…』· 已登记完成」。日期、来源、状态、同步信息用「·」连成一条 13pt 灰字。
- 代码：拼接逻辑 `WorkspaceView.swift:1207-1222`，截断 12 字在 `1220-1222`。
- 伤害：次要信息过响且不可扫。用户想确认「哪天」「哪来的」「完成没」时必须逐字读。
- 最小修改方向：固定两个槽位。状态一个词固定在左侧或右侧，来源保留完整标题用 `lineLimit(1)` 截断，日期右对齐。不改数据。

#### D9 材料页是 860pt 宽的裸列表，没有日期分组，计数停在 15.7pt 灰字

- 现象：`/tmp/hier-voiceos-materials.png`。68 份材料平铺，行标题 17.9pt semibold，行间只有 1px 分隔线。首页同样内容有「11月13日」日期组，材料页没有。标题下的「68 份」是 15.7pt 次级灰，与筛选 chip 挤在同一视觉带。
- 代码：材料页结构 `WorkspaceView.swift:706-753`；标题与计数 `711`；分隔线 `750`；行组件 `1180-1186`。
- 伤害：长列表没有分组锚点，扫读只能从第一行逐行往下。计数作为副标题被误读成说明文字。
- 最小修改方向：加日期组头，或把日期固定成右列。计数改成小号标签并靠右，与标题分离。只改布局与字号。

#### D10 任务详情页用两套标签重复同一路径

- 现象：`/tmp/hier-voiceos-task-detail.png`。窗口头面包屑是「行动 / 任务与结果」，标题上方 eyebrow 是「行动 · 已完成」。同一个位置信息出现两次，分隔符还不一样。
- 代码：面包屑 `WorkspaceView.swift:523`；eyebrow `WorkspaceActivityViews.swift:241`。
- 伤害：页面顶部有两个并列的小灰行，真正的状态信息（已完成）被路径信息稀释。
- 最小修改方向：面包屑只留路径，eyebrow 只留状态，或删掉 eyebrow 中的「行动」前缀。只改文案。

#### D11 主题卡片的密度随摘要有无而跳变，页脚 12.3pt 过小

- 现象：`/tmp/hier-voiceos-topics.png`。有摘要的卡片明显更高，摘要 15.7pt 三行，页脚「N 份材料 / N 个小主题」12.3pt medium。无摘要卡片只剩标题与页脚，卡片留白比例完全不同。
- 代码：标题 20 semibold、摘要 14 三行、页脚 11 medium `WorkspaceTopicReadingView.swift:388-396`；网格 `WorkspaceView.swift:767-772`。
- 伤害：网格节奏不均匀，页脚信息小到接近注释，主题之间的比较成本变高。
- 最小修改方向：摘要固定两行或统一省略，页脚升到 12 到 13pt。只改字号与行数。

#### D12 两个行组件的标题与副标题间距不一致

- 现象：材料与行动行使用 `WorkspaceRow`，标题到副标题 8pt；紧凑行组件 `WorkspaceListRow` 是 2pt。同一应用两种垂直节奏。
- 代码：`WorkspaceView.swift:89` 与 `WorkspaceDesign.swift:246`。
- 伤害：列表的松紧感因页面而异，元数据有时贴着标题，有时像独立一段。
- 最小修改方向：统一到 2 到 4pt，或统一 8pt。只改常量。

### 低：细节

#### D13 token 与实现漂移

- 现象：`WorkspaceText.sectionTitle` 声明 20，实际区块头是 21。`WorkspaceText.pageTitle` 声明 28，实际页标题是 30。
- 代码：`WorkspaceTextScale.swift:69-70` 对比 `WorkspaceView.swift:42,1155`。
- 伤害：后续修改会改错源头，层级继续漂移。
- 最小修改方向：删掉未用 token，或把视图改成取 token。

#### D14 设置里的主题选项不随文字大小缩放

- 现象：主题卡标题与副标题用系统 `.callout` 和 `.caption`，没有走 `vosFont`。切换「文字大小」时，这一块不跟着变。
- 代码：`WorkspaceTheme.swift:94-99`。
- 伤害：设置页内部层级不一致，辅助字号设置在这块失效。
- 最小修改方向：换成 `vosFont` 的 13 与 11。

#### D15 侧栏选中态只靠字重和浅底色

- 现象：侧栏五个入口都是 16.8pt，选中项只从 regular 变 semibold 并加 `#E7E7E7` 底。品牌字「VoiceOS」19 medium 与入口同处一栏，字号接近。
- 代码：导航 `WorkspaceView.swift:467-475`；品牌 `426`。
- 伤害：选中态弱，品牌与导航争夺侧栏顶部注意力。
- 最小修改方向：选中项改强调色文字或加左侧色条，品牌降到 17。

## 6. 取不到的项目与原因

- 行动页「我的待办」「问题与目标」「待核对」「历史记录」四个筛选未截图。本单元只要求全部与已完成。
- 「启动」页未截图。任务范围未列入。
- 首页「全景」模式未截图。任务范围只列首页，截图取默认的「最近」。
- 悬停操作未截图。`MaterialMenuRow` 与 `WorkspaceActionRowChrome` 的悬停胶囊只能从代码确认（`WorkspaceView.swift:1802-1824`、`1826-1872`），注入悬停会改变运行状态，且不影响层级结论。
- 深色模式与鼠尾草主题未测。当前实例是石墨浅色。
- 「小 / 大 / 特大」三档文字大小未测。设置页确认当前是「标准」，所有渲染字号按 1.12 计算。
- 没有做像素级取色。颜色值来自代码常量，未用取色器复核抗锯齿后的屏上色。
- AX 只能按文字命中并 press，未导出每个元素的 frame。因此间距来自代码常量，不是 AX 实测。

## 7. 结论

最根本的问题不是某一个页面排错了字号，而是没有一套被执行的尺度。23 个字号、三套页标题声音、六档只差 1 点的连续字号，让每一页都在用相近大小的黑字互相竞争。行动页把结果、AI 工作、待办放进同形卡片，芯片又和主操作同级，因此首屏没有主任务。元数据、状态和可点击操作共用一档灰字，列表的扫读线索被抹平。阅读页则因为原样输出 Markdown 和两层工具栏，把唯一的正文推到后面。

重做时先定 5 档字号和唯一页标题声音，再按页面主任务重排区块，最后把状态、元数据、操作拆成三个视觉槽位。这样改动集中在令牌与容器，不需要动交互。
