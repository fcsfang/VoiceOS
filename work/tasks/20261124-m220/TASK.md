# 220 测试连接与端口共用同一地址策略

目标：设置页「测试连接」不再绕开端口授权的地址策略，同一地址在测试与保存两条路径上结论一致。

## 改动

- `TextModelHostPolicy`（VoiceOSCore）：HTTPS、`api.openai.com` / `api.chiyi.cc`、精确 `/v1`、无用户信息/端口/查询/片段；`ResponsesModelPort` 与「测试连接」共用。
- `testTextModelConfiguration` 先过策略再发请求：未授权地址不会收到密钥，结果里直接说明允许的地址形态。
- 新增单元测试覆盖九种通过/拒绝形态。

## 验证
- swift build/test 真实退出码（新增 1 个测试，预期 592）。

## 完成情况（2026-11-24）

- 已实现；build_exit=0；swift test 592/592、test_exit=0；dist 重建。