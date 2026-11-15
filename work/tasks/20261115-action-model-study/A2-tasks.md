# A2 任务与工单型产品的公开模型

目标重述：用户问 VoiceOS 的「待办 vs 问题与目标」模型该不该改，有没有更成熟的方案。本单元只回答一件事，Todoist、Linear、Notion、Apple Reminders 如何处理任务、问题、不确定项和提醒。

只读研究，不改代码。抓取时间 2026-11-15。来源全部是官方文档。WebFetch 未使用，页面用 curl 抓取后经 textutil 转文本。

throughput checkpoint: n/a, read-only investigation.

## 一页结论

1. 四款产品都没有把「问题」做成独立的一等公民对象。最接近的是 Linear 的 Triage，但它是状态类别，不是对象类型。
2. 不确定项都停在一个收件箱或前置状态里，澄清后进入正常流程。没有哪家在产品模型里新造一个「问题池」再要求用户搬家。
3. 提醒挂在哪里分两派。自有提醒系统的产品把提醒挂在任意对象上（Linear、Notion）。以可完成条目为单位的产品只挂任务（Todoist）。Apple Reminders 里一切皆 reminder。
4. VoiceOS 的「提醒只认 task」与 Apple 提醒事项的模型一致，不是落后。缺的不是提醒入口，而是未澄清项的状态机与显式动作。这是推断，依据是下面四家的分流机制。
5. VoiceOS 已有 clarify 与 promote 两条通道，但两者都改 `kind`，不改状态。成熟产品把这一步放在状态上。这是代码事实，见 `Sources/VoiceOSCore/ActionStore.swift:133` 与 `:170`。

## 对比表

| 产品 | 对象 | 状态 | 提醒 | 问题表示 |
|---|---|---|---|---|
| Todoist | task、sub-task、project、section、label、filter；comment 附在 task 上 | 任务有完成/未完成。`*` 前缀让任务不可完成。没有取消态 | 只挂在 task 上。时间、地点、重复、自动或自定义 | 没有独立对象。用 label、comment、不可完成任务或 Inbox 未定项表示 |
| Linear | issue 是基本单位。project、milestone、cycle、initiative、document 是外围对象 | 每队一条工作流。状态类别固定为 Backlog、Unstarted、Started、Completed、Canceled，另有 Triage 与 Duplicate | 可挂在 issue、document、project、initiative 上。due date 另有通知 | 没有独立类型。Triage 状态承载未澄清问题，可 resolve 的线程承载已答问题，label group 承载分类 |
| Notion | 数据库行就是 page。property 定义字段 | Status 属性三大类为 To Do、In Progress、Complete，可加子项 | 任意页面用 `@remind`。数据库需要 Date 属性 | 没有独立类型。问题就是 page，配 status 或 select，或单独建 Questions 数据库。评论可 resolve |
| Apple Reminders | reminder 是唯一对象。list、section、subtask、tag 是组织层 | 完成/未完成。完成后从列表隐藏 | 每个 reminder 都有日期、地点、紧急、提前提醒 | 没有独立类型。一切皆为 reminder，项目也只写成一条 reminder 文本 |

## Todoist

对象模型。任务是基本单位。任务可带子任务、项目、分区、标签、评论、日期、截止日、提醒、优先级。

> "Labels let you save time by batching similar tasks together. In Todoist, you can add as many labels as needed, and then pull up a list of tasks with any of these labels in seconds."
>
> 中文转述：标签是扁平分类，数量不限，用来把相似任务批量拉到一起。Todoist 没有标签层级。
>
> https://www.todoist.com/help/todoist/features/introduction-to-labels-dSo2eE

不确定项分流。没有项目归属的任务先落 Inbox。

> "The Inbox is your default task list in Todoist. When you add a task, it goes straight to your Inbox unless you specify that the task goes into a project."
>
> 中文转述：Inbox 是默认任务列表。用户不确定归属时先放进去，之后再决定。
>
> https://www.todoist.com/help/todoist/features/whats-the-difference-between-the-inbox-and-a-project-d6dSLqAM

问题型条目。Todoist 没有 question 对象。唯一的非完成机制是给任务名加 `*`，让任务变成不可完成。官方用途是当标题或父任务。

