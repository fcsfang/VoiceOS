---
status: merge-ready
started: 2026-11-15
updated: 2026-11-15
branch: work/app-intents
owner: coordinator
---

# App Intents 与 Shortcuts 入口

## 目标

把「保存一段文字到 VoiceOS」暴露给系统快捷指令与 Siri。支持方式与原计划不同：SwiftPM 构建的应用没有 Xcode 的 Intent 构建步骤，协调者把「const-values 编译 + appintentsmetadataprocessor」两步复制进 `scripts/app/build.py`，元数据落在 `Contents/Resources/Metadata.appintents`。

## 实现

- `Sources/VoiceOSApp/AppIntents.swift`：自包含（只依赖 AppIntents、AppKit、Foundation），定义 `CaptureTextIntent` 与 `@MainActor protocol VoiceOSIntentEndpoint`；执行时从 `NSApp.delegate` 取端点，经 `ControlCenter.primary` 走既有 `acceptCaptureRequest`，上下文记「快捷指令」。
- `ApplicationDelegate` 实现端点协议，桥接既有抓取路径。
- `scripts/app/build.py`：签名前生成元数据。协议清单用裸名 JSON（`["AppIntent","AppShortcutsProvider","AppEntity","AppEnum"]`），const-values 用 `-const-gather-protocols-file` 与 `-emit-const-values-path` 产出。

## 验证

- 单文件类型检查通过；应用目标 `swift build -j 2` 通过。
- 发行构建后确认 `Contents/Resources/Metadata.appintents/extract.actionsdata` 存在且包含 `CaptureTextIntent`。
- Shortcuts 应用内的动作发现与 Siri 语音调用需要界面与麦克风，锁屏环境下不可得，写明原因。

## 已知边界

- v1 只暴露文字捕获；打开今日行动、开始口述等意图留到下一批。
- 意图在应用未运行时触发 `openAppWhenRun` 会先启动应用，随后写入；应用尚未初始化时返回「尚未就绪」。
- 元数据步骤固定 arm64 与 macOS 26 目标，与当前开发机一致。

## 结果

2026-11-15 提交 `7535729`，随第四批合并。单文件类型检查与目标编译通过；发行包 `extract.actionsdata` 含 `VoiceOSApp.CaptureTextIntent` 与参数定义。Shortcuts 界面发现与 Siri 调用因锁屏不可得。

## 链接

- `docs/product/reference-products.md` 第 9.2 节
