# 波 69 任务书（2026-11-18）：官网正文去站点导航

## 背景（实机发现 2026-11-18，波 68 安装后走查）

证据行实机展开暴露正文污染：研究生院通知的存储正文以标题开头后紧跟站点导航「后台管理 首页 机构设置 研院简介 历史沿革 现任领导和分工 研院机构和职责 联系方式 院长信箱 招生工…」。导航经 `ArticleExtractor` 原样进入 `monitor_messages.content`，直接污染分析输入（模型可能把导航当正文引用）与证据片段。

结构核对（cs.nuaa.edu.cn 真实文章页，curl 抓取）：正文在 `div.pageR_article > div.infoA > div.con`；导航在 `div.top_nav` / `div.pc_nav` / `div.crumbs`，均为纯链接行；`hiddenBlocks` 已丢弃 `<nav>` 但该 CMS 用 div，未命中。

## 完成判据

1. `ArticleExtractor.extract` 增加链接主导行的过滤：转换前给每个 `<a>` 内容加哨兵包裹（U+0001/U+0002），逐输出行统计「锚文本字符占比」与「链接个数」；占比 > 60% 且链接个数 ≥ 2 的行整行丢弃，其余行去除哨兵保留。单链接行（如「附件：报名表.docx」）不丢。
2. 真实形态 fixture（子目录导航 + 面包屑 + 正文 div + 末尾单链接附件行）断言：导航词不出现、面包屑不出现、正文段落保留、附件行保留。
3. 既有五种场景不回归：隐藏块剥离、实体解码、段落换行、80 字下限、标题回退（现有测试原样通过）。
4. 不引入依赖、不改调用方、不加迁移；本波只修未来采集的正文，已存储消息不回改。
5. 测试 ≤ 3 个新用例（含 fixture 主场景、单链接行保留、纯文本无锚行不受影响），中文断言。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0；基线 main f59c030 共 607 项。

## 文件所有权

- `Sources/VoiceOSPlatform/ArticleExtractor.swift`
- `Tests/VoiceOSCoreTests/ArticleExtractorChecks.swift`
- 不碰消息监测管线、QQ 脚本、界面、提醒同步、主题组织；不加迁移。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；不访问网络跑真实站点（fixture 来自本任务书背景里已抓取的页面结构，测试内联字符串）。
- 分支 `work/m69-article`，提交回报；不 push、不合并、不重建 dist。

## 结果

- 分支：`work/m69-article`（基于 main `f59c030`；构建前 merge main，已是最新）
- 提交：`8388090` fix(消息监测): 官网正文过滤链接主导行，站点导航不再进入正文；本结果随后一次 docs 提交
- 验证：`swift build -j 2` exit 0（Build complete 2.41s）；`swift test -j 2` exit 0，610 项测试 0 失败（基线 607 + 本波 3）
- 文件清单：
  - `Sources/VoiceOSPlatform/ArticleExtractor.swift`
  - `Tests/VoiceOSCoreTests/ArticleExtractorChecks.swift`
- 判据落点：
  1. `ArticleExtractor.extract` 在块标签转换前把 `<a ...>` 与 `</a>` 替换为 U+0001/U+0002 哨兵；`dropLinkDominatedLine` 逐行统计锚文本字符数与链接个数，可见字符为 0 的行整行丢弃，链接数 ≥ 2 且锚文本占比 > 60% 的行整行丢弃，其余行去除哨兵保留。
  2. `testDropsNavigationAndBreadcrumbLinkLines` 用真实形态 fixture（top_nav、pc_nav、crumbs、pageR_article > infoA > con、末尾单链接附件行）断言导航词与面包屑不出现、正文段落保留、附件行保留；修复前该用例 4 条断言失败，其余两条新增用例先通过。
  3. 既有五个用例（隐藏块剥离、实体解码、段落换行、80 字下限、标题回退）原样通过，未改断言。
  4. 未引入依赖、未改调用方（`WebsiteMonitor` 与 `WebArticle` 无需改动）、未加迁移；只修未来采集，已存储消息不回改。
  5. 新增 3 个用例：fixture 主场景、单链接行保留（`testKeepsSingleLinkLine`）、纯文本无锚行不受影响（`testKeepsPlainTextLinesWithoutAnchors`），断言为中文。
  6. `swift build -j 2` / `swift test -j 2` 真实退出码均为 0，610 项测试 0 失败。
- 遗留风险：
  - 阈值按任务书固定为 60% 与 ≥ 2 个链接；两链接且锚文本恰为 60% 的行保留，双链接短行（如「首页 > 通知公告」）靠标点与空格压低占比，站点若改用无分隔符双链接行可能漏过。
  - 未闭合的 `<a>` 会让哨兵失衡，异常行占比可能被高估；正常 CMS 输出不受影响。
  - 修复只作用于未来采集；已落库的导航污染正文不回改。