> "When creating a new task or making changes to an existing one, add an asterisk * and space before the task's name to make it uncompletable. These tasks don't have the circle icon next to the task name."
>
> 中文转述：`*` 前缀把任务变为不可完成，界面上不显示完成圆圈。它仍是一条任务，可加评论、文件、日期和负责人。
>
> https://www.todoist.com/help/todoist/features/create-an-uncompletable-task-in-todoist-QxQosZuF

筛选。过滤器是保存的查询，可以按关键词、日期、截止日、优先级、标签、项目、分区、负责人筛选。

> "Filters are saved searches that show only the tasks you need. You write a query, such as today & p1, and Todoist lists every task that matches it."
>
> 中文转述：过滤器是保存的搜索。查询语言支持 `search:`、`no date`、`%label`、`##section` 等条件。
>
> https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH

提醒语义。提醒绑定在任务上，支持时间、地点、重复。自动提醒相对任务日期触发。

> "A reminder sends you a notification about a task, either at a time you choose or when you arrive at a place."
>
> 中文转述：提醒的对象是任务。触发条件是时间或到达地点。
>
> https://www.todoist.com/help/todoist/features/introduction-to-reminders-9PezfU

日期与截止日分开。

> "While dates schedule when you plan to work on a task, deadlines represent the hard cutoff."
>
> 中文转述：date 是计划何时做，deadline 是硬截止。两个字段并存。
>
> https://www.todoist.com/help/todoist/features/introduction-to-deadlines-in-todoist-uMqbSLM6U

评论。评论挂在任务或项目上，按时间排序，用来放笔记和讨论。

> "Keep the discussions in one place by adding comments to your tasks in Todoist. In a comment, you can post notes, upload a file, or notify someone for their input, so that context is always available for anyone working on the task."
>
> 中文转述：评论是任务的讨论区，不是独立对象。问题可以作为一条评论存在，但不会被当成任务追踪。
>
> https://www.todoist.com/help/todoist/features/add-comments-or-files-to-tasks-in-todoist-CwiA50

## Linear

对象模型。issue 是基本单位，任务、bug、跟进、内部请求都算 issue。

> "Issues are the fundamental unit of work in Linear. They represent anything a team needs to track, such as bugs, feature work, follow-up tasks, or internal requests."
>
> 中文转述：Linear 不为「问题」单设对象。问题、任务、请求都是 issue。
>
> https://linear.app/docs/conceptual-model

状态机。每队一条工作流，类别顺序固定。

> "These workflows are team-specific and come with a default set and order: Backlog > Todo > In Progress > Done > Canceled."
>
> 中文转述：默认状态序列是 Backlog、Todo、In Progress、Done、Canceled。团队可在类别内增删和排序，不能改类别顺序。
>
> https://linear.app/docs/issue-property

Triage。Triage 是工作流之外的额外状态类别，充当团队的收件箱。

> "Triage is an additional status category that acts as an Inbox for your team."
>
> 中文转述：Triage 不是新对象，是 issue 的一个状态类别。默认从所有视图中排除。
>
> https://linear.app/docs/issue-property

> "By default, we exclude triage issues from all views since triage is considered to be outside the normal workflow. To include them in a custom view, you need to explicitly include them by adding a status filter where 'Triage' is included."
>
> 中文转述：未澄清的 issue 不混进正常视图，只有显式过滤才出现。
>
> https://linear.app/docs/triage

Triage 的显式动作。接受、拒绝、标重复、稍后。

> "Open the issue to review it and take one of the following issue actions: accept with 1, decline with 2, mark as duplicate with 3, or snooze with H."
>
> 中文转述：澄清不是改类型，而是选一个动作。接受到默认状态，拒绝进 Canceled，重复进 Duplicate，稍后隐藏到指定时间或新动态出现。
>
> https://linear.app/docs/triage

Triage 的工作内容直接包含弄清问题。

> "Triage is the process of reviewing new work and deciding what should happen next. Teams often use it to evaluate incoming issues before they are scheduled, assigned, or prioritized."
>
> 文档随后列出的 triage 内容：clarifying the problem、deciding whether the work should be tracked、assigning ownership、setting priority、moving the issue into the appropriate next status。
>
> 中文转述：澄清问题、决定是否追踪、指派、定优先级、移到下一状态，全在同一个 issue 上完成。
>
> https://linear.app/docs/conceptual-model

问题作为线程。Linear 不建 question 对象。已答的问题通过 resolve 评论线程结束。

