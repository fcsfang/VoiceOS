# A1 GTD 与项目型任务管理研究

日期：2026-11-15。范围：GTD、OmniFocus、Things 3 的公开模型。只读研究，不改代码，不提交。

目标：回答 VoiceOS 的「待办 vs 问题与目标」模型是否该改，以及成熟产品如何建模「结果」与「动作」的关系、停滞如何浮现、将来也许如何与动作分开、回顾扮演什么角色。

## 结论摘要

1. 三个成熟模型都区分「结果」与「动作」，并用关系连接两者。GTD 用项目清单加下一步行动清单。OmniFocus 用容器。Things 用区域加项目。VoiceOS 现在没有这层关系，`kind` 只是同一张表上的标签。
2. 停滞项目的发现是一条关系查询：活跃结果加零个可执行子项。OmniFocus 把它做成可保存的过滤规则，GTD 把它放进周回顾。VoiceOS 没有关系，所以这条查询无法表达。这是推断，依据是下面的手册原文与 VoiceOS 现状描述。
3. 将来也许是第三种状态，有回顾路径，不是垃圾桶。GTD 叫 incubate，Things 叫 Someday，OmniFocus 用 On Hold 加 Defer。VoiceOS 的 opportunity 没有回顾路径，也没有完成态，三家都没有对应的形状。
4. 回顾是让清单可信的机制。GTD 把它称为 critical success factor。OmniFocus 给每个项目设下次回顾日期和回顾间隔。Things 给 Someday 设每两个月的节奏，并建议每天看 Inbox 与 Today。
5. 对 VoiceOS 的直接含义：问题不在「要不要保留问题与目标」，而在缺少关系、状态和回顾。`docs/product/todo-and-questions.md` 的「结果与动作两层」方向与三家一致。`docs/product/reference-products.md` 里「待办与问题与目标已经是下一步行动与将来也许的形状」这一判断不成立。现有机会池把「项目」与「将来也许」混在了一起，这是推断。

## 方法与取数边界

- 用 curl 抓官方页面正文，用本地 HTML 转文本脚本阅读。引用保留英文原文，中文为转述。
- OmniFocus 与 Things 的官方文档可直接访问。
- GTD 主站 `gettingthingsdone.com` 对 curl 返回 403，Cloudflare 挑战页。`davidco.com` 跳转到同一站，同样 403。archive.org、archive.ph、Google 缓存、翻译代理均连接失败。可访问的官方材料是 David Allen Company 的商店子域 `store.gettingthingsdone.com` 的产品说明，以及官方培训伙伴 Crucial Learning 的课程页。澄清决策树的细节用公开 GTD 摘要页 Todoist 指南补齐，并标注为二手摘要。
- 检索日期均为 2026-11-15。

## 1. GTD（David Allen）

### 模型图

```
捕获 inbox
  ↓
澄清，对每一件事问
  可行动吗
    否 → 垃圾 / 参考资料 / 将来也许（incubate）
    是 → 下一步行动是什么
           两分钟内能做完 → 立刻做
           能交给别人   → 等待他人（waiting for）
           不能马上做   → 日历或下一步行动清单
  ↓
组织
  下一步行动清单（按情境分组）
  项目清单（每个结果一行，项目本身不是动作）
  日历
  等待清单
  将来也许清单
  参考资料
  ↓
回顾（每周回顾，逐项检查项目清单，保证每个活跃项目有下一步行动）
  ↓
执行
```

关键结构是两张平行的清单。项目清单记录结果，下一步行动清单记录动作。项目不需要成为容器，但每个活跃项目必须能在行动清单里找到它的下一步行动。

### 关键规则

- 五步是 Capture、Clarify、Organize、Reflect、Engage。
- 澄清的第一问是可行动吗。不可行动的进入垃圾、参考资料或将来也许。可行动的继续问下一步行动。
- 两分钟规则：两分钟内能完成的事立刻做。
- 能委托的事交给别人，进入等待。
- 不能马上做的进入日历或下一步行动清单。这是 defer 的位置。
- 项目是任何需要多于一步才能完成的事。Todoist 摘要的原话是 "projects are any item that requires more than one step to complete"。
- 下一步行动是下一次有机会就能执行的具体动作，与将来行动分开存放。
- 将来也许是想做但现在没有带宽做的事，需要之后回看，不要让它占住当前系统。
- 每周回顾是让系统可信的关键动作。Todoist 摘要引用 David Allen 的说法，称其为 "critical factor for success"。

