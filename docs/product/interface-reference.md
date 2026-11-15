# VoiceOS 界面参照：HIG 与真实 macOS 应用

## 1. 目的与方法

本文给 VoiceOS 的界面决策提供两份依据。一份是 Apple 人机界面指南（HIG）的原文规则，一份是真实 macOS 应用的实测尺寸。两者冲突时，先信实测，再看 HIG 是否给出了平台差异的解释。

HIG 原文于 2026-11-15 从 developer.apple.com 直连抓取，转换成本地文本后逐页摘录。页面 URL 前缀统一为 `https://developer.apple.com/design/human-interface-guidelines/`，共 28 页，完整列表见第 6 节。

实测方法：用 CGWindowList 读取窗口边界，用 screencapture 截取窗口，再按截图内的像素比例测量控件与间距。误差约 ±2 pt。测量环境为当前 macOS 版本，Apple 应用版本随系统更新，后续系统升级后数值可能小幅变化。

VoiceOS 当前值取自 `Sources/VoiceOSApp` 的代码。截图对照使用 after 系列，包括 after-home、after-actions、after-sheet，必要时与 before 系列对比。

本文是 reference 文档，只记录事实与判断，不写实现步骤。

## 2. HIG 关键规则摘录

每条规则末尾标注来源页面，格式（HIG: slug）。数字与禁止项按原文保留。

### 2.1 布局与窗口

- 按阅读顺序排布，自上而下、leading 到 trailing，最重要的内容放窗口顶部和 leading 侧。（HIG: layout）
- 用对齐表达相关性，用缩进表达从属，两者都要有意使用。（HIG: layout）
- 用渐进披露降低首屏密度，可用 disclosure triangle、菜单、嵌套视图或可滚动分区。（HIG: layout）
- 尊重安全区、系统 margins 和 layout guides；全屏背景内容延伸到侧栏和工具栏之下。（HIG: layout）
- 支持 Dynamic Type；相邻的横向视图可能需要改为纵向堆叠，行高需要增长。（HIG: layout）
- macOS 上避免把控件或关键信息放在窗口底部。（HIG: layout）
- bottom bar 只放少量与窗口内容或选中项直接相关的信息，不放关键信息；信息更多时用 split view trailing 侧的 inspector。（HIG: windows）
- 窗口分 primary 和 auxiliary 两类；auxiliary 只做一个任务，不允许导航到应用的其他区域。（HIG: windows）
- 不要默认开新窗口；可以在上下文菜单或 File 菜单提供「在新窗口打开」。（HIG: windows）
- 不要自造窗口 frame 或窗口控件，也不要模仿系统外观；面向用户的文案统一用 window，不用 scene。（HIG: windows）

### 2.2 侧栏

- 侧栏出现在视图 leading 侧，用于在应用各区域或顶层内容集合之间导航。（HIG: sidebars）
- 侧栏需要大量垂直和水平空间；空间有限时，更紧凑的 tab bar 可能是更好的导航选择。（HIG: sidebars）
- 内容多时用 disclosure controls 分组层级，控制侧栏的垂直长度。（HIG: sidebars）
- 用 SF Symbols 表示侧栏项目；需要自定义图标时做成 custom symbol，不要用位图。（HIG: sidebars）
- 让用户可以隐藏侧栏；macOS 提供显示或隐藏按钮，或在 View 菜单加命令。不要默认隐藏。（HIG: sidebars）
- 侧栏一般不展示超过两级的层级；更深时用 split view，在侧栏项与详情之间加内容列表。（HIG: sidebars）
- 侧栏图标默认用应用的 accent color，并跟随系统 accent color 变化。（HIG: sidebars）
- macOS 侧栏分 small、medium、large 三档，行高、文字和 glyph 大小随档位变化，程序可设，用户也能改。（HIG: sidebars）
- 考虑在容器窗口缩放时自动收起或显示侧栏。（HIG: sidebars）
- 不要把关键信息或操作放在侧栏底部，用户移动窗口时常会遮住底边。（HIG: sidebars）

### 2.3 列表与表格

