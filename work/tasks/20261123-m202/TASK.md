# 202 启发层实现（material-note-v4 + AI 批注 UI）

依据：docs/product/启发层设计（AI批注）.md（f53e3ff 全面审计版），用户已确认开工。

## 数据与提示词
- MaterialNote 增加 Annotation（id/kind/text/quote?/title?/startsFrom?/voice?/source?/confidence?）；Paragraph 增加 annotations；Note 增加 closing。全部可选、旧笔记兼容。
- ResponsesMaterialNotePort 升 v4：promptVersion material-note-v4、schemaVersion note-v3、outputTokens 32768；instructions 采用设计文档全文（能力优先、角色自选、无上限、发散、诚实底线）；schema 增加批注对象（段落 annotations 必填数组、根 closing 必填数组），解码生成稳定 id（sXpYaZ / closingN）。
- MaterialNoteAnchoring：保留批注与文末长文；批注的 quote 只作定位，定位不到时只清引文、批注本体保留。

## 界面
- MaterialNoteReadingView：段落后就地显示批注（低饱和暖色底、左缘色条、「AI 批注 · 类型 · voice」小标、有出处时显示来源行、超长自然换行）；文末「再看一眼」区列 closing；笔记操作菜单增加「隐藏/显示 AI 批注」（AppStorage 持久化，默认显示）。
- 笔记页与材料页共用该视图，两者同时获得批注层。

## 测试 +3
旧 JSON 无批注字段解码为 nil；新 JSON 解码保留 kind/voice/source/closing；锚定清掉无法定位的批注引文但保留批注本体。

## 验证
parse_exit=0；集成构建 107（预期 583 tests）；随后「重新整理笔记」用 v4 生成黑雾并验收。
