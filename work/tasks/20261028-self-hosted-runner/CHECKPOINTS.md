# 检查点

只追加，不改写旧检查点。

## 2026-10-28T15:41:43Z

- 完成：仓库改为私有；runner v2.338.2 下载、SHA-256 校验、注册为 `voiceos-mac`；LaunchAgent 启动，API 显示 online。
- 证据：`gh api repos/fcsfang/VoiceOS/actions/runners` 显示 `voiceos-mac` online，labels 为 `self-hosted`、`macOS`、`ARM64`、`voiceos-local`；压缩包 SHA-256 校验通过。
- 下一步：推送 workflow 改动，用本 PR 的 CI 验证。
- 阻塞：无。