- 文本内容优先用列表或表格，行式布局最利于快速扫读；项目尺寸差异很大或要显示大量图片时，改用 collections。（HIG: lists-and-tables）
- 导航型表格持续高亮选中行，标出所处层级；选项型表格只短暂高亮，然后用勾选图像标记选中项。（HIG: lists-and-tables）
- 条目文本保持简短；单项文本很长时，行内只放标题，正文放进详情视图。（HIG: lists-and-tables）
- 表格变窄时用中间省略号，保留文本开头和结尾。（HIG: lists-and-tables）
- 列标题用名词或短名词短语，不加句末标点。（HIG: lists-and-tables）
- macOS 中点击列标题按该列排序，再次点击已排序列则反向排序；让用户能调整列宽。（HIG: lists-and-tables）
- 多列表格可用交替行颜色，帮助跨列追踪同一行的值。（HIG: lists-and-tables）
- 层级数据用带展开三角形的 outline view，不要用 table view。（HIG: lists-and-tables）
- info button 只展示行内容的更多信息，不承担层级导航；行尾已有控件时不要再给表格加索引。（HIG: lists-and-tables）

### 2.4 工具栏

- 工具栏水平排列在视图顶部或底部，包含标题、导航控件和操作项，并按逻辑分区。（HIG: toolbars）
- 刻意挑选条目防止拥挤，并定义窗口变窄时哪些项移入 overflow 菜单。（HIG: toolbars）
- 系统会自动添加 overflow 菜单，不要手动添加，也避免默认就让条目溢出的布局。（HIG: toolbars）
- 分区数量尽量不超过三个；导航控件与 Done、Close、Save 等关键动作放进独立分区。（HIG: toolbars）
- 窗口标题概括用途，控制在 15 个字符以内；不要用 app 名称作窗口标题。（HIG: toolbars）
- Back 和 Close 用标准符号，不写文字标签。（HIG: toolbars）
- 优先用系统提供、无边框的符号；只给一个尾端的关键动作加 prominent 样式。（HIG: toolbars）
- 带文字标签的动作与纯符号动作分开，多个文字按钮之间插入固定间距。（HIG: toolbars）
- 减少自定义工具栏背景和着色控件，避免工具栏项标签与内容层背景相近。（HIG: toolbars）
- macOS 中每个工具栏项都必须在菜单栏有对应命令；工具栏项不带 bezel。（HIG: toolbars）

### 2.5 菜单

- 菜单项标签用动词或动词短语，采用 title-style capitalization，去掉 a、an、the 等冠词。（HIG: menus）
- 动作需要用户补充信息或多做选择才能完成时，标签末尾加省略号。（HIG: menus）
- 不可用菜单项显示为变暗；整组都不可用时菜单仍须可打开，让人了解其中命令。（HIG: menus）
- 重要或常用项放最前；逻辑相关的项归入同一组，组间用分隔线或短间隙。（HIG: menus）
- 同一组内菜单项图标要么全有要么全无；找不到能清楚表达该项的图标时不要显示图标。（HIG: menus）
- 子菜单限制在一层；某项超过约 5 条时考虑新建菜单或改用子菜单。（HIG: menus）
- 开关项用随状态变化的标签，如 Show Map 与 Hide Map；当前生效的属性用勾选标记。（HIG: menus）
- 弹出按钮只呈现扁平、互斥的选项列表；列动作、多选或含子菜单时改用 pull-down button。（HIG: pop-up-buttons）
- 标签要让选项在打开前可预测；必要时提供 Custom 项。（HIG: pop-up-buttons）

### 2.6 控件与命中区

