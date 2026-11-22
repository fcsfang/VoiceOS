# 173-A 笔记归属与访谈覆盖（origin/speaker、对方轨、AI 联想标记）

## 来源
审计工作流（9 代理）对照产品文档确认的缺口：
1. `MaterialNoteMember` 丢失 origin/speaker，提示词固定第一人称——外部文章、AI 交付与访谈对方的话被写成「我」。
2. 成员只取 `expression.sourceIDs`，配对的对方/节目轨（`externalVersions`）从不进入生成。
3. 提示词允许模型串联观点，但没有「AI 联想单独标出」的机制。

## 改动
- `MaterialNoteMember` 新增可选 `origin`/`speaker`；端口输入编码携带；提示词 v2：
  - 只有 origin=user 且 speaker=user 用第一人称；访谈对方、外部作者、AI 交付按角色写清，不并入「我」。
  - 段落新增 `inferred` 布尔：模型补充的跨材料/观点关联置 true；阅读界面在段落后以 caption 轻标「整理时补充的关联」。
- 编排：成员集合 = `expression.sourceIDs` + `externalVersions` 的键（排序），与讨论、知识核查的展开口径一致；生成、显示、版本映射共用同一个成员集合。外部成员照常走许可门控（仅本机/未核对会如实阻断）。
- 阅读界面：引文出处显示角色（对方 / 原文作者 / AI 交付），本人材料不显示；`MaterialNote.Paragraph.inferred` 可选字段，旧笔记 JSON 无此键解码为 nil。
- promptVersion → material-note-v2，schemaVersion → note-v2；测试同步（解码保留 inferred、旧 JSON 兼容、身份断言）。

## 验证
- 改动文件 parse 真实退出码全 0；集成构建见 STATUS。
