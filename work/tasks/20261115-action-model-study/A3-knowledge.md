# A3 知识与 AI 原生工具如何表示「开放问题」

状态: 只读研究，不改代码，不提交。
日期: 2026-11-15。
范围: Obsidian、Roam Research / Logseq、Zettelkasten、SiYuan，以及「开放问题清单」类方法论。
方法: curl 抓官方页面与官方仓库正文。WebFetch 与多数 WebSearch 不可用，见文末「取不到的项目」。

## 0. 结论先行

1. 这四类工具都没有一个叫「开放问题」的一等实体。问题通常以笔记、块、任务行或属性组合出现。真正决定体验的是回看入口和状态出口，不是实体名字。
2. 成熟做法把「是不是问题」和「问题到哪一步了」分开。类型负责语义，状态负责收敛。单一 kind 枚举同时承担两件事时，条目就会混装。
3. 最值得迁移的一条机制来自 Andy Matuschak。问题不要变成立即执行的待办，而是进入一个小批量、按间隔重现的提示队列。每天只看几条，标记 fruitful 或 unfruitful，最后转成永久笔记或放弃。
4. 对 VoiceOS，当前的 opportunity 至少混装四种意图: 长期目标、待弄清的问题、待核对事项、录音里提到但未处理的活动。知识工具对这四种意图给出不同的承载单元和出口。把 opportunity 继续当作一个 kind，会持续制造「不可完成但又需要收敛」的语义空洞。

## 1. Obsidian

### 1.1 基本单元与任务语义

Obsidian 的单元是 Markdown 文件。任务只是列表项的一种写法，不是独立对象。

原文: "To create a task list, start each list item with a hyphen and space followed by `[ ]`." 以及 "You can toggle a task in Reading view by selecting the checkbox."
来源: https://help.obsidian.md/editing-and-formatting/basic-formatting-syntax
中文转述: 任务就是带方括号的列表项。读视图里点复选框即可切换完成。官方语法不包含截止日期、状态、负责人等字段。只有「开」和「完成」两态。

原文: "Tasks tracks your checklist items from your vault. The simplest way to create a new task is to create a new checklist item."
来源: https://publish.obsidian.md/tasks/Getting+Started/Getting+Started
中文转述: Tasks 是全库扫描复选框的社区插件，不是官方核心插件。官方帮助只定义复选框语法，Tasks 插件才提供查询、日期、优先级、重复规则。两者要分开看。

原文: "To list all open tasks in a markdown file, simply add a query as a tasks code block ... ```tasks not done```."
来源: https://publish.obsidian.md/tasks/Queries/About+Queries
中文转述: 开放任务通过查询视图汇总，而不是维护一张手工清单。查询条件写在笔记里，结果随库内容变化。

原文: Core statuses 里 `space` 对应 Todo，`x` 对应 Done，并且可以配置 `Todo -> In Progress -> Done`。
来源: https://publish.obsidian.md/tasks/Getting+Started/Statuses/Core+Statuses
中文转述: 即使引入更多状态，Tasks 的状态仍然只服务可勾选的复选框。问题型条目如果没有完成动作，放进这个模型会很别扭。

### 1.2 问题作为笔记: 属性与 Bases

Obsidian 官方对问题型内容没有专门对象。可用的表示法是「笔记加属性」，再用 Bases 做视图。

原文: "Properties allow you to organize information about a note. Properties contain structured data such as text, links, dates, checkboxes, and numbers."
来源: https://help.obsidian.md/properties
中文转述: 笔记可以带类型化属性。文本、链接、日期、复选框、数字、列表都能作为字段。于是可以给问题笔记加 `type: question`、`status: open`、`opened: 2026-11-15` 这类字段。

原文: "Bases is a core plugin that lets you create database-like views of your notes. Using a base you can view, edit, sort, and filter files and their properties."
来源: https://help.obsidian.md/bases
中文转述: Bases 把笔记当作数据库行，按属性筛选、排序、分组。问题清单因此可以是「所有 `type: question` 且 `status: open` 的笔记，按开启时间排序」。视图是查询，不是另一份数据。