- 按钮命中区至少 44x44 pt，visionOS 为 60x60 pt。（HIG: buttons）
- 自定义按钮必须有按压态；缺少按压态会让人怀疑按钮是否接受了输入。（HIG: buttons）
- 每个视图的突出按钮限一到两个，用样式而非尺寸区分首选操作；破坏性操作不分配 Primary 角色。（HIG: buttons）
- 打开另一个窗口、视图或应用的按钮，标题末尾加省略号。（HIG: buttons）
- macOS 方形按钮只放符号，放在视图内而不是窗口框架；帮助按钮每窗口不超过一个。（HIG: buttons）
- 分段控件由两个以上等宽段组成，宽界面以约 5 到 7 段为宜，标签用名词或名词短语。（HIG: segmented-controls）
- 单个分段控件不要混用文字与图像，也不要混用动作段与状态段。（HIG: segmented-controls）
- 开关只表达一对相反状态，不要仅靠颜色差异表达状态；macOS 的开关放窗口主体，不放框架、工具栏或状态栏。（HIG: toggles）
- 尽量用确定型进度指示器并准确报告进度，保持持续运动，不要从圆形样式切换到条形样式。（HIG: progress-indicators）
- 文本框只收少量信息；搜索重要时给它主位置，全应用内容尽量只有一个搜索入口。（HIG: text-fields）

### 2.7 字体

- macOS 文本默认字号 13 pt，最小 10 pt。（HIG: typography）
- 优先使用系统文本样式：Large Title 26/32、Title 1 22/26、Title 2 17/22、Title 3 15/20，字号与行高单位为 pt。（HIG: typography）
- Body 为 Regular 13/16，Headline 为 Bold 13/16，Callout 12/15，Subheadline 11/14，Footnote 与 Caption 1 为 10/13，Caption 2 为 Medium 10/13。（HIG: typography）
- 强调字重只用 medium、semibold、bold、heavy；避免 Ultralight、Thin、Light 这类过轻字重。（HIG: typography）
- 尽量减少字体家族数量，混用过多字体会模糊信息层级。（HIG: typography）
- 宽栏或长段文字用松行距；文本达到三行及以上时不要用紧行距。（HIG: typography）
- Dynamic Type 是 iOS、iPadOS、tvOS、visionOS、watchOS 的系统级特性，macOS 不在列；字号变化时要保持相对层级和视觉区分。（HIG: typography）
- 不要内嵌系统字体，用 API 取系统字体；13 pt 的 tracking 值为 -6/1000 em。（HIG: typography）

### 2.8 颜色与材质

- 同一颜色只表达同一含义；品牌色用于无边框按钮后，不要再用相近颜色装饰非交互文本。（HIG: color）
- 所有颜色都要在浅色、深色、提高对比度三种语境下可用；自定义色必须提供浅色和深色变体，并为每个变体提供提高对比度版本。（HIG: color）
- 不要只靠颜色区分对象、指示可交互性或传递关键信息。（HIG: color）
- 不要在代码中硬编码系统颜色值，也不要挪用动态系统颜色的语义。（HIG: color）
- 前景文本按 label、secondaryLabel、tertiaryLabel、quaternaryLabel 分层，分隔线用 separatorColor。（HIG: color）
- macOS 11 起可设置 app 强调色，作用于按钮、选中高亮和侧栏图标；用户选非 multicolor 时系统替换它。（HIG: color）
- Liquid Glass 构成控件与导航的功能层，浮在内容层之上；内容层用标准材质，不用 Liquid Glass。（HIG: materials）
- regular 变体适合文字量大的组件，如侧栏和弹出框；clear 变体只用于浮在照片、视频上的组件，内容明亮时可加 35% 透明度的深色变暗层。（HIG: materials）
- 材质上使用 vibrant 颜色；按语义选材质，不要按材质呈现的颜色来选。（HIG: materials）
- 厚材质更不透明，对比更好；薄材质更半透明，保留更多背景上下文。（HIG: materials）

### 2.9 深浅色

- 不要提供 app 专属的外观设置选项；应用应遵循系统的外观选择。（HIG: dark-mode）
- 应用在两种外观下都要好看；Auto 设置可能在应用运行期间切换明暗外观。（HIG: dark-mode）
- 使用语义颜色自动适配；自定义颜色用 asset catalog 的 Color Set 提供亮暗两套变体，避免硬编码颜色值。（HIG: dark-mode）
- 对比度至少 4.5:1；自定义前景与背景颜色争取 7:1，小字号文本尤其如此。（HIG: dark-mode）
- 深色色板不是浅色色板的简单反转，有些颜色反转，有些不是。（HIG: dark-mode）
- 文字使用系统的 primary、secondary、tertiary、quaternary label 颜色。（HIG: dark-mode）
- 在 Increase Contrast 与 Reduce Transparency 下测试内容仍保持可读。（HIG: dark-mode）

