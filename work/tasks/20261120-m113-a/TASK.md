# 波 113-A 反思与阅读页面间距收敛到 4pt 网格

基线 3bcd442，工作树 `.worktrees/m113-a`，分支 `work/m113-a`。只改四个文件：`Sources/VoiceOSApp/ReflectionQuestionsView.swift`、`ReflectionGraphView.swift`、`TextCaptureView.swift`、`WorkspaceTopicReadingView.swift`。

## 修法

间距与内边距统一到 4/8/12/16/20/24/32；卡片内边距只用 20/16/12 三档；圆角优先用 `WorkspaceMetrics` 既有令牌。行号以下均为改后行号。

### ReflectionQuestionsView.swift

- `:103` spacing 14→16：侧栏标题、问题列表与底部按钮是三段结构，16 取区块档；14 与列表卡间距 8 只差 6，层级读不出来。
- `:117` bottom 6→8：静默提示卡与下方问题列表的间隔，与 `LazyVStack` 的 8 档一致。
- `:128` padding 13→12：问题行是 240 宽侧栏里的列表卡，落紧凑 12 档。
- `:136` padding 18→16：侧栏外框取紧凑 16，20 会压缩窄栏内容宽度。
- `:139` spacing 15→16：详情列各组之间取 16 区块档。
- `:158` spacing 6→8：主按钮内进度与标签的最小间距，6 无档位。
- `:191` vertical 18→16：空记录提示上下留白取 16。
- `:203` WorkspaceCard padding 14→16：记录卡含多行正文与操作行，取紧凑 16；12 会压长文本。
- `:204` spacing 9→8：记录卡内部行距取 8。
- `:234` spacing 9→8：撰写区表单行距取 8。
- `:298` padding 28→24：创建面板内边距，与本应用其余弹层的 24 一致。
- `:301` spacing 14→16：资料弹层各区块之间取 16。
- `:327` WorkspaceCard padding 12 保持：资料选择卡是密集三行列表卡，12 就是既有密集档，核对后不动。
- `:328` spacing 7→8：资料卡内部行距取 8。
- `:355`、`:376` WorkspaceCard padding 13→12：知识卡/任务卡与上方资料卡同属弹层密集列表，统一 12。
- `:356`、`:377` spacing 9→8：同上。
- `:171` frame(width: 210) 未动：分段 Picker 的固定宽度，按任务要求保留。

### ReflectionGraphView.swift

- `:115` padding 14→16：嵌入页面的主题头部条取紧凑 16。
- `:141` spacing 18→16：空态内容与按钮之间取 16。
- `:150` padding 10→12：错误行内边距与 `ReflectionQuestionsView:95` 的 12 一致。
- `:161` spacing 18→20：页头标题块与控件行之间取 20 的呼吸档，与底部 20 呼应。
- `:171` spacing 14→12：控件行内分段控件、日期与按钮之间取 12。
- `:206` horizontal 26→24：页头左右与页脚已有的 24 对齐。
- `:345` horizontal 22→24、vertical 14→12：图谱工具条左右对齐页脚 24，纵向取工具栏 12。
- `:360` horizontal 22→24、vertical 10→12：搜索结果列表与工具条同一套缩进。
- `:369` horizontal 22→24：关联开关行对齐工具条。
- `:394` spacing 7→8：泳道图例圆点与文字间距取 8。
- `:426` padding 18→16、`:447`/`:448` 定位补偿 18→16、`:338`/`:351` 内容尺寸 36→32：这组画布内边距与滚动定位补偿是同一组耦合常量，整体落到 16/32 档，仍保持一致。
- `:456`、`:556` spacing 7→8：节点卡与引文块内部行距取 8。
- `:465` padding 13→12：节点卡是固定 196×104 框，12 腾出的 2px 抵消行距 8 带来的 1px 增长。
- `:475` spacing 18→20：检查器面板标题与依据组之间与面板 20 内边距配套。
- `:511` padding 22→20：检查器内容取卡片默认 20。
- `:515` spacing 14→16：节点详情组间距取 16。

### TextCaptureView.swift

- `:53` spacing 10→12：底部状态与操作堆栈取 12。
- `:115` spacing 17→16：内容主堆栈取 16。
- `:136` spacing 10→12：保存选项表单段落取 12。
- `:232` spacing 10→12：模板名称卡内字段与错误提示取 12。
- `:271` vertical 10 保持：模板行与全局 `WorkspaceRow` 的 10/10 行节奏对齐，卡内还有分隔线形成连续行。
- `:385` horizontal 10→12：字段文字内缩与 `WorkspaceSearchField` 的 `controlPadding` 12 一致。
- `:231` WorkspaceCard padding 16 与 `:260` padding 12 核对已在档位，未动。

