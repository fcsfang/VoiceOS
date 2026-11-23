# 186 主题按人生维度凝练

来源：用户反馈「主题太分散，能否从人生的几个角度（爱情、职业等）分主题」。可行，且不需要数据库迁移：主题的组织信息本就在 organization_json 里。

## Core
- 新增 TopicDomain（爱情/家庭/职业/金钱/健康/成长/自我/生活）与 TopicDomainInput/Assignment/Candidate；normalized 只接受固定名单。
- TopicOrganizationSummary 增加可选 domain（旧 JSON 解码为 nil）。
- TopicSkeletonTopic 增加可选 domain；骨架与合流 schema 增加 domain 枚举并必填，提示词要求按人生维度选择、合流后重新确认。
- 协议新增 assignTopicDomains（默认返回空，夹具不受影响）与 domainIdentity（topic-domains-v1）；Responses 端口实现批量归类（effort low）。
- applyTopicSkeleton 写入 domain（模型值优先，否则保留旧域）；正文复用判定增加 domain 相等。
- organizeTopics 结尾按 40 个一批补归类缺域主题，只写仍为空的行；失败不阻塞整理。

## App
- 主题页按域分组：固定八域在前、未归类殿后、空域不出现；方向键顺序与视觉一致；详情页眉显示维度。

## 测试 +3 与夹具
旧 summary 无 domain 解码为 nil；normalized 白名单；骨架主题解码 domain。测试夹具把「维度归类」请求（topics 无 viewpoints）与正文请求区分并单独记录，断言归类只补一次、正文仍 3 批。

## 验证
构建 82 首跑因夹具误分类失败（body 3→4）；修夹具后见构建 83。
