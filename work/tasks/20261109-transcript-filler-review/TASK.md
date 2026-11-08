---
status: in_review
started: 2026-11-09
updated: 2026-11-09
branch: codex/transcript-filler-review-20261109
pr: 123
owner: codex
---
# 让 AI 理解前的转写更干净

## 目标

自动清理转写中的填充表达，再把校正稿交给后续理解和任务提取。

## 范围

复用一轮全文校正和原有修订流程。判断依据是口语成分在上下文中的表达作用。

## 改动

全文校正提示词允许删除纯填充且不影响理解的文字。删减仍采用片段内可定位的最小替换。

## 当前状态

提示词已修改，真实模型的合成样本核对通过。

## 下一步

审查改动后随应用更新交付。

## 验证

运行 `organize_podcast.py --review-transcript-only`，真实文本服务删去填充音，保留肯定回应、条件、犹豫和自我修正。核对片段身份、录音时间和文本位置。

## 链接

- [全文校正](../../../scripts/organizer_quality.py)
