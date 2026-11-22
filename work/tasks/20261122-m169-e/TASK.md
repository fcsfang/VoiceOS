# 169-E 修复讨论上下文摘要校验阻断资料库打开

## 症状
构建 49 起应用启动报「资料库尚未打开：讨论上下文摘要或预算不一致」，重试仍失败；隔离副本上 `voiceos-check read <copy>` 同样 exit 1。

## 根因
`validateStoredConversations` 的摘要守卫把已存 `snapshot_json` 解码再编码后与写入时摘要比对。169-B 死代码减法删除了 `TranscriptionReview.Correction.independent_reason`（当时已注明「重新编码会丢弃该键」），导致 271 条含该键的讨论上下文快照重编码字节变化、摘要失配。校验与数据本身没有不一致，是 Codable 往返不再保真。

## 修复
恢复 `Correction.independent_reason: String?` 为兼容字段并加注释说明约束（删除会再次破坏已有快照的摘要校验）。校验逻辑、存储与既有数据零改动。

## 验证
- 修复前：隔离副本 `voiceos-check read` exit=1，stderr「讨论上下文摘要或预算不一致」。
- 修复后：同副本 `voiceos-check read` exit=0，integrity=true。
- 集成构建见波 169 记录。