> "Resolving threads clarifies when a question has been answered or a decision is made. This is particularly useful in longer threads to clearly identify the resolution."
>
> 中文转述：问题可以是一条评论线程，resolve 表示已答或已决策。
>
> https://linear.app/docs/comment-on-issues

标签与单选项。标签可分组，组可设为单选。

> "Label groups can be single-select, where you are restricted to adding only one label under that group to the issue, or multi-select, where more than one label under the group can be added to the issue."
>
> 中文转述：用单选标签组模拟一个「类型」字段，例如 Type/Bug。问题可以是 Type/Question，但不是系统级类型。
>
> https://linear.app/docs/issue-property

项目、里程碑、周期。项目围绕结果，里程碑是项目内阶段，cycle 是时间盒。

> "A project is a grouping of issues that have a clear outcome or planned completion date, such as a new feature launch."
>
> 中文转述：项目是结果的容器，issue 是推进它的动作。
>
> https://linear.app/docs/projects

> "Project milestones represent different stages in a project's lifecycle. You can easily create milestones, add issues to milestones, and track the progress of each milestone in a project."
>
> 中文转述：里程碑是项目内的阶段，进度由挂在其下的 issue 完成情况计算。
>
> https://linear.app/docs/project-milestones

> "Cycles are time-boxed periods where a team works on completing a pre-defined set of work."
>
> 中文转述：cycle 是团队节奏，未完成 issue 会滚入下一个 cycle。个人产品不宜照搬。
>
> https://linear.app/docs/use-cycles

提醒语义。Linear 的提醒可以挂在 issue 之外的多种对象上。

> "You can also set issue reminders for an issue, document, project or initiative and receive a notification to your Inbox at the selected time."
>
> 中文转述：提醒是对象的属性，不是任务的专属能力。项目、文档、倡议都能被提醒。
>
> https://linear.app/docs/inbox

## Notion

对象模型。数据库的每一行是一个 page，property 是列。没有固定的任务表结构。

> "The first column is where you enter the name of your database pages. Each column in a Notion table corresponds to a property that gives your item context."
>
> 中文转述：行即页面，列即属性。任务、项目、问题都只是某张数据库里的页面。
>
> https://www.notion.com/help/create-a-database

状态属性。三大类固定，子项可自定义。

> "Track this item's progress using status tags categorized by To-do, In Progress, or Complete."
>
> 中文转述：Status 属性把选项归入 To-do、In Progress、Complete 三组。用户可在组下加子项，不能改三大类。
>
> https://www.notion.com/help/database-properties

> "Choose from one of three categories: To Do, In Progress, or Complete, and create as many sub-categories as you need."
>
> 中文转述：与上一条一致。Notion 用分组约束状态，避免 select 选项各自为政。
>
> https://www.notion.com/help/guides/status-property-gives-clarity-on-tasks

任务与项目模板。官方模板用两张相关联的数据库。

> "Projects and tasks are two separate but related databases. You can record different information in each database and link them with one another."
>
> 中文转述：项目与任务是两个库，靠 relation 关联。任务属于一个项目。
>
> https://www.notion.com/help/guides/getting-started-with-projects-and-tasks

> "One project can have many tasks, but each task should only relate to a single project."
>
> 中文转述：一对多。项目是父，任务是子。
>
> https://www.notion.com/help/guides/getting-started-with-projects-and-tasks

> "The completion property calculates the number of completed tasks per project and displays the percentage as a progress bar."
>
> 中文转述：项目进度由挂在其下的任务完成数计算。项目不需要自己的完成态，进度来自动作。
>
> https://www.notion.com/help/guides/getting-started-with-projects-and-tasks

提醒语义。任意页面可加提醒，数据库提醒依赖 Date 属性。

> "When you add a reminder, Notion will send you a notification to draw your attention back to a particular task, event, or page at the date or time you specify."
>
> 中文转述：提醒可以指向任务、事件或页面。对象不限于任务。
>
> https://www.notion.com/help/reminders

> "You can create reminders in a database if the database has a Date property."
>
> 中文转述：数据库里的提醒挂在日期属性上，不是任务对象上。
>
> https://www.notion.com/help/reminders

问题作为页面与评论。Notion 没有 question 类型。问题可以是一行，也可以是页面里的评论。