### 原文与出处

官方商店，GTD Workflow Map 产品说明。https://store.gettingthingsdone.com/product/gtd-workflow-map-pdf-download/

> "The Map gives wonderful, illustrated detail on how the steps of your workflow tie together"
>
> Capture
> Clarify
> Organize
> Reflect
> Engage

转述：官方把工作流概括为捕获、澄清、组织、回顾、执行五步。原文是五个并列的项目符号。

官方商店，GTD Methodology Guides 产品说明。https://store.gettingthingsdone.com/product/gtd-methodology-guides/

> "The GTD Weekly Review® checklist (to coach you through the critical success factor)"

转述：官方把周回顾称为关键成功因素，并单独提供检查清单。

> "The GTD Clarifying Map (featuring the updated version released in 2015)"

转述：官方有独立的澄清决策图。澄清不是一条说明文字，而是一张正式的判断图。

官方培训伙伴 Crucial Learning。页面声明 "Crucial Learning is the exclusive provider of Getting Things Done® training in North America, developed in partnership with David Allen and the David Allen Company." https://cruciallearning.com/courses/getting-things-done/

> "Identify next actions to get moving and overcome procrastination."

转述：澄清的输出是下一步行动。

> "Create and track a simple, personalized inventory of your projects."

转述：除行动外，还要维护一份项目清单。

> "Get clear on your highest priorities and stay engaged with them through a GTD Weekly Review®."

转述：周回顾负责把行动与更高层目标重新对齐。

公开摘要，Todoist 的 GTD 指南。https://www.todoist.com/productivity-methods/getting-things-done

> "Use the two-minute rule, when a task takes less than two minutes, complete it right away."

转述：两分钟规则。

> "Delegate tasks to someone else, if possible."

转述：能委托就委托。

> "Delete tasks that are no longer actionable."

转述：不可行动的东西不留在行动清单。

> "Create a project for tasks that require more than one step to house all of its sub-tasks. Then identify the next action you can take to move the project forward."

转述：多步的事升级为项目，并且必须找出下一步行动。

> "File away non-actionable reference items"

转述：不可行动的参考资料单独存放。

> "You can use our Getting Things Done flowchart to aid you in deciding what to do with actionable tasks and whether to delegate, defer, or do them immediately."

转述：可行动项的三个出口是委托、推迟、立刻做。这里出现了 defer 这个词。

> "In the GTD philosophy, projects are any item that requires more than one step to complete."

转述：项目定义。

> "These are tasks with a clear, concrete action you'll do at the next opportunity" 以及 "Next actions are separate from future actions"

转述：下一步行动是具体动作，并且与将来行动分开。

> "These items are ideas for things you want to do in the future but don't have the bandwidth to work on now."

转述：将来也许的定义。它们会被回看，但不占用当前系统。

> "Each week, set aside time to review your lists, organize your tasks, and keep your system running smoothly."

转述：每周回顾的节奏。

> "The review helps you adapt to changes, refocus your attention, identify next actions, and reflect on your workflow."

转述：回顾的具体产出包括重新识别下一步行动。

取材说明：Todoist 指南是公开摘要，不是 David Allen Company 原文。五步、周回顾、澄清图的存在由官方商店产品说明支撑。澄清决策树的分支细节来自公开摘要。主站原文因 403 未能取得。

## 2. OmniFocus

### 模型图

```
Folder（可选，可嵌套）
└─ Project
   type   = Parallel / Sequential / Single Actions List
   status = Active / On Hold / Completed / Dropped
   dates  = Defer Until / Due
   review = Next review / Review every / Last reviewed
   └─ Action Group（可选，可嵌套，本身就是 subproject）
      └─ Action
         status = Active / Completed / Dropped
         fields = Defer Until / Due / Flag / Tags / Estimated Duration / Repeat
```

容器与属性会向下继承。日期、状态、可用性、旗标、标签都可以从容器继承。容器的日期给子项设边界。Defer Until 不能早于容器的 Defer Until，Due 不能晚于容器的 Due。

### 关键规则