### 2.10 动效

- 有目的地添加动效，不为动效而动效；无谓或过多的动画会让人分心，甚至造成身体不适。（HIG: motion）
- 动效不能作为传达重要信息的唯一方式，应辅以触感、声音等替代反馈。（HIG: motion）
- 反馈动画要短而精确；简短动画常比醒目的大动画传达信息更有效。（HIG: motion）
- 频繁发生的 UI 交互一般不要加动效。（HIG: motion）
- 允许用户取消动效，尽量不要让人等动画播完才能操作。（HIG: motion）
- 反馈动效要符合手势与预期；从顶部下滑出现的视图，不应靠侧滑关闭。（HIG: motion）
- 系统组件的动效符合规范，并会随辅助功能设置或输入方式调整。（HIG: motion）
- 可以使用 SF Symbols 5 或更高版本的符号动画来表达状态。（HIG: motion）

### 2.11 焦点与选择

- 优先使用系统提供的焦点效果，只有绝对必要时才自定义。（HIG: focus-and-selection）
- 不要在人没有交互的情况下改变焦点。（HIG: focus-and-selection）
- macOS 的全键盘访问模式能让人用键盘到达每个控件，因此只需为列表项、文本输入框、搜索框等内容元素支持焦点。（HIG: focus-and-selection）
- 获得焦点的列表项用白色文字和应用强调色背景，未获得焦点的项用标准文字色和灰色背景。（HIG: focus-and-selection）
- 文本输入框和搜索框一般用焦点环，列表与集合用整行高亮。（HIG: focus-and-selection）
- 多数情况下聚焦即选中；当自动选中会造成分散注意力的上下文切换时，把聚焦与选中分开。（HIG: focus-and-selection）
- Tab 顺序为阅读顺序，从行首到行尾、从上到下。（HIG: focus-and-selection）
- 同容器内拖放默认移动，跨容器默认复制，跨 App 拖放总是复制。（HIG: drag-and-drop）
- 为每个拖放操作提供替代途径，例如菜单命令。（HIG: drag-and-drop）

### 2.12 键盘

- 尽可能支持全键盘访问（Full Keyboard Access），在系统设置的辅助功能中打开它来测试。（HIG: keyboards）
- 尊重标准快捷键，例如 Esc 取消当前动作、Command-Comma 打开应用设置、Command-Question mark 打开帮助。（HIG: keyboards）
- 一般不重新定义标准快捷键；只有当它的动作在你的应用里没有意义时才考虑。（HIG: keyboards）
- 只为最常用的应用专属命令定义自定义快捷键；快捷键过多会让应用更难学。（HIG: keyboards）
- 自定义快捷键优先用 Command 作主修饰键，Shift 作次要修饰，Option 少用，避免用 Control。（HIG: keyboards）
- 同时使用多个修饰键时，按 Control、Option、Shift、Command 的顺序列出。（HIG: keyboards）
- 不要给使用双字符键上档字符的快捷键再加 Shift，直接写出上档字符。（HIG: keyboards）
- 不要在现有快捷键上加修饰键来创建无关命令的新快捷键。（HIG: keyboards）
- 让系统负责快捷键的本地化与镜像。（HIG: keyboards）

### 2.13 无障碍

- 文字须可放大到至少 200%，watchOS 应用为 140%。（HIG: accessibility）
- macOS 自定义字号默认 13 pt、最小 10 pt；细字重要比推荐尺寸更大。（HIG: accessibility）
- 对比度达到 WCAG AA 下限：17 pt 及以下所有字重至少 4.5:1，18 pt 和所有粗体至少 3:1，明暗两种外观都要检查。（HIG: accessibility）
- 优先用系统定义颜色；不用颜色单独传达信息，另加形状或图标。（HIG: accessibility）
- macOS 控件默认 28x28 pt、最小 20x20 pt；有边框元素周围约 12 pt 内边距，无边框元素约 24 pt。（HIG: accessibility）
- 常用交互只用最简单的手势；滑动关闭等手势必须提供按钮替代。（HIG: accessibility）
- 不用定时自动消失的界面元素，改用显式操作关闭。（HIG: accessibility）

