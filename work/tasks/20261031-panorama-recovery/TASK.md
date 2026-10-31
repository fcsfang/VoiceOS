---
status: done
started: 2026-10-31T13:06:21Z
updated: 2026-11-01T01:12+08
branch: main
pr: https://github.com/fcsfang/VoiceOS/pull/46, https://github.com/fcsfang/VoiceOS/pull/53
owner: 主会话
---

# 全景生成管线恢复

## 目标

让全景生成在终止性上游失败下可恢复：对有证据的临时失败自动重试，单单元失败不再中止整次尝试，失败单元下轮可继续。关系综合因此有机会真正运行。

## 范围

- `ResponsesEnvelope` / `ResponsesModelPort` / `ResponsesPanoramaPort`：把 `status=failed` 的上游失败识别为可重试类型，仅全景端口使用，其他端口默认行为不变。
- `ThoughtPanoramaStore`：全景步骤对可重试失败做最多 2 次重试；单元循环改为失败隔离，最后汇总报错。
- 测试：在既有全景流程测试里加入失败隔离与重试场景，不新增测试数量。

## 非目标

- 不改 `configurationIdentity`，已核对单元的步骤回执继续复用。
- 不改 digest 守卫的字段范围（标题变化作废旧运行），这是需要用户确认的设计决策。
- 不拆小超长来源，不做分块生成。

## 当前状态

已完成并合入。恢复能力在生产重试中得到验证：终止性失败自动重试、失败单元隔离后继续、24/25 单元核验。最后一个单元 CE3C1904 受服务端 600 秒流上限阻塞，直连对照相同，另开 #55。

## 下一步

无。剩余的分块生成见 #55。

## 验证

- 新场景先以当前代码失败，修复后通过。
- `swift test -j 4` 全部通过。
- 修复后可在空闲窗口对实时资料库发起一次真实重试，观察进度。

## 链接

- 诊断：17 次尝试 0 次完成；CE3C1904 八次 `unit.generate` 全部失败（上游 `status=failed`）；ED362352 因升序执行与首错中止从未被尝试；`global.*` 从未运行。
