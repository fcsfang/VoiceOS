---
status: planning
started: 2026-11-06
updated: 2026-11-06
branch: -
pr: -
owner: coordinator
---
# 工作区整库刷新的空闲成本

## 现象

知识核查快速路径（#112、#114）合入后，应用空闲时仍以约 100% 一个核的节奏成簇占用 CPU，簇之间只有 0 到 6 秒的空隙。十秒运行样本里知识核查只剩 4 个样本，`ControlCenter.refresh()` 的闭包占 373 个样本，`pread` 168、UTF-8 校验 63。

## 证据

- `/tmp/voiceos-cpu-after-fix.log`：第一次扫描后降到 0，随后反复回到 100%。
- `/tmp/voiceos-sample-10s.txt`：refresh 闭包为主，知识核查只有 4 个样本。
- 实时库知识核查计数未变（12 完成、18 失败、10 冻结），当天 0 次模型调用。

## 假设

`ControlCenter.refresh()` 每次 `reloadWorkspace` 都先调 `panorama.refresh`，而 `panoramaState()` 会构建整份 `PanoramaInput`（全部来源、观点、上下文），随后又读整份 `workspaceSnapshot` 并重发所有发布数组。定时器、通知观察者与处理进度都会触发刷新，`refreshPending` 还可能让刷新连续循环。全景页未显示时也在反复重建全景输入。

## 方向

- 把全景刷新与工作区刷新拆开：只在全景页可见、正在生成或数据确实变化时刷新全景；页面出现时补一次。
- 合并短时间内的重复刷新，避免刷新循环。
- 用样本与刷新计数测量前后差异；不改变数据正确性与界面内容。

## 非目标

- 不改全景语义、工作区数据或界面布局。
- 不新增后台常驻任务。

## 验证

- 实时应用启动后第一次扫描结束，十秒样本不再以 refresh 为主，空闲 CPU 明显下降。
- `swift build -j 4`、`swift test -j 4` 全绿；工作区各页内容与刷新时机不变。

## 链接

`/tmp/voiceos-sample-10s.txt`，`/tmp/voiceos-cpu-after-fix.log`。