> "Offer your opinion or ask a question by commenting on specific parts of a page."
>
> 中文转述：问题可以落在任意页面片段的评论里，评论可 resolve。
>
> https://www.notion.com/help/comments-mentions-and-reminders

## Apple Reminders

对象模型。reminder 是唯一对象。list 用来分类，section 分组，缩进产生子任务，tag 做交叉分类。

> "Create separate lists to organize all your to-do items into categories, like projects, vacation planning, or movies you want to see."
>
> 中文转述：list 是分类容器，项目只是其中一种分类名。
>
> https://support.apple.com/guide/reminders/create-change-or-delete-reminder-lists-remn8f00ee72/mac

> "Indent reminders to turn them into subtasks of the reminder right above them."
>
> 中文转述：子任务是缩进出来的，没有独立对象类型。
>
> https://support.apple.com/guide/reminders/add-subtasks-to-reminders-remn32a9622b/mac

> "Tags are keywords you can apply to your reminders to categorize and view them in flexible, creative ways."
>
> 中文转述：标签是 reminder 上的关键词，可组合成 Smart List。
>
> https://support.apple.com/guide/reminders/tag-reminders-remn45640f4f/mac

> "Smart Lists gather reminders from all your lists based on criteria you choose."
>
> 文档给出的条件包括 tags、date、time、priority、flag、location。另一句原文："The reminders themselves remain in their original lists."
>
> 中文转述：智能列表是保存的查询，条目仍留在原列表。类似 Todoist 过滤器。
>
> https://support.apple.com/guide/reminders/create-custom-smart-lists-remnfec66479/mac

完成语义。完成即隐藏，可撤销为未完成。

> "To indicate that a reminder is done, mark it as complete. The reminder is saved, but it's hidden in the list."
>
> 中文转述：完成是唯一结局。没有目标、问题或取消态。
>
> https://support.apple.com/guide/reminders/mark-reminders-complete-or-incomplete-remndbeda47c/mac

提醒语义。每个 reminder 都可带日期、时间、地点。

> "You can be reminded when individual reminders are due, or when you arrive at or leave a location, such as an address or your car. If you set both types of notifications for a reminder, you're notified either at the time you specify, or when you arrive at the location, whichever comes first."
>
> 中文转述：时间与地点可同时设，先到者触发。
>
> https://support.apple.com/guide/reminders/add-dates-or-locations-to-reminders-remnd4b206fb/mac

「目标」概念。Reminders 用户指南的目录里没有目标或问题章节。项目只作为一句 reminder 出现。

> "Add reminders for to-dos, projects, and anything else you want to track."
>
> 中文转述：项目也被写成 reminder。系统没有结果与动作的分层。
>
> https://support.apple.com/guide/reminders/add-or-change-reminders-remndc729e28/mac

目录证据：https://support.apple.com/guide/reminders/toc/mac 的章节只有 reminders、lists、tags、Smart Lists、notifications、settings，没有 goals 或 questions。

## 提炼

### 问题型条目有没有一等公民

没有。四家都没有 question 类型。问题被放进四种既有结构里：

| 产品 | 问题的承载物 | 是否有独立生命周期 |
|---|---|---|
| Todoist | 任务加 `*`、标签、评论 | 否。仍是任务，只是不可完成 |
| Linear | Triage 状态的 issue、可 resolve 的评论线程、单选标签组 | 部分。Triage 有进出状态，线程有 resolve |
| Notion | page 加 Status/Select 属性或评论 | 否。状态由用户自建 |
| Apple Reminders | reminder 文本 | 否。只有完成 |

结论：把「问题」做成独立对象不是这四家的做法。更常见的做法是让同一个对象带状态，用动作把它分流。这是推断，依据是上面四条路径。

### 不确定项如何分流

四种机制，按明确程度排序：

1. Linear Triage。独立的 issue 状态类别，默认不进正常视图，只能 accept、decline、duplicate、snooze。分流动作最多，状态最清楚。
2. Todoist Inbox。默认落点，用户之后拖进项目。没有强制动作，也没有「拒绝」。
3. Notion 任意数据库。没有统一收件箱，靠用户自己建 Inbox 数据库或 My Tasks 视图。最弱。
4. Apple Reminders 默认列表。新 reminder 落到默认列表，没有澄清阶段。

共同点：捕获时不要求分类，澄清时仍是同一个对象，不给用户第二个池子。这是推断。

### 提醒的对象是什么