### 2.14 设置

- 默认设置以最多数人为准，让用户不先调整就能开始使用。（HIG: settings）
- 设置项尽量少；过多设置显得难以接近，也让具体某项更难找。（HIG: settings）
- macOS 把设置入口放在 App 菜单的 Settings 项，不要在窗口工具栏加设置按钮。（HIG: settings）
- 连接物理键盘时，支持标准的 Command-Comma 打开设置。（HIG: settings）
- 不用设置索取应用能自行获取的信息。（HIG: settings）
- 不在自定义设置区重复无障碍、滚动行为等系统全局选项。（HIG: settings）
- 自定义设置区只放通用且不常改的选项；任务内的选项就地放在受影响的界面。（HIG: settings）
- macOS 设置窗口调暗最小化和最大化按钮，用不可自定义的工具栏，标题随当前 pane 更新，打开时恢复最近用过的 pane。（HIG: settings）

### 2.15 提醒框与弹层

- 提醒框少用，每个只含必要信息和有用操作；代价是打断当前任务。（HIG: alerts）
- 不要仅为告知信息而弹提醒框，应用启动时也不弹。（HIG: alerts）
- 常见且可撤销的操作不弹提醒框，即便有破坏性；只对罕见且不可撤销的破坏性操作弹。（HIG: alerts）
- 提醒框最多三个按钮；标题具体，不超过两行；按钮标题一到两个词并用动词。（HIG: alerts）
- 默认按钮放在行的尾侧或栈的顶部，Cancel 放在行的首侧或栈的底部；破坏性操作必须提供 Cancel，Cancel 不作默认按钮。（HIG: alerts）
- 主界面一次只显示一个弹层；macOS 弹层浮在父窗口上方并调暗父窗口。（HIG: sheets）
- Done 必须与 Cancel 或 Back 配对，不要 Cancel、Done、Back 三键同时出现。（HIG: sheets）
- macOS 用合理的默认尺寸并支持调整大小。（HIG: sheets）

### 2.16 引导

- 引导要快、有趣且可选；理想情况是用户仅凭使用就能理解应用。（HIG: onboarding）
- 引导发生在启动完成之后，不属于启动体验。（HIG: onboarding）
- 通过交互教学，让用户安全地实际执行动作，而不是只看说明。（HIG: onboarding）
- 优先在相关界面区域就地提示上下文信息，而不是设计单一完整引导流程。（HIG: onboarding）
- 必需的前置引导要简短愉快，不要求记住大量信息。（HIG: onboarding）
- 单独教程做成可选；首次启动可跳过，之后不再自动出现，但要能在帮助、账户或设置里找回。（HIG: onboarding）
- 推迟非必需的设置和自定义步骤，用合理默认值让多数人立即上手。（HIG: onboarding）
- 应用在获得私有数据前无法运作时，把权限请求纳入引导并说明收益；否则在首次使用该功能时请求。（HIG: onboarding）

## 3. 真实应用实测

以下四款应用为实测，数值误差 ±2 pt。第 5 款系统设置本次未截图，单独标注非实测。

### 3.1 Apple 提醒事项（实测）

- 窗口 980×644。
- 侧栏约 200 宽。选中行是浅灰圆角填充，不是强调色。
- 列表行约 34 高，单行标题；勾选圈是 21 pt 的圆形。
- 正文字号约 17，页内大标题约 33。
- 内容左右边距约 29。
- 圆形控件约 28。搜索胶囊和新增按钮并入标题栏右侧。
- 强调色留给勾选圈等少量元素，选中态保持中性灰。

### 3.2 Apple 备忘录（实测）

- 窗口 970×660。
- 三栏：侧栏约 167，列表栏约 146，正文占余下宽度。
- 列表行约 42 到 44，标题 16、日期 12、预览 12 三层；分区头 11 到 12 加粗。
- 选中笔记是灰色圆角胶囊，不用强调色填充。
- 正文约 16 到 17，行距宽松。

