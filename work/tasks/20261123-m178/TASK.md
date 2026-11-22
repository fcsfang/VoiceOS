# 178 阶段 2 差距审计落地（三组）

来源：阶段 2 差距发现工作流（四路只读读者 + 汇总，共 41 条候选，前六名附代码证据）。本波取三条成本最低、影响最大：

## 178-A 阅读位置跨启动持久化
- 现状：MaterialNoteReadingPosition 是进程内字典，首页 help 却承诺「回到上次读到的位置」。
- 改动：改 UserDefaults 持久化（voiceos.note.readingPosition.v1，上限 400 条），条目记录 noteID + anchor；笔记重生成后 id 变化不再沿用旧锚点。调用点传 display.note.id。

## 178-B 搜索索引纳入笔记
- 现状：搜索索引只有旧显示标题与转写；首页显示的笔记标题搜不到。
- 改动：rebuildSearchIndex 额外读取每个表达最新一版 material_notes（标题/导语/小标题/段落），按成员集计算 expressionKey 并入材料条目正文；searchIndexShape 升至 cjk-spaced-v3-notes 强制旧库重建；searchFingerprint 纳入 material_notes（count + max created_at），新笔记保存后下一次搜索自动重建。

## 178-C 文本模型缺失时仍可只保存原音（阶段 2 硬性要求）
- 现状：canToggleCaptureDictation 要求 recordingModelIssue 为空；toggleCaptureDictation 固定 processAfterTranscription:true；菜单/工作区按钮/App Intent 全被拦住，而底层 startDictation(false) 本来就只要求麦克风。
- 改动：canToggleCaptureDictation 只看 initialized/dictationBusy；toggleCaptureDictation 在模型缺失时退化为 processAfterTranscription:false（录完封存原音）；菜单标题区分「开始口述（先保存原音）/停止并保存」；工作区按钮同样放开并改文案；Siri endpoint 去掉模型门控；引导第 1 步补「文本模型未配置时原音也会先保存在本机」。
- 未做（后续）：FullRecordingView 本人/多轨的「只保存原件」入口；模型缺失时导入状态与提示的诚实化（审计候选 6）。

## 验证
parse_exit=0；集成构建 69 结果见 STATUS。
