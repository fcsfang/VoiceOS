# 145-C 动效与文案小尾（WeeklyReviewView / VoiceOSApp）

## 背景
144 波遗留两条：周回顾摘要跳转滚动用的是手写 0.2 easeInOut，不在 144-D 的替换范围；VoiceOSApp 一处拉丁词紧贴中文（「AI关系提案」）。两条都小，但都属本轮统一目标。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/WeeklyReviewView.swift
- Sources/VoiceOSApp/VoiceOSApp.swift

## 逐条

### 1. 周回顾摘要跳转
- WeeklyReviewView.swift 约 208 行：摘要 chip 的 `withAnimation(... .easeInOut(duration: 0.2)) { proxy.scrollTo(...) }` 改为 `withAnimation(reduceMotion ? nil : WorkspaceMotion.scroll) { ... }`（reduceMotion 环境值文件内已有）。

### 2. VoiceOSApp 中英间距
- VoiceOSApp.swift 约 4915 行：「AI关系提案」→「AI 关系提案」（仅补空格）。用 grep 复核同文件其它拉丁词紧贴中文的用户可见字符串，一并补空格（不改措辞、不改标识符/键名/文件名）。

## 约束
- 不改业务逻辑；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、逐条完成情况、parse 退出码、diff --stat。