- 层级是文件夹、项目、行动组、行动。文件夹装文件夹或项目。项目与行动组装行动或行动组。行动组在手册里被称为 subprojects。
- 项目有三种类型。Parallel 项目的行动可以任意顺序完成。Sequential 项目必须从上到下完成，只有最上面的活跃行动可用。Single Actions List 装彼此可能相关但不属于某个整体目标的行动。
- 项目有四种状态。Active 是默认状态。On Hold 表示不确定是否继续，在只显示 Available 的视图里会被隐藏，但仍可回顾。Completed 表示到达成功终点，会顺带完成未完成行动。Dropped 表示决定不再做，保留记录但隐藏。
- Defer Until 决定什么时候可以开始工作。Due 决定什么时候必须完成。两者是不同字段，可以同时存在。
- 每个项目有 Next review 日期、Review every 间隔、Last reviewed 日期。默认间隔是每周，从项目创建一周后开始。
- Review 透视列出到期需要回顾的项目，一次只显示一个项目。Mark Reviewed 会把 Last reviewed 设为今天，并按间隔推进 Next review。
- 停滞的官方定义是 Active 项目没有任何剩余行动。术语表说明，旧版本的 Stalled 过滤规则现在叫 "Has an active project which has no remaining actions"。
- Inbox 是捕获入口。给条目加上项目或标签就把它变成行动。需要更多行动时，把条目转成项目。
- Single Actions List 是重要反例。它明确容纳「不属于某个整体目标」的单独行动。系统在建模时承认有些行动没有上层目标，不需要硬塞进项目。

### 原文与出处

OmniFocus 4 Reference Manual，版本 4.3.3。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/

容器与继承，https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/the-outline/#containers-and-properties

> "folders can contain folders or projects, while projects and action groups can contain actions or action groups."

转述：文件夹、项目、行动组、行动的 containment 关系。

> "When you add a Defer Until date to an action, action group, or project, you are telling OmniFocus that the item is not available for work until the Defer Until date has passed. When you add a Due date, you are telling OmniFocus that the item must be resolved before the Due date occurs."

转述：Defer 是可用时间，Due 是截止时间，两者语义不同。

项目类型，https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/perspectives/#project-type

> "Single actions lists contain actions that may (or may not) be related in some way, but that are not part of an overall goal."

转述：没有整体目标的行动有自己的合法容器，不必伪装成项目。

项目状态，https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/perspectives/#project-status

> "If you're not sure whether you want to continue a project, you can change the project's status to On Hold."

转述：On Hold 是暂停但不删除的状态，仍然可以被回顾。

> "Eventually you'll reach the successful end of a project."

转述：项目有成功终点，可以 Completed。

> "If you have decided not to work on a project any longer, you can set it to Dropped."

转述：放弃是独立状态，和完成分开。

回顾，https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/perspectives/#review

> "If you have projects that need actions added, projects that aren't relevant anymore, or projects you don't plan to do any time soon, following a regular review process can help keep them from falling through the cracks."

转述：Review 的存在理由就是抓住需要补行动、已经无关、短期不做的项目。

> "The Review Sidebar presents those projects in a flat list, intentionally ignoring any structure that you have created in the Projects perspective."

转述：回顾视图故意抹平项目结构，防止被文件夹遮住。

回顾间隔，https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/the-inspector/#review-inspector

> "By default, projects are set to be reviewed every week, beginning one week after the project is created."

转述：每个项目默认每周回顾一次。

> "Sets Last reviewed date to today, sets the Next review date for the project based on the Review every interval, and then presents the next project in the list."

转述：Mark Reviewed 会推进回顾日期，而不只是打勾。

停滞定义，https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/glossary/#stalled

> "This Custom Perspective filter rule from earlier versions of OmniFocus is now named Has an active project which has no remaining actions."

转述：停滞就是活跃项目没有剩余行动。

过滤器规则，https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/custom-perspectives-pro/#contents

> "Includes any item that is part of a Project which is both Active and contains no Remaining actions."

转述：停滞可以被表达为一条可保存的查询条件。

Inbox，https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/perspectives/#inbox

> "Adding a project or tags to an item turns it into an action, and converting it into a project allows you to add even more actions"

转述：捕获后先决定它属于哪个项目，或者把它升级成项目。

