---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: main
owner: coordinator
---

# 信息层级研究波（实测成熟应用）

## 目标

用户判定 VoiceOS 当前信息展示层级「非常糟糕」，要求加大向成熟方案学习的力度。本波只做研究，不改代码：对已装成熟应用做实测（字号阶梯、行高、间距节奏、分组方式、色彩语义、渐进披露），与 VoiceOS 现状对照，产出带实测数据的层级规范，供后续实施波次遵循。

基线 `main` 为 `69a5b5c`。

## 单元

### H1 Apple 应用实测
目标：提醒事项、备忘录、邮件、系统设置、日历。每款测：标题/区块头/正文/次要文字的实测字号与字重（像素测量，标注方法）、行高、区块间距、分组容器（卡片/分隔线/底色）、色彩语义（强调色、次要文字、状态色）、渐进披露与导航层级。截图存 `/tmp/hier-apple-*.png`，引用对应 HIG 页面。

### H2 第三方应用实测
目标：Obsidian、Folo、飞书、微信读书、Zotero、Anki。同样的测量项，另记：信息密集型列表如何控制噪音（每行显示哪些字段）、主次操作如何区分、长内容页的阅读层级。

### H3 VoiceOS 现状审计
对运行中的 `dist/VoiceOS.app`（pid 见 `pgrep -fl dist/VoiceOS`）逐页截图（首页、行动、材料、主题、设置、阅读），并从 `Sources/VoiceOSApp/WorkspaceDesign.swift`、`WorkspaceTheme.swift`、`WorkspaceView.swift` 提取实际使用到的字号、字重、间距、颜色与层级元素，列出具体缺陷（含文件行号与证据），按严重度排序。

## 约束

- 只读：不改任何代码，不写用户资料库，不干扰正在运行的 VoiceOS 实例。
- 截图与测量均用真实运行的应用；每个数字注明获取方式（AX 框架、像素测量、代码常量）。
- 不估猜：取不到的项目写明原因。

## 结果

（待填）

## 链接

- `docs/product/interface-reference.md`