### WorkspaceTopicReadingView.swift

- `:111` spacing 28→24：页面区块之间取 `sectionGap` 24。
- `:121` top 14→16：展开的结构卡顶部间距取 16。
- `:151` spacing 15→16：主题速览卡内组间距取 16。
- `:215` horizontal 18→20、vertical 12 保持：结构卡顶部主题根行是强调层，取卡片默认 20 横向；纵向 12 保持紧凑，与下方 12 的网格行区分层级。
- `:220` connector height 18→16：根行与网格之间的连接线取 16。
- `:224` spacing 10→8：序号与标题是紧贴二元组，取 8。
- `:228` padding 13→12：结构小主题块取密集 12 档。
- `:229`、`:230` corner 9→`WorkspaceMetrics.controlRadius`（8）：小主题块是可选控件面，用既有控制圆角令牌，不为 9 新建令牌。
- `:286` spacing 10→12：卡片内两条预览观点的组间距取 12。
- `:297` spacing 15→16：展开的观点列表取 16。
- `:299` spacing 6→8：归属标签与观点正文是紧贴组，取 8。
- `:318` top 10→12：展开行动列表顶部与同卡其他展开区（12）统一。
- `:328` spacing 13→12：原话依据组取 12。
- `:348` spacing 6→8：安静按钮内文字与箭头间距取 8。
- `:365` spacing 14→16：问题标题与问题卡之间取 16。
- `:369` spacing 13→12：问题卡图标与文字间距取 12。
- `:374` padding 18→20：问题卡是独立卡片面，取默认 20 与 `sectionRadius` 16 配套。
- `:403` top 10→12：与前话前后的展开区统一。
- `:405` vertical 17→16：连接块上下间距取 16。
- `:475` spacing 11→12：任务行图标与文案间距取 12。
- `:477` spacing 5→4：标题与状态两行是紧贴对，取 4。
- `:483` padding 10 保持：任务行与全局 `WorkspaceRow` 10/10 行节奏对齐。
- `:484` hover corner 10→`WorkspaceMetrics.panelRadius`（12）：悬停底色与 `WorkspaceRow` 一样用面板圆角令牌。
- `:489` spacing 9→8：结果卡内部行距取 8。
- `:496` padding 15→16、corner 10→`WorkspaceMetrics.panelRadius`（12）：结果卡取紧凑 16 与面板圆角令牌。
- `:554`、`:571` spacing 15→16：主题磁贴内部与底部标签组取 16。

## 验证

共享锁循环，工作目录为工作树。首次取得锁，未出现 `LOCK_TIMEOUT`；命令结束后锁已释放（`LOCK_RELEASED`）。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 44.068 (44.128) seconds`

另用脚本扫描四个文件全部 `spacing`、`padding`、`cornerRadius` 字面量，未归位项仅为下方例外清单。

## 保留例外与原因

- `ReflectionGraphView.swift:353` 的 `padding(.top, 5)`：5×5 圆点与 meta 文本的光学对齐，取 4 会让圆点相对文字偏高。
- `ReflectionGraphView.swift:410` 的 `spacing: 50` 与 `:422` 的 `padding(.leading, 14)`：画布列宽 196 加列距 50 等于 246，正对 `:397` 泳道标签的 `x = 112 + lane * 246`；leading 14 加节点半宽 98 等于 112，使节点中心与标签同位。改任一处都会让标签与节点错位。
- `ReflectionGraphView.swift:467` 的 `cornerRadius: 2`、`width: 3`、`height: 30`、`leading: 1`：节点左侧色条图形，不是布局圆角与间距。
- `TextCaptureView.swift:271` 的 `padding(.vertical, 10)`：模板行与全局 `WorkspaceRow` 的 10/10 行节奏对齐。
- `WorkspaceTopicReadingView.swift:483` 的 `padding(10)`：任务行同样对齐 `WorkspaceRow` 10/10。
- `ReflectionQuestionsView.swift:228` 的 `frame(width: 22)`：图标操作区固定宽度，不是间距。
- 字面量宽度与高度（140/190/210/215/240/282/560/740、196/104/60、30/75/78/100/110/130/160 等）属于布局尺寸，不在本轮范围。

## 未做

- 未驱动真实应用验证：本轮约束是不重启应用，验证止于全量构建与测试。
- 未写 `~/Library/Application Support/VoiceOS`，未 push，未合并。
- `ReflectionTimelineView.swift` 不在本单元（112-A 已处理其文案），未改。
- 未新增令牌，未改 `WorkspaceDesign.swift`；`WorkspaceDesign.swift` 内已有的 10/9/11/7 等值不在本单元四个文件内，未动。