行动组，https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/the-outline/#grouping-actions

> "action groups are sometimes referred to as subprojects."

转述：项目内部允许再分层。

## 3. Things 3

### 模型图

```
Area（ongoing，不可完成）
├─ Project（可完成，可设 start date、deadline、reminder，可进 Someday）
│  ├─ Heading（可选，长项目分组）
│  │  └─ To-do（start date、deadline、reminder、checklist、tags）
│  └─ To-do
└─ To-do（可以直接挂在区域下）

松散 To-do 也可以停在 Inbox
```

时间面是另一套正交视图。

```
Inbox      未处理的捕获
Today      今天要开始的事，含 This Evening
Upcoming   有未来 start date 的事，休眠到日期到达
Anytime    现在随时可以做、没有被阻塞的事
Someday    还没想清楚、将来也许可做的事
Logbook    完成或取消的事
```

Anytime、Upcoming、Someday 对活跃条目互斥。Someday 里的项目会从侧栏消失。Upcoming 里的项目也会休眠。

### 关键规则

- 区域是持续的责任，不可完成。项目是可完成的目标。待办是动作。
- 项目用来装需要多步的事。每个步骤可以成为独立待办，带自己的备注、标签、日期。
- 项目像待办一样可以被安排、推迟、放进 Someday、完成。这条把「目标」和「动作」放在同一套时间语义里。
- Someday 是状态，不是另一种对象。待办和项目都能进 Someday。进入后既不显示在 Anytime，也不显示在 Upcoming，侧栏里的项目会消失。
- Someday 需要回看，官方建议每两个月看一次。
- Inbox 是未处理想法的临时落脚点。官方建议经常清空，把每个想法变成正式待办。
- 不要过度规划。官方建议只关注接下来的 1 到 3 步。
- 没有文档化的停滞项目检测。这是文档缺失，不是功能断言。能确认的是：项目没有活跃待办时，它的名字不会出现在 Anytime。项目进度用 Progress Pies 显示完成度，不显示是否缺下一步。

### 原文与出处

区域，https://culturedcode.com/things/support/articles/6037627/

> "Areas help keep everything tidy. They can hold related projects and to-dos, organized around a theme"

转述：区域容纳项目和待办。

> "Unlike projects, areas are ongoing and can't be completed, serving as a continuous framework for different parts of your life."

转述：区域与项目的关键差别是完成语义。区域永远不完成。

项目，https://culturedcode.com/things/support/articles/8491676/

> "For bigger to-dos, create a project. Projects allow each step to become a to-do, complete with notes, tags, and dates if needed."

转述：项目把目标拆成多个可执行待办。

> "Projects are just like to-dos. Add deadlines, schedule them for later, indefinitely postpone them in Someday, and complete them when they're done."

转述：项目有和待办相同的排期与完成能力，包括无限期放进 Someday。

> "Avoid over-planning. You don't need a full roadmap for every new project. Just focus on the next 1-3 steps to maintain momentum."

转述：项目只要求近期的少量下一步，不要求完整路线图。

Someday，https://culturedcode.com/things/support/articles/4001304/

> "Someday is for everything that's not clear yet but might become actionable at a later time."

转述：Someday 收的是未清晰、可能以后可行动的东西。

> "While they slumber in Someday, neither to-dos nor projects will show up in Anytime or Upcoming, and inactive projects disappear from the sidebar."

转述：Someday 让条目退出当前视野，但不是删除。

> "Review this list every couple of months."

转述：Someday 有明确回看节奏。

> "Because the list contains only active to-dos, its contents and what you see in Upcoming and Someday are mutually exclusive."

转述：Anytime、Upcoming、Someday 三者互斥，状态清楚。

Inbox，https://culturedcode.com/things/support/articles/4001304/

> "It's a temporary staging ground for your unprocessed thoughts."

转述：Inbox 是临时捕获区。

> "clarifying what you've captured will make it easier to stay focused."

转述：捕获之后要澄清。

时间面，https://culturedcode.com/things/support/articles/2803579/

> "To-dos (and projects) with future start dates hibernate in Upcoming until their start date arrives."

转述：未来开始日期让条目休眠，到期自动回到 Today。

> "Contrary to start dates, which describe when you want to begin working on a task, deadlines define the date by which you must finish the to-do."

