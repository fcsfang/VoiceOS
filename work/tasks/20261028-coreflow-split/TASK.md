---
status: done
started: 2026-10-28
updated: 2026-10-28
branch: codex/coreflow-split-20261028
pr: 32
owner: main session
---
# 拆分 CoreFlowTests 提速 CI

## 目标

缩短 Swift 变更的 CI 时间。当前 `CoreFlowTests.swift` 一个文件编译占 11 分 17 秒，总 CI 14 分 40 秒。

## 范围

- 把 `CoreFlowTests.swift` 拆成 fixtures、Core、Recording、Panorama、Followup 五个文件。
- 抽出一个共享的 `FlowTestCase` 基类和 internal fixtures。
- 不改变测试行为、名称或数量。

## 改动

- `FlowTestFixtures.swift` 放共享 fixtures 和基类。
- 四个测试类按功能拆分。
- `PanoramaFlowChecks.swift` 的扩展改指向 `PanoramaFlowTests`。

## 非目标

- 不改断言、测试逻辑或产品代码。
- 不改 CI workflow。

## 决策

- 按功能拆分，让 SwiftPM 并行编译多个小文件。
- 共享 fixtures 改 internal，测试类继承 `FlowTestCase`。
- 用现有 7 个测试作为行为契约，不新增测试。

## 当前状态

PR #32 已合并到 main（70a9608）。托管 runner 的 CI test 用了 11 分 34 秒。

## 下一步

无；CI 提速继续用自托管 runner，见 `work/STATUS.md`。

## 验证

- 本地 `swift test -j 4`：7 项，0 失败。
- 从零构建 284.61 秒，测试 19.66 秒。
- 五个文件的内容范围和原文逐段比对一致。
- PR #32 的 CI test 通过，11 分 34 秒（托管 runner）。

## 链接

- PR: #32（已合并，70a9608）
- 基线: CI test 14 分 40 秒，`CoreFlowTests.swift` 编译 11 分 17 秒。
- 后续: 自托管 runner。