### 1.3 标签、反链、日记、画布

原文: "Tags are keywords or topics that help you quickly find the notes you want." 以及 "Nested tags define tag hierarchies that make it easier to find and filter related notes."
来源: https://help.obsidian.md/tags
中文转述: 标签是最轻的语义标记。嵌套标签可以表达 `#question/administrative`、`#question/product` 这种分层。标签适合临时分流，不适合承载状态机。

原文: "Linked mentions are backlinks to the notes that contain an internal link to the active note. Unlinked mentions are backlinks to any unlinked occurrence of the name of the active note."
来源: https://help.obsidian.md/plugins/backlinks
中文转述: 反链会展示谁会回到这个问题。未链接提及还能发现「有人提到过这个问题但没建链接」。这让问题在后续笔记里自然积累上下文。

原文: "Daily notes is a core plugin that opens a note based on today's date, or creates it if it doesn't exist. Use daily notes to create journals, to-do lists, or daily logs for things you discovered during the day."
来源: https://help.obsidian.md/plugins/daily-notes
中文转述: 日记是每日回看入口。官方示例模板里直接放了 `## Tasks` 和 `- [ ]`，说明日记被当作当天任务与捕获的暂存面。

原文: "Canvas is a core plugin for visual note-taking. It gives you infinite space to lay out notes and connect them to other notes, attachments, and web pages." 以及 "Text-only cards don't appear in Backlinks."
来源: https://help.obsidian.md/plugins/canvas
中文转述: 画布适合把一批问题摆开看关系，支持分组和连线。纯文本卡片不进反链，所以画布本身不是可靠的知识索引。它适合阶段性的空间梳理，不适合作为唯一回看入口。

原文: 官方示例中有 `> [!question] Can callouts be nested?`
来源: https://help.obsidian.md/editing-and-formatting/callouts
中文转述: `[!question]` 只是标注块的视觉类型。它不产生查询语义，也不改变状态。能被搜索到，但不能被当作问题对象来筛选和收敛。

### 1.4 Obsidian 小结

本节把六份官方文档拼成一种可行表示法，属于综合推断，不是 Obsidian 官方推荐。问题在 Obsidian 里最成熟的表示是「笔记加属性加 Bases 视图」。任务复选框只适合已经能执行的动作。标签负责粗分流，反链负责积累上下文，日记负责每日露面，画布负责阶段性空间整理。官方没有「问题状态机」和「定期重现」的内置机制，这两件事要靠属性约定或社区插件自己搭。

## 2. Roam Research 与 Logseq

### 2.1 取不到 Roam 官方文本

Roam 的官方帮助是一个运行在 `roamresearch.com/#/app/help` 的图，正文由客户端加载。`blog.roamresearch.com` 与 `help.roamresearch.com` 均返回 404。`roamresearch.com/api/graph/help` 等公开读取路径也返回 404。Wayback Machine 与 Jina Reader 在本机网络不可达。因此本节的块模型以 Logseq 官方文档为准，Roam 只作同类产品的背景，不引用 Roam 原文。

### 2.2 Logseq 的任务是块标记

原文: "Logseq comes with two built-in flavors to mark your block with built-in workflow marker keywords and manage your tasks:" 两种流是 `LATER -> NOW -> DONE` 和 `TODO -> DOING -> DONE`。
来源: https://docs.logseq.com/#/page/tasks
中文转述: 状态写在块的头部。一个块可以是任务，也可以不是。默认流可以在设置里切换。

原文: "there's also `CANCELED`/`CANCELLED`, `IN-PROGRESS`, and `WAIT`/`WAITING` markers which can be typed directly." 以及 "Both of the above commands work on regular blocks too, not just tasks."
来源: https://docs.logseq.com/#/page/tasks
中文转述: 除了完成流，还有取消、进行中、等待。截止日期和计划日期也能加在普通块上，不要求块先变成任务。这意味着「有待处理属性」和「是任务」在 Logseq 里不是同一件事。