| 产品 | 提醒挂载对象 | 提醒系统 |
|---|---|---|
| Todoist | task | 自有 |
| Linear | issue、document、project、initiative | 自有，通知进 Inbox |
| Notion | 任意 page，或数据库的 Date 属性 | 自有，通知进 Inbox |
| Apple Reminders | 每个 reminder 自身 | 系统级 |

分界不在产品成熟度，在提醒系统的承载单位。自有系统可以把提醒挂在任意对象上。Apple Reminders 只能承载可完成条目。VoiceOS 同步到 Apple 提醒事项，因此问题与目标要在那里可见，只能以一个可完成代表的身份出现。这与现有产品文档的结论一致，也解释了为什么「问题与目标默认不进提醒」不是模型错误。这是推断，依据是 Apple Reminders 的完成语义与 VoiceOS 的同步方向。

### 对 VoiceOS 的判断

事实部分：

- `actions.kind` 取 `task`、`opportunity`、`ai_suggestion`，`actions.state` 取 `open`、`completed`、`dismissed`。完成约束是 `CHECK(state!='completed' OR kind='task')`。见 `Sources/VoiceOSCore/Database.swift:195`。
- `clarifyAction` 的决定有 `commit`、`opportunity`、`not`，每条抽取行动只能澄清一次。`opportunity` 改 `kind`，`not` 置 `dismissed`。见 `Sources/VoiceOSCore/ActionStore.swift:133`。
- `promoteAction` 把 `opportunity` 改为 `task`，写 `转为待办` 修订。见 `Sources/VoiceOSCore/ActionStore.swift:170`。
- `actions` 表没有 label 或 tag 列。问题与目标的细分只存在于 `ActionIntentMetadata.intentType`，当前取值有 question、goal、idea、uncertain、claim。见 `Sources/VoiceOSCore/OrganizedPodcast.swift:216`。

推断部分：

- 现在的问题不是「问题与目标」这个池子该不该存在，而是 `kind` 同时承担了对象类型和澄清结果两件事。成熟产品把这两件事拆开。对象类型稳定，澄清结果落在状态上。
- 最小改动方向不是新增表，而是给 `actions` 加一个前置状态或视图，例如 `triage`，抽取项先进入，用户用现有 clarify 的三种决定加一个 snooze 把它分流。这样不必改 kind 的语义，也能让未澄清项与承诺项分开显示。
- 若要让问题与目标在 Apple 提醒事项里每天可见，更符合四家模型的路径是让每个目标或问题带一条下一步待办，而不是把目标本身伪装成 reminder。现有 promote 通道已经是这个方向。

## 可直接迁移的机制清单

个人、本地、单用户可用的机制。团队形状的 SLA、cycle、triage 轮值、指派、多人评论已排除。

| 机制 | 出处 | VoiceOS 现状 | 迁移方式 |
|---|---|---|---|
| 默认收件箱，捕获时不分类 | Todoist Inbox | 部分。有抽取与澄清，没有独立收件箱视图 | 抽取项先进入未澄清视图，不直接落成用户承诺 |
| Triage 作为工作流外状态，默认不进日常视图 | Linear Triage | 缺。澄清直接改 kind | 加前置状态或视图，承诺项与未澄清项分开查询 |
| 显式分流动作 accept / decline / duplicate / snooze | Linear Triage | 部分。已有 commit / opportunity / not，缺 snooze 与 duplicate | 在澄清动作上补 snooze。duplicate 对个人产品可不要 |
| 问题作为可 resolve 的线程 | Linear comments，Notion comments | 缺。问题是一行，没有讨论终止态 | 给问题与目标加线程与「已答」结局，或复用现有讨论 |
| 单选标签组承载问题类型 | Linear label groups | 缺。actions 没有标签 | 先用 intentType 元数据即可，不必加表。用户可编辑时再加列 |
| 提醒挂在任意对象上 | Linear Inbox，Notion reminders | 缺。只有 task 进提醒 | 仅应用内通知可行。Apple 提醒事项仍只收可完成代表 |
| 完成与不作答分开，取消、重复是独立结局 | Linear Canceled / Duplicate，Notion Status | 部分。有 dismissed，没有取消与重复之分 | 若要统计「放弃」与「不是问题」，再加结局枚举 |
| 日期与截止日分开 | Todoist deadlines | 缺。只有一个日期 | 目标可带截止日，动作带计划日。先验证是否真用得上 |
| 目标进度来自子项完成 | Notion project progress，Linear milestones | 缺。promote 不建立父子关系 | 提升时记录 `goalID` 关联，详情页显示完成比例。intent 已有 goalID 字段 |
| 保存视图或智能列表 | Todoist filters，Apple Smart Lists | 部分。有每日回顾，没有保存查询 | 加「未澄清」「无下一步的问题」两个固定视图即可，不做查询语言 |

