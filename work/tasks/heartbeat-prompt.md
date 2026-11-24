# VoiceOS 自主循环心跳（暂停中，待用户开启）

2026-11-24 用户要求暂停定时唤醒自迭代。原 cron 为每小时的 :17 触发（session-only），已删除；下面是原始唤醒 prompt，用户说开启时用 CronCreate 原样恢复（cron `17 * * * *`，recurring，非 durable）。

```text
[VoiceOS 自主循环心跳] 这是定时唤醒。工作目录 /Users/joey/01 Projects/VoiceOS。先看 work/STATUS.md 尾部与 work/tasks/ 最新的 TASK.md 掌握当前波次，然后继续自主循环。

约束（硬性）：
- 16GB 内存，任何时刻只跑一个 swift build/test。
- 绝不写实时库 ~/Library/Application Support/VoiceOS，只在隔离副本验证。
- 推送用 SSH remote git@github.com:fcsfang/VoiceOS.git（HTTPS 常超时）。
- 应用只在空闲时重启：先跑 scripts/app/restart_preflight.sh 并检查其真实退出码（不要经管道），0 才 pkill + open dist/VoiceOS.app。
- 每波记录写进 work/tasks/<日期>-<波名>/TASK.md 并提交；构建与测试只认真实退出码。
- 效率策略：小修、文档与状态记录直推 main，不开 PR；实质波次在独立工作树实现后 `git merge --no-ff` 进本地 main，跑一轮集成构建+测试后推 main，波次边界由 merge 提交保留。基础的日志、状态记录（TASK.md、STATUS.md）任何情况下不删。

循环是发现→决策→修复→再发现，并行推进是关键：若有后台单元在跑，推进等待中的集成或立即准备下一波任务书；若上一波已合并交付，立即用 2-4 个只读发现者开下一波，取影响最大、成本最小的一组点并行实现（不同文件的波次可以同时跑），一次构建与全量测试，隔离副本验证，合并推 main，重建 dist 并重启应用。任何时刻不要停在无事可做的状态，总有下一个可优化的点。用户当前在跟进 UI 反馈时优先响应用户。
```