### 2.3 查询就是问题视图

原文: "Queries are for asking questions from your knowledge base and the outside world (in the future)."
来源: https://docs.logseq.com/#/page/queries
中文转述: Logseq 把查询直接称为「向知识库提问」。问题清单可以用标签查询 `{{query [[question]]}}`，也可以用 `(task now later)` 或 `(between -7d +7d)`。视图由查询定义，不靠手工维护列表。前一个查询写法是示例，后两个写法来自官方文档。

原文: 查询过滤器包括 `task`、`page`、`property`、`page-tags`、`between`，例如 `(task now later)`、`(property type book)`、`(between -7d +7d)`。
来源: https://docs.logseq.com/#/page/queries
中文转述: 可以按状态、页面、属性、时间窗组合筛选。问题的「新鲜度」可以用时间窗表达。

原文: "Whenever you link to a page in Logseq, you actually create two links; one that you write, and one that automatically appears in the Linked references section of the page you link to."
来源: https://docs.logseq.com/#/page/why%20linking%20matters
中文转述: 双向链接让问题页自动收集所有提到它的块。问题不需要被复制到清单里，提到它的地方会自己聚拢。

原文: "Type `[[]]` to create or reference any other page." 以及 "Type `(())` to reference a block on any page."
来源: https://docs.logseq.com/#/page/page%20and%20block%20references
中文转述: 页面引用和块引用都是普通书写动作。问题可以是一个页面，也可以是一个可被引用的块。

### 2.4 Logseq 小结

Logseq 的关键是「块可以没有任务状态」。一个开放问题可以先作为普通块存在，靠标签、属性和查询被回看。状态标记只在它变成动作时才加上。这一点比 Obsidian 更贴近「问题不是任务」的语义。Roam 的情况没有可引用的官方文本，本文不作结论。

## 3. Zettelkasten

### 3.1 永久笔记是积累单元，问题是一类前置笔记

原文: "A Zettelkasten is a personal tool for thinking and writing."
来源: https://zettelkasten.de/introduction/
中文转述: 卡片盒的目标是长期积累可复用的想法，不是管理当天任务。问题如果进入这个系统，通常先作为阅读笔记或项目笔记存在，回答之后才沉淀为永久笔记。

### 3.2 研究项目里的「问题清单」是真实存在的中间产物

原文: "I count 34 notes in total, one idea, term, concept, or question for each note."
原文: "I end up with: a collection of questions, a collection of concepts or term definitions, ..."
原文: "I create a running list of ideas concerning Justice for Hedgehogs."
原文: "the aforementioned list of research questions, called ... '201409261640 research questions.md'."
原文: "In the next step, I will organize my questions and afterwards begin to create Zettel notes from the clusters."
来源: https://zettelkasten.de/posts/preparing-project-justice-hedgehogs/
中文转述: 处理一本书的阅读笔记时，作者把笔记分成问题、概念、主题等簇，并维护一个 `research questions.md`。问题清单是项目级中间产物。下一步是整理问题，再从簇里写出卡片。这条链路是「问题清单 -> 整理 -> 永久笔记」，不是「问题 -> 完成任务」。

### 3.3 创造性工作不能映射成任务

原文: "most parts of the creative process cannot be mapped to tasks."
原文: "For book projects I do keep task lists. But they don't look like the one above. They contain research prompts."
原文: "In essence, you use the Zettelkasten to buffer knowledge work."
来源: https://zettelkasten.de/posts/manage-writing-ideas/
中文转述: 写作和研究的主体过程不适合拆成可勾选任务。作者保留的清单装的是研究提示和 someday/maybe。原文举的 finish chapter 1 式清单，作者说它不可执行。问题型条目应该进入缓冲区，等材料足够再收敛。

### 3.4 Zettelkasten 小结

Zettelkasten 把问题当作知识生产的前沿。问题先被收集，再被组织，回答后转成永久笔记。它明确反对把创造性过程压成任务列表。对 VoiceOS 的启示是，问题需要一个「已回答」出口，而不是只有「已完成」。

## 4. SiYuan

### 4.1 块与任务块

原文: 内容块类型表里列出 "Task list block / Container block"。
来源: https://github.com/siyuan-note/user-guide-en_US/blob/master/20200923234011-ieuun1p/20210808180303-6yi1dv5/20200924101225-k254i8g.sy
中文转述: 思源的任务列表是一种容器块，和普通列表块并列。任务状态存在块的 markdown 文本里。

### 4.2 用 SQL 嵌入查询未完成任务

原文: "To query the unfinished task list items, you need to use the `markdown` field instead of the `content` field:"
原文查询: `{{SELECT * FROM blocks WHERE markdown LIKE '%[ ]%' AND subtype = 't' AND type = 'i'}}`
来源: https://github.com/siyuan-note/user-guide-en_US/blob/master/20200923234011-ieuun1p/20210808180303-6yi1dv5/20201117112518-dott91x.sy
中文转述: 思源允许在任意文档里嵌入 SQL 查询。未完成任务就是 `markdown` 里还有 `[ ]` 的列表项。问题清单同样可以用标签或属性查询出来，视图随内容实时变化。

### 4.3 日记模板承担每日回看

原文: "Use [[Embed Content Block]] in the specified template to summarize to-do items or content blocks that need to be viewed daily."
来源: https://github.com/siyuan-note/user-guide-en_US/blob/master/20200923234011-ieuun1p/20210808180303-xaduj2o/20210110181011-fbhoesf.sy
中文转述: 官方建议在日记模板里放查询嵌入，把每天要看的待办或块汇总到当天日记。回看入口是自动生成的，不依赖用户记得去翻清单。

### 4.4 思源的其他相关能力

原文: 官方网站列出 "Bidirectional link"、"Database Support relation, rollup and template"、"Spaced repetition By FSRS Algorithm"。
来源: https://b3log.org/siyuan/en/
中文转述: 思源有双向链接、关系型数据库视图、FSRS 间隔重复和 AI 辅助。据官网描述推断，间隔重复目前服务记忆卡，不是问题队列。数据库视图可以承载问题类型与状态，但需要用户自己约定字段。

### 4.5 一个需要纠正的站名

用户提到的 `siyuan.io` 是 Siyuan Qi 的个人学术主页，不是思源笔记官网。思源官网是 `https://b3log.org/siyuan/`。本文的思源结论都来自 b3log 官网与 `siyuan-note/user-guide-en_US` 官方仓库。

## 5. 「开放问题清单」方法论

### 5.1 问题可以作为笔记的正规类型

原文: "sometimes these are framed as questions, when evidence is too inconclusive to frame sharply; e.g. To what extent is exceptional ability heritable?"
来源: https://notes.andymatuschak.org/Taxonomy_of_note_types
中文转述: Andy Matuschak 的笔记分类里，问题标题是合法形式。证据不足以下断言时，就把标题写成问题。问题不是笔记的半成品，而是一种适合当前证据状态的表达。

原文: 一个示例问题笔记的正文包含 "Q. What's an important class of exceptions..." 与 "A. Sports..." 这样的问答对。
来源: https://notes.andymatuschak.org/z3CX38AdFzNGcujEwctVj5X
中文转述: 问题笔记可以随证据增加逐步写出答案。答案留在同一个笔记里，问题标题不变。这给「已回答」提供了一个自然状态，而不是把整条记录标成完成。

### 5.2 问题不进待办，进按间隔重现的提示队列

原文: "I could create a 'to-do' or block out time to think about this question, but that's often not what's called for. Instead, often what I need is marination: let's come back in a few days, see what bubbles up."
原文: "Sit down to my morning writing and see a small handful of writing prompts for the day, drawn from my writing inbox"
原文: "mark the prompt as 'fruitful,' meaning it'll come up again relatively soon, or 'unfruitful,' in which case the system will increase its interval substantially."
原文: "convert one of these prompts into one or more Evergreen notes."
来源: https://notes.andymatuschak.org/Spaced_repetition_may_be_a_helpful_tool_to_incrementally_develop_inklings
中文转述: 遇到有趣的问题时，先不要建立待办或预约思考时间。把问题放进收件箱，让间隔重复系统每天只露出少量提示。每次看完标记「有产出」或「没产出」。有产出就缩短间隔，没产出就拉长间隔。成熟后转成永久笔记。这条机制同时解决回看频率和收敛方向。