## 取不到或未验证

- Todoist 帮助中心改版为客户端搜索，旧文章 URL 会跳转。本单元从 Features 索引取得新 URL，未覆盖所有语言与平台差异。
- Linear 文档的 sitemap 不含全部页面。状态与标签细节在 `/docs/issue-property`，由 conceptual model 页内链接发现。
- Notion 官方模板库中的 Projects & Tasks 数据库结构需要在应用内查看。本单元使用帮助中心的模板说明，未读取模板本体。
- Apple Reminders 指南为 macOS 27 版本。旧系统与第三方账户的功能差异未覆盖。
- 四家均未登录、未操作真实工作区。所有结论来自公开文档，不包含付费版实测。
- 没有找到任何一家把「问题」定义为不可完成的独立对象。这个否定结论只对这四款产品成立，不能外推到 GTD 或知识管理工具。A1 与 A3 覆盖那部分。

## 来源

Todoist：
- https://www.todoist.com/help/todoist/features/introduction-to-tasks-080OAXric
- https://www.todoist.com/help/todoist/features/introduction-to-labels-dSo2eE
- https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH
- https://www.todoist.com/help/todoist/features/introduction-to-reminders-9PezfU
- https://www.todoist.com/help/todoist/features/schedule-a-date-and-time-for-your-todoist-tasks-q7VobO
- https://www.todoist.com/help/todoist/features/turn-smart-date-recognition-on-or-off-63WfIr
- https://www.todoist.com/help/todoist/features/add-comments-or-files-to-tasks-in-todoist-CwiA50
- https://www.todoist.com/help/todoist/features/whats-the-difference-between-the-inbox-and-a-project-d6dSLqAM
- https://www.todoist.com/help/todoist/features/create-an-uncompletable-task-in-todoist-QxQosZuF
- https://www.todoist.com/help/todoist/features/use-sub-tasks-in-todoist-kMamDo
- https://www.todoist.com/help/todoist/features/use-task-quick-add-in-todoist-va4Lhpzz
- https://www.todoist.com/help/todoist/features/introduction-to-deadlines-in-todoist-uMqbSLM6U

Linear：
- https://linear.app/docs/conceptual-model
- https://linear.app/docs/issue-property
- https://linear.app/docs/creating-issues
- https://linear.app/docs/triage
- https://linear.app/docs/inbox
- https://linear.app/docs/projects
- https://linear.app/docs/project-status
- https://linear.app/docs/project-milestones
- https://linear.app/docs/use-cycles
- https://linear.app/docs/comment-on-issues
- https://linear.app/docs/filters

Notion：
- https://www.notion.com/help/reminders
- https://www.notion.com/help/database-properties
- https://www.notion.com/help/create-a-database
- https://www.notion.com/help/comments-mentions-and-reminders
- https://www.notion.com/help/tasks-and-dependencies
- https://www.notion.com/help/guides/status-property-gives-clarity-on-tasks
- https://www.notion.com/help/guides/getting-started-with-projects-and-tasks
- https://www.notion.com/help/guides/give-your-to-dos-a-home-with-task-databases

Apple Reminders：
- https://support.apple.com/guide/reminders/toc/mac
- https://support.apple.com/guide/reminders/add-or-change-reminders-remndc729e28/mac
- https://support.apple.com/guide/reminders/add-subtasks-to-reminders-remn32a9622b/mac
- https://support.apple.com/guide/reminders/mark-reminders-complete-or-incomplete-remndbeda47c/mac
- https://support.apple.com/guide/reminders/tag-reminders-remn45640f4f/mac
- https://support.apple.com/guide/reminders/add-dates-or-locations-to-reminders-remnd4b206fb/mac
- https://support.apple.com/guide/reminders/create-custom-smart-lists-remnfec66479/mac
- https://support.apple.com/guide/reminders/create-change-or-delete-reminder-lists-remn8f00ee72/mac
