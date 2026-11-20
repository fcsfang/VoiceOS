# 128 材料标题契约：标题统一、可读、一目了然

## 背景

用户反馈首页材料的标题长短不一、信息密度不同，没有起到「一眼看出这段想法在做什么」的作用。查实原因：`displayTitle` 在缺少 AI 标题时直出正文首行前 48 个字符，口语原文（「所以我我要考虑找一个方法…」）因此成为标题；存量 AI 标题约 17–21 字，48 字回退与之混排。本单元给两类来源各定一条统一规则，并收紧生成提示词。基线 fbea4ab。

## 新契约 `MaterialTitleText`

- `derived(fromTranscript:) -> String?`：正文回退标题。
  - 去换行、压缩空白，去掉开头标点。
  - 句首语气词与口头填充最多剥两轮（我觉得/我想说/然后/就是/反正/其实/所以/那个/这个/嗯/啊/哦/呃），并压缩「我我」式叠字；剥完不足 6 字回到未剥版本。
  - 取第一个分句（两个以上字符后遇 。！？；，、 截断）；整段无标点取前 20 字符。
  - 上限 20 个 Character，超出在 20 字内最后一个停顿处截断补「…」。
  - 空或仅标点返回 nil，调用方保留 48 字兜底。
- `normalizedGenerated(_:) -> String?`：AI 标题收紧，存量与新增共用。
  - 去 markdown 符号（#*`~_>）、去换行、压缩空白、去句末标点。
  - 上限 24 个 Character，超出截断补「…」；空返回 nil。
- 两个函数一律按 `Character` 计数，emoji 与组合字符不撕裂。

## 接入

- `RecordingPresentation.displayTitle`：manualTitle 仅 trim 后原样展示；automatic 标题先过 `normalizedGenerated`，沿用 transcriptVersionID 校验；正文回退先过 `derived`，nil 时保留原 48 字逻辑，纯链接特例不变；audio/video 的「录音 · 日期」顺序不变。
- `VoiceOSStore.generateRecordingTitles`（`RecordingPresentation.swift:226`）：落库前清洗 title，空则跳过该提案。
- `ResponsesRecordingTitlePort` 提示词：标题规格改为通常 10–20 字、最多 24；一句话说清这段想法在做什么或在探讨什么；不复述开场口语，不带句末标点或省略号；不用「关于…」「一些想法」「录音」「总结」这类空泛词。

## 测试

`Tests/VoiceOSCoreTests/MaterialTitleTextChecks.swift` 覆盖：口头填充与叠字开场、分句截断、无标点长文补省略号、恰好 20 字不截、过度剥离开头时回退、AI 标题去 markdown 与句末标点、超过 24 字截断、空串与纯标点返回 nil、manual 标题只 trim 不改写、automatic 与正文两条路径经 displayTitle 生效、grapheme 不撕裂。

## 风险

- 存量 AI 标题超过 24 字的会被截短并补「…」，带句末标点的会去掉标点。
- 正文回退从 48 字缩到 ≤20 字，长标题信息量下降是有意取舍。
- 像「所以，我觉得…」这样开头剥完不足 6 字时，按约定回退到未剥版本，可能只得到「所以」这类短词。
- 只读资料库（`ReadOnlyLibrary.displayTitle`）仍读原始 automatic 标题，未纳入本单元；它不展示正文回退，影响面小于首页。
- 按任务约定未运行 swift build / swift test；改动只涉及 VoiceOSCore 与测试目标，未改 UI。