### 3.3 Zotero（实测）

- 窗口 960×975。
- 三栏列表加右侧图标栏，图标栏约 50。
- 表格式单行行高约 32；列标题小号加粗。
- 选中行灰色圆角。
- 工具栏并入标题栏。

### 3.4 Obsidian（实测）

- 窗口 1512 宽。
- 左图标栏约 67，文件树侧栏约 196。
- 树行高约 36，缩进带引导线。
- 标签是浅紫胶囊。
- 底部状态栏一行统计芯片。
- 正文标题约 40 加粗。

### 3.5 系统设置（非实测）

本次未截图。按 HIG 与公开知识整理，只作形态参照，不作尺寸依据。

- 入口在 App 菜单的 Settings 项，支持 Command-Comma；应用内部不放设置按钮。
- 窗口为分类侧栏加右侧 pane，标题随 pane 更新。
- 控件行式成对排列，左侧标签，右侧控件。
- 窗口顶部有统一搜索框。
- 设置窗口调暗最小化和最大化按钮，工具栏不可自定义。

## 4. 与 VoiceOS 的差距清单

按用户影响排序，共 12 条。现状引用 after 截图或源码位置。

| 序 | 现状 | 参照 | 建议动作 | 优先级 |
|---|---|---|---|---|
| 1 | 设置入口是侧栏底部的按钮（`WorkspaceView.swift:458`）；App 菜单没有 Settings 项，Command-Comma 未注册（`VoiceOSApp.swift:3242-3257` 只加导入与撤销） | macOS 设置入口放 App 菜单，支持 Command-Comma；HIG 不要在工具栏加设置按钮 | 注册 Settings 场景或 app 菜单项，补 Command-Comma；侧栏按钮保留为跳转 | 高 |
| 2 | 头部右侧只有放大镜图标按钮（`WorkspaceView.swift:485`），搜索是独立页面，没有常驻搜索框 | 提醒事项把搜索胶囊放进标题栏右侧；HIG 要求搜索给主位置，全应用尽量一个入口 | 标题栏右侧加常驻搜索胶囊，点击即输入，Command-F 保留 | 高 |
| 3 | 标题栏显示 VoiceOS；页面名用 caption 面包屑画在自绘头部里（`WorkspaceView.swift:483,490`），与标题栏脱节 | HIG 窗口标题概括用途，15 字符以内；提醒事项、备忘录、Zotero 的工具栏并入标题栏 | 页面名进窗口标题或统一工具栏，收掉自绘头部行 | 高 |
| 4 | 设置提供跟随系统、浅色、深色三选一（`WorkspaceTheme.swift:12-30`） | HIG 明确不做 app 专属外观设置，避免用户以为应用不响应系统设置 | 移除三选一，改跟随系统；主题色是否保留另议 | 中 |
| 5 | 侧栏底部是全宽突出的记录想法按钮和设置入口（`WorkspaceView.swift:450-459`），after-home 截图可见 | HIG 不把关键操作放侧栏底部，窗口移动时会被遮住 | 主操作移到内容区或工具栏，侧栏底部只留次要入口 | 中 |
| 6 | Toast 2.5 秒后自动消失（`WorkspaceDesign.swift:190-192`） | HIG 无障碍不使用定时自动消失的界面元素 | 改为可关闭的常驻提示，或同等信息在非定时界面可见 | 中 |
| 7 | 色板只有浅色与深色两套色值（`WorkspaceTheme.swift:35-66`），没有提高对比度变体 | HIG 自定义色需提供提高对比度版本，并在 Increase Contrast 下测试 | 关键前景背景色补对比度变体，或改用系统语义色 | 中 |
| 8 | 引导完成标记写入本地存储后，没有重看入口（`Onboarding.swift:94-116`） | HIG 引导不再自动出现，但要能在帮助、账户或设置里找回 | 设置页加「再看一次引导」 | 中 |
| 9 | 讨论按钮只在头部（`WorkspaceView.swift:487`），菜单栏没有对应命令 | HIG 每个工具栏项都必须在菜单栏有对应命令 | View 菜单加显示或隐藏讨论的命令与快捷键 | 低 |
| 10 | 多个 sheet 用固定宽度，如 400 和 820（`WorkspaceView.swift:363`、`OutcomeFollowupView.swift:52`） | HIG macOS sheet 用合理默认尺寸并支持调整大小 | 改 min 与 ideal 尺寸，允许拉伸 | 低 |
| 11 | 键盘高亮用自定义 focusRing 描边（`WorkspaceView.swift:977,1161,1254`） | HIG 优先系统焦点效果，只有绝对必要时自定义 | 改用系统焦点效果，描边只作补充 | 低 |
| 12 | 单级页面也显示面包屑，与页内大标题重复；after-actions 截图中「行动」出现两次 | HIG 一个页面一个标题；实测应用没有重复标题 | 只在多级路径显示面包屑 | 低 |