转述：开始日期与截止日期分开。

产品结构，https://culturedcode.com/things/features/

> "The sidebar neatly groups projects underneath their area for added clarity."

转述：侧栏的层级是区域之下放项目。

> "See the progress of your projects at a glance and see just how close you are to achieving your goal."

转述：项目被当成目标，进度按完成度显示。

停滞检测的文档缺口：抓取的支持文章与 features 页均未描述类似 OmniFocus Stalled 的过滤器。只能确认 Anytime 会省略没有活跃待办的项目，见 4001304 原文 "If one of your projects or areas doesn't contain any active to-dos the list's name will not appear here"。是否另有隐藏的停滞提示，本次未找到官方说明。

## 4. 横向提炼

### 4.1 结果与动作如何建模

三种做法。

1. GTD 用两张平行清单。项目清单记录结果，行动清单记录动作。关系是引用，不是容器。每个活跃项目必须有一个下一步行动，否则周回顾会抓出来。
2. OmniFocus 用容器加类型加状态。项目是容器，有 Parallel、Sequential、Single Actions List 三种类型，有 Active、On Hold、Completed、Dropped 四种状态。Single Actions List 明确容纳不属于任何目标的行动。
3. Things 用三级结构加完成语义。区域不可完成，项目可完成，待办可勾选。三层各自有清楚的完成规则。

共同点有三条。

- 结果和动作是两种不同的东西，不靠一个 `kind` 字段区分就算完。
- 结果可以完成或放弃。三家都有这个出口。
- 动作始终是可执行、可提醒的单位。结果本身不被提醒，但结果必须能产出下一步动作。

VoiceOS 的差距是关系缺失。`actions` 表里 task 和 opportunity 是并列的两行，澄清还会把 task 改成 opportunity，原动作消失。三家都不这样做。GTD 会保留项目，另建下一步行动。OmniFocus 会保留项目，在项目下加行动。Things 会保留项目，把步骤变成待办。这是本条最重要的迁移结论。

### 4.2 停滞项目如何浮现

- GTD 靠周回顾。项目清单逐项过，问每个项目有没有下一步行动。没有就补，或者移到将来也许，或者放弃。
- OmniFocus 靠查询加回顾。查询条件是「Active 项目且没有剩余行动」。这个条件可以保存为自定义透视。Review 透视则按每个项目的回顾日期把项目送到眼前。官方对 Review 的说明直接点名「需要补行动的项目」。
- Things 没有文档化的停滞检测。Anytime 只列有活跃待办的项目，项目页用完成度显示进度。官方建议每天清 Inbox，定期看 Someday，但没有说系统会主动提示「这个项目没有下一步」。

对 VoiceOS 的含义。用户看不到 opportunity，表层原因是提醒事项只认 task。深层原因是模型里没有「结果包含动作」这条关系，所以系统无法回答「哪些结果没有下一步」。修提醒同步只能治表层。要复现 OmniFocus 的机制，先要有父子关系，再加一条「活跃结果且零个可执行子项」的查询。这是推断。

### 4.3 将来也许如何与动作分开

三家都把「现在不做」单独建模，并且都给回看路径。

- GTD 的 incubate 列表，也就是 Someday/Maybe。它不是项目，也不是下一步行动，定期回看后决定升级或丢弃。
- OmniFocus 用 On Hold 状态和 Defer Until。On Hold 项目在只显示 Available 时隐藏，但仍在 Review 中出现。
- Things 用 Someday 状态。待办和项目都能进，进入后从 Anytime 与 Upcoming 消失，每两个月回看一次。

共同规则是：将来也许不等于不重要，也不等于垃圾。它需要一个可见的清单和一个回看节奏。

VoiceOS 的 opportunity 同时装着「长期目标」「待弄清的问题」「待核对的事项」「录音里提到但还没处理的活动」。这四类里只有「待核对的事项」本来是动作。其余三类里，目标应该按项目建模，将来也许应该按孵化状态建模，未知问题应该保留为问题并挂一个「找到答案」的下一步。把三者塞进同一个不可完成的 kind，等于把 GTD 的项目清单、Someday 清单和参考清单合成一个黑箱。这是推断，依据是现状描述与三家的模型对照。