### 5.3 收件箱必须可信，可信来自定期清理

原文: "a quick way to capture transient notes which clearly isolates them from evergreen notes; and a place to put notes you want to develop further and a practice which reliably drains it"
来源: https://notes.andymatuschak.org/A_writing_inbox_for_transient_and_incomplete_notes
中文转述: 捕获和培育要分开。收件箱需要一条可靠的排出路径，否则会变成废纸堆。

原文: "You should be able to record a task anywhere"; "You regularly drain tasks from this list"; "You regularly delegate, refactor, or delete tasks which you can't prioritize".
来源: https://notes.andymatuschak.org/Close_open_loops
中文转述: 随处可捕获还不够。必须定期排出，并且允许委派、重构、删除。没有删除出口的清单会失去信任。

原文: "Inboxes only let us Close open loops if they're reliable." 以及 "Inboxes only work if you trust how they're drained."
来源: https://notes.andymatuschak.org/zGKqPvetpYbvbXmPmuuvfx8
中文转述: 用户是否继续往里放东西，取决于他是否相信这些东西会被处理。信任是回看机制的函数，不是捕获入口的函数。

### 5.4 方法论里反复出现的四步

这四步在 Andy 和 Zettelkasten 的材料里都出现。

1. 捕获。问题先以原始措辞进入收件箱或问题清单。
2. 小批量回看。每天只看少量，不做全量清理。
3. 状态推进。回答、转成动作、继续观察、删除，四选一。
4. 沉淀。回答后写成永久笔记，或者转成可执行任务。

## 6. 工具对比

| 工具 | 问题承载单元 | 状态与元数据 | 回看入口 | 转化出口 | 主要局限 |
| --- | --- | --- | --- | --- | --- |
| Obsidian | 笔记，或块内文本 | 属性: type、status、日期、复选框；标签 | Bases 视图、搜索、反链、日记模板 | 建任务复选框、写新笔记、加链接 | 无内置问题状态机；问题不会自动重现 |
| Obsidian Tasks 插件 | 复选框 | 状态符号、日期、优先级、重复 | `tasks` 查询 | 勾选完成、改状态 | 只服务可勾选项，问题无完成动作 |
| Logseq | 块 | 块状态标记、属性、页面标签 | 查询、Linked references | 加状态变成任务、写页面、删除块 | 状态标记偏任务语义；问题需要自定义约定 |
| Zettelkasten | 项目笔记或问题清单文件 | 项目、簇、卡片链接 | 阅读与整理回合 | 写成永久笔记 | 依赖人工整理节奏，没有软件强制 |
| SiYuan | 块，或任务块 | 块属性、标签、数据库字段 | SQL 嵌入、日记模板、反链 | 建任务块、写文档、加数据库字段 | 问题与任务共享块结构，需字段约定 |
| Andy 的笔记系统 | 收件箱提示、问题型永久笔记 | 提示间隔、fruitful 标记 | 每日写作时段 | 永久笔记、删除 | 个人实践，没有产品化 |

## 7. 可迁移到「录音 -> 理解 -> 行动」管道的机制

1. 问题不是任务，先不要给完成按钮。
   证据: Zettelkasten 说创造性过程不能映射到任务；Andy 说给问题建待办通常不是所需动作。来源见 3.3 与 5.2。
   迁移: 录音里识别出的问题进入「问题」状态，不进入可勾选列表。它可以被回答、转成任务或丢弃，但不能被「完成」。

2. 类型与状态分开。
   证据: Obsidian 用属性区分 type 与 status；Logseq 允许普通块再加状态标记；SiYuan 用块类型加字段。来源见 1.2、2.2、4.4。
   迁移: `actions` 表可以保留，但语义从单一 `kind` 变成两个轴。类型轴区分 task、question、goal、suggestion。状态轴区分 open、answered、dropped、promoted、done。