## 5. 采纳决定

本批只新增本文档，不改界面代码，不跑构建。以下决定指下一轮界面批次的取舍。

下一轮先做差距 1 到 4。设置入口与 Command-Comma、标题栏统一、搜索胶囊都是高影响且改动面可控。外观开关的删除有产品习惯的代价，先做，观察反馈。

差距 5 到 8 留到更后一轮。侧栏底部改动牵动主操作入口，Toast 与对比度变体需要无障碍视角复核，引导重看依赖设置页成形。

差距 9 到 12 暂不排期，等真实使用反馈。图标控件、sheet 拉伸、焦点效果都属于细节，收益小于改动风险。

每条改动落地时，以本文档的参照值和 HIG 原文复核，不以本文档为唯一依据。系统升级后重新测量第 3 节的数值。

## 6. 链接

HIG 页面，前缀均为 `https://developer.apple.com/design/human-interface-guidelines/`。

- 布局：https://developer.apple.com/design/human-interface-guidelines/layout
- 窗口：https://developer.apple.com/design/human-interface-guidelines/windows
- 侧栏：https://developer.apple.com/design/human-interface-guidelines/sidebars
- 列表与表格：https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
- 工具栏：https://developer.apple.com/design/human-interface-guidelines/toolbars
- 菜单：https://developer.apple.com/design/human-interface-guidelines/menus
- 按钮：https://developer.apple.com/design/human-interface-guidelines/buttons
- 弹出按钮：https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons
- 文本框：https://developer.apple.com/design/human-interface-guidelines/text-fields
- 搜索：https://developer.apple.com/design/human-interface-guidelines/searching
- 分段控件：https://developer.apple.com/design/human-interface-guidelines/segmented-controls
- 开关：https://developer.apple.com/design/human-interface-guidelines/toggles
- 进度指示器：https://developer.apple.com/design/human-interface-guidelines/progress-indicators
- 字体：https://developer.apple.com/design/human-interface-guidelines/typography
- 颜色：https://developer.apple.com/design/human-interface-guidelines/color
- 深浅色：https://developer.apple.com/design/human-interface-guidelines/dark-mode
- 材质：https://developer.apple.com/design/human-interface-guidelines/materials
- 动效：https://developer.apple.com/design/human-interface-guidelines/motion
- 焦点与选择：https://developer.apple.com/design/human-interface-guidelines/focus-and-selection
- 拖放：https://developer.apple.com/design/human-interface-guidelines/drag-and-drop
- 键盘：https://developer.apple.com/design/human-interface-guidelines/keyboards
- 无障碍：https://developer.apple.com/design/human-interface-guidelines/accessibility
- 设置：https://developer.apple.com/design/human-interface-guidelines/settings
- 提醒框：https://developer.apple.com/design/human-interface-guidelines/alerts
- 引导：https://developer.apple.com/design/human-interface-guidelines/onboarding
- 分栏视图：https://developer.apple.com/design/human-interface-guidelines/split-views
- 面板：https://developer.apple.com/design/human-interface-guidelines/panels
- 弹层：https://developer.apple.com/design/human-interface-guidelines/sheets