### 4.4 回顾扮演什么角色

- GTD 把周回顾称为关键成功因素。回顾的产出是修正后的下一步行动和项目清单。
- OmniFocus 把回顾做成数据。每个项目有下次回顾日期和间隔，Review 透视按日期排队，Mark Reviewed 推进日期。回顾不靠记忆。
- Things 把回顾分散到多个节奏。每天看 Inbox 和 Today，每两个月看 Someday，做周计划时看 Upcoming，避免把一天排爆。

VoiceOS 已有每日回顾，按 `docs/product/todo-and-questions.md` 的代码事实，回顾门槛只认 task。所以问题与目标从不进入任何回顾。三家都认为结果需要回顾，而且 OmniFocus 证明回顾可以是一条日期字段加一条查询，不需要新子系统。

### 4.5 与 VoiceOS 现状的差距

基于任务简报与两份产品文档，逐条对照。

| 机制 | 出处 | VoiceOS 现状 | 判定 |
|---|---|---|---|
| 动作可完成、可排提醒、同步 Apple 提醒事项 | `docs/product/todo-and-questions.md` 的代码事实；Things 时间面 | task 已具备 | 已有 |
| 结果作为容器承载多个动作 | OmniFocus 容器；Things 项目；GTD 项目清单 | 无父子关系，同表并列 | 缺 |
| 活跃结果必须有下一步动作 | GTD 周回顾；OmniFocus Review | 无关系可检查 | 缺 |
| 停滞查询：活跃结果加零剩余动作 | OmniFocus 自定义透视 | 无法表达 | 缺 |
| 结果可完成或放弃 | OmniFocus Completed 与 Dropped；Things 项目可完成 | opportunity 不可完成 | 缺 |
| 结果状态 Active、On Hold、Completed、Dropped | OmniFocus 项目状态 | opportunity 只有一个隐含的冻结态 | 缺 |
| 将来也许作为可回顾的孵化状态 | GTD Someday/Maybe；Things Someday；OmniFocus On Hold | opportunity 混装目标与将来也许，无回顾 | 缺 |
| 每个结果有下次回顾日期和间隔 | OmniFocus Review inspector | 无 | 缺 |
| 可用日期与截止日期分开 | OmniFocus Defer 与 Due；Things start date 与 deadline | 只有提醒日期，推断没有 defer 概念 | 缺 |
| 先捕获后澄清 | GTD；Things Inbox；OmniFocus Inbox | 录音与 AI 建议承担捕获，澄清只有单向 task 到 opportunity | 部分已有 |
| 参考资料的存放 | GTD reference；OmniFocus 备注与附件 | 知识库可能承担，推断 | 部分已有 |
| 等待他人 | GTD waiting for | 无独立状态 | 缺 |
| 项目类型 Parallel、Sequential、Single Actions List | OmniFocus | 无 | 缺 |
| 区域：长期责任，不可完成 | Things Areas | 无 | 缺 |
| 只规划最近 1 到 3 步 | Things 项目建议 | 无 | 缺 |
| 每日回看今天 | Things Today；`DailyReview.swift`，见产品文档 | 每日回顾存在 | 已有 |
| 结果与动作的双向通道 | GTD 在项目下添下一步；VoiceOS clarify 单向 | 只有 task 到 opportunity，反向缺失 | 缺 |

## 5. 对「该不该改模型」的研究结论

这是研究结论，不是产品决定。

1. 三家成熟模型都不存在「不可完成且不进任何回顾的目标池」。OmniFocus 的项目有 Completed 与 Dropped，Things 的项目可以完成，GTD 的项目完成后离开项目清单。VoiceOS 的 opportunity 是三家里的异类。
2. 三家的目标都不会与动作脱钩。GTD 用周回顾强制，OmniFocus 用查询加回顾强制，Things 用项目内待办和近期 1 到 3 步的建议降低脱钩概率。VoiceOS 允许 opportunity 永远没有下一步，而且没有机制把它拉回视线。
3. 「将来也许」在三家里都有独立位置和回看节奏。VoiceOS 没有独立位置。把它并进 opportunity 会让目标看起来像拖延清单，也会让拖延清单看起来像目标。
4. 修复方向不必是重做整张表。最小的结构增量是两条。第一，结果与动作之间有一条持久关系。第二，一条覆盖「活跃结果没有可执行子项」的查询和回顾节奏。`docs/product/todo-and-questions.md` 已经写出「结果与动作两层」的方向。需要修正的是实现描述里的 `promoteAction`：当前描述把 opportunity 的 `kind` 改成 task，这会消耗掉结果本身。按三家模型，正确动作是保留结果并生成它的下一步动作。这是推断，依据是产品文档的实现段落与三家模型。
5. `docs/product/reference-products.md` 第 47 行的判断需要修正。「待办与问题与目标已经是下一步行动与将来也许的形状」把项目清单和将来也许混为一谈。GTD 是项目清单、下一步行动、将来也许、等待、参考五个位置。VoiceOS 现在是两个 kind。差距不是一步，是三个位置。