3. 回看入口用查询视图，不用手工清单。
   证据: Obsidian Bases 按属性筛选；Logseq 查询按状态、时间和属性组合；SiYuan SQL 嵌入实时汇总未完成项。来源见 1.2、2.3、4.2。
   迁移: 「问题与目标」页是保存查询，不是另一张需要维护的表。默认按开启时间排序，过期条目浮到顶部。

4. 小批量、按间隔重现。
   证据: Andy 的每日少量提示、fruitful/unfruitful 调整间隔。来源见 5.2。
   迁移: 每日回看只抽三到五条问题，按年龄和上次回看时间加权。用户标记「有进展」「继续观察」「丢弃」。不要一次展示全部积压。

5. 至少三条收敛出口。
   证据: Zettelkasten 的问题清单会整理成永久笔记；Andy 的提示会转成永久笔记或被忽略；收件箱要求定期删除和重构。来源见 3.2、5.2、5.3。
   迁移: 问题需要 `answered`、`promoted_to_task`、`dropped` 三个出口。当前只有「澄清成任务」一个方向，会把不想行动的问题永久困在 opportunity 里。

6. 问题标题写成问句。
   证据: Andy 的笔记标题直接用 "To what extent is exceptional ability heritable?" 这种问句。来源见 5.1。
   迁移: 录音理解阶段生成的问题条目，标题应尽量是问句，并保留录音时间戳与原文片段。问句在回看时更容易判断是否已有答案。

7. 目标不是问题，核对项也不是问题。
   证据: 知识工具里目标通常落在项目页、数据库字段或 someday/maybe，问题落在问题清单或提示队列，核对项落在任务。三者回看节奏不同。来源见 3.3、1.2、2.3。
   迁移: 用户库里混装的 opportunity 应该先分流。长期目标需要目标和进度。问题需要答案。核对项多半应该变成任务或带截止日期的检查项。录音里未处理的活动通常是任务候选。

8. 信任来自排出，不来自捕获。
   证据: Andy 说收件箱只有可靠时才关闭开放循环，可靠性取决于定期清理与删除。来源见 5.3。
   迁移: 每一条被捕获的问题必须有且只有一个回看入口。系统要能回答「这条问题下次什么时候出现」。答不上来，用户就会另建一份外部清单。

## 8. 对 VoiceOS 模型的直接含义

这一节只给知识工具一侧的证据，最终模型取舍由 A1、A2 汇总。

1. 不建议继续让 `kind` 单独承担语义。知识工具都把「是什么」和「到哪一步」分开。`opportunity` 这个 kind 同时容纳目标、问题、核对项和未处理活动，正是混装的来源。
2. 问题需要自己的状态机。`open -> answered | dropped | promoted_to_task`。`answered` 与 `done` 不是同一件事。回答是内容产出，完成是动作结束。
3. 目标需要另一组字段。目标通常有期限、方向和进度，不需要「回答」。把它和问题放在同一个子类型里，会让目标也长出一个永远等不到的回答状态。
4. 提醒只属于任务这条轴。知识工具里日期可以加在普通块上，但真正的提醒和重复仍然服务可执行动作。问题可以被「安排回看」，不应该被「安排执行」。
5. 录音管道应输出候选问题，而不是直接输出 opportunity。理解阶段可以把一句话识别为问题、目标、核对项或活动，再让用户确认。保留原始录音片段和转写时间点，回看时才有判断依据。
6. 每日回看页是产品必需件，不是附加视图。Obsidian 日记模板、SiYuan 日记模板、Andy 的晨间写作、Logseq 的 journal 都把回看放在每天固定入口。如果 VoiceOS 目前没有固定的问题回看面，这会是 opportunity 堆积的原因之一。后半句为推断。

## 9. 本次研究的边界