## 6. 来源

检索日期均为 2026-11-15。

官方与官方伙伴。

- David Allen Company 商店，GTD Workflow Map。https://store.gettingthingsdone.com/product/gtd-workflow-map-pdf-download/
- David Allen Company 商店，GTD Methodology Guides。https://store.gettingthingsdone.com/product/gtd-methodology-guides/
- Crucial Learning，Getting Things Done 课程。https://cruciallearning.com/courses/getting-things-done/
- OmniFocus 4 Reference Manual，版本 4.3.3。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/
  - 容器与继承。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/the-outline/#containers-and-properties
  - 行动组。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/the-outline/#grouping-actions
  - 项目类型。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/perspectives/#project-type
  - 项目状态。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/perspectives/#project-status
  - Review。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/perspectives/#review
  - Inbox。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/perspectives/#inbox
  - Defer Until。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/the-inspector/#defer-until-inspector
  - Due。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/the-inspector/#due-inspector
  - Review inspector。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/the-inspector/#review-inspector
  - Stalled 术语。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/glossary/#stalled
  - 自定义透视过滤规则。https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/custom-perspectives-pro/#contents
- Things 支持文档。
  - 区域。https://culturedcode.com/things/support/articles/6037627/
  - 默认清单。https://culturedcode.com/things/support/articles/4001304/
  - 排期。https://culturedcode.com/things/support/articles/2803579/
  - 项目与卡住的待办。https://culturedcode.com/things/support/articles/8491676/
  - 上手指南。https://culturedcode.com/things/support/articles/6378414/
  - 功能页。https://culturedcode.com/things/features/

公开摘要，二手。

- Todoist，Getting Things Done 指南。https://www.todoist.com/productivity-methods/getting-things-done

## 7. 取不到的项目与原因

1. `gettingthingsdone.com` 的方法论正文。curl 返回 403，页面是 Cloudflare 的 "Just a moment..." 挑战页。`davidco.com` 跳转到同一站，同样 403。所以无法直接引用官方对五步与澄清问题的原文。
2. archive.org 与 archive.ph 的官方页快照。连接超时，HTTP 000，DNS 可解析但 TCP 不通。
3. Google 缓存与 Google Translate 代理。HTTP 000，不可达。
4. Wikipedia 的 GTD 条目。HTTP 000，不可达。
5. OmniFocus 旧版本的 Stalled 内置筛选界面说明。当前 4.3.3 手册只保留术语表定义，说明旧过滤规则现在叫 "Has an active project which has no remaining actions"。旧版界面是否内置该筛选，本次没有取到官方旧手册。
6. Things 的停滞项目检测说明。官方支持文章与 features 页都没有描述。报告的是文档缺口，不是确认功能不存在。
7. GTD 原书原文。没有合法可取的在线全文，未使用。澄清问题细节用 Todoist 公开摘要补齐，已在正文标注。

## 8. 供 A2 与 A3 复用的结构判断

- 结果与动作的关系有两种成熟画法，平行清单和父子容器。VoiceOS 选父子容器更贴近现有单表结构，也与 `docs/product/todo-and-questions.md` 的两层方向一致。
- 停滞不是结果上的一个字段，而是关系上的查询结果。任何没有关系的数据模型都做不出这个功能。
- 将来也许必须是状态，并且必须进回顾。只加一个 kind 不加回顾，等于把垃圾箱改名。
- 回顾需要日期字段。OmniFocus 的 Next review 加 Review every 是最小实现。