1. 没有取到 Roam 官方文本。原因见 2.1。Roam 的结论没有进入对比表。
2. 没有取到 Obsidian 官方对「问题」的专门文档，因为不存在。本文用属性、Bases、任务、反链、日记、画布六处官方文档拼出可行表示法。这是综合推断，不是官方推荐方案。
3. 「AI 原生工具」只覆盖了 SiYuan 的 AI 与 FSRS 能力。Notion AI、Tana、Mem 等未在本次范围，A2 若覆盖 Notion 可补。
4. 对照结论以公开文档为准。没有做用户访谈，也没有观察真实库里的问题条目生命周期。

## 10. 来源清单

Obsidian 官方帮助
- https://help.obsidian.md/tags
- https://help.obsidian.md/properties
- https://help.obsidian.md/editing-and-formatting/basic-formatting-syntax
- https://help.obsidian.md/editing-and-formatting/callouts
- https://help.obsidian.md/plugins/backlinks
- https://help.obsidian.md/plugins/daily-notes
- https://help.obsidian.md/plugins/canvas
- https://help.obsidian.md/bases

Obsidian Tasks 社区插件
- https://publish.obsidian.md/tasks/Getting+Started/Getting+Started
- https://publish.obsidian.md/tasks/Queries/About+Queries
- https://publish.obsidian.md/tasks/Getting+Started/Statuses/Core+Statuses

Logseq 官方文档
- https://docs.logseq.com/#/page/tasks
- https://docs.logseq.com/#/page/queries
- https://docs.logseq.com/#/page/why%20linking%20matters
- https://docs.logseq.com/#/page/page%20and%20block%20references

Zettelkasten.de
- https://zettelkasten.de/introduction/
- https://zettelkasten.de/posts/preparing-project-justice-hedgehogs/
- https://zettelkasten.de/posts/manage-writing-ideas/

SiYuan 官方
- https://b3log.org/siyuan/en/
- https://github.com/siyuan-note/user-guide-en_US
- 任务块文档: https://github.com/siyuan-note/user-guide-en_US/blob/master/20200923234011-ieuun1p/20210808180303-6yi1dv5/20200924101225-k254i8g.sy
- SQL 查询未完成任务: https://github.com/siyuan-note/user-guide-en_US/blob/master/20200923234011-ieuun1p/20210808180303-6yi1dv5/20201117112518-dott91x.sy
- 日记模板: https://github.com/siyuan-note/user-guide-en_US/blob/master/20200923234011-ieuun1p/20210808180303-xaduj2o/20210110181011-fbhoesf.sy

Andy Matuschak 公开笔记
- https://notes.andymatuschak.org/Taxonomy_of_note_types
- https://notes.andymatuschak.org/z3CX38AdFzNGcujEwctVj5X
- https://notes.andymatuschak.org/Spaced_repetition_may_be_a_helpful_tool_to_incrementally_develop_inklings
- https://notes.andymatuschak.org/A_writing_inbox_for_transient_and_incomplete_notes
- https://notes.andymatuschak.org/Close_open_loops
- https://notes.andymatuschak.org/zGKqPvetpYbvbXmPmuuvfx8

## 11. 取不到的项目与原因

1. Roam Research 官方帮助与博客。`roamresearch.com/#/app/help` 是客户端渲染的图，取不到正文。`blog.roamresearch.com`、`help.roamresearch.com` 返回 404。Wayback Machine 与 Jina Reader 在本机返回连接失败。没有用非官方转述冒充官方文档。
2. Roam 官方白皮书。没有找到可公开抓取的文本入口。
3. WebSearch 工具多数查询返回 403，订阅不可用。检索靠已知官方域名、官方仓库 API 与站点索引完成。
4. GitHub 网页与 raw.githubusercontent.com 在本机常超时。Logseq 与 SiYuan 的仓库文本通过 api.github.com 的 contents 接口读取，正文已抓取。文中的 GitHub blob URL 供人阅读，抓取状态不影响文本真实性。
5. Obsidian 官方帮助没有 Tasks 插件的官方文档，因为 Tasks 是社区插件。本文明确区分了官方复选框语法与社区插件行为。
