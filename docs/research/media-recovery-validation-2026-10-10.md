# 现有音视频保存与进程中断恢复验证

日期：2026-10-10。状态：M0 的文件保存窗口探针完成，产品功能/AC 未实现。最终 run_id：`media-recovery-2026-10-10-v3`。依据用户“继续”及上一轮[现有素材验证](existing-media-validation-2026-10-10.md)，本轮不需要录音。

## 1. 样本与方法

V01 使用此前保留的 26.9 秒 MP4 视频副本，A01 使用此前导出的 60 秒 M4A 音频片段。每个案例在新的私有目录建立测试输入副本、partial/最终资产和最小 SQLite 状态库；所有损坏/删除/改名仅作用于该案例自有副本。

流程：提交接收意图/已知输入长度和摘要 → 分块复制并 flush/fsync → 全量摘要和原生容器/音轨解码核验 → sealed 登记 → 文件 rename/目录 fsync → saved 与一条待处理 stage 同事务提交。SQLite 3.53.4，WAL，synchronous=FULL，外键开启；不是正式产品 schema 或任务引擎，stage 记录不实际执行转写。

子进程在指定检查点等待，父进程对该子进程发 SIGKILL 并确认退出；随后先检查崩溃后的数据库快照，再启动恢复、再次恢复并比较。每份素材 12 个案例，共 24 个最终案例、26 次 SIGKILL（恢复自身中断两个案例各杀两次）。普通进程退出不混作强制终止。

原生验证由 AVURLAsset/AVAssetReader 读取容器并把首个音轨读到 completed；不解码视频画面。本次两份样本各只有一个音轨，完整恢复后原音轨帧数与各自基准一致；V01 的 MP4 原音轨基准为 1,186,217 帧，A01 为 2,646,000 帧。前轮 V01 导出 M4A 的帧数不拿来替代本轮 MP4 基准。

## 2. 最终结果：24/24 符合探针判定

每行分别在 V01/A01 上运行。

| 窗口/故障 | 中断后、恢复前 | 两次恢复后的结果 | 关键核对 |
|---|---|---|---|
| intent：意图已提交，尚无文件 | receiving / 0 job | interrupted-empty / 0 job | 不宣称原件已保存 |
| copy_chunk：只复制首块 | receiving / 0 job | interrupted-unsealed / 0 job | 64 KiB 内容保留，不冒充可用完整录音 |
| copy_complete：全部复制，尚未 sealed | receiving / 0 job | saved / 1 queued job | 已知长度/摘要与原生解码共同核验后自动封存续作 |
| sealed：登记完成，尚未 rename | sealed / 0 job | saved / 1 queued job | partial 核验后落位，字节完全一致 |
| renamed：文件已落位，尚未 saved | sealed / 0 job | saved / 1 queued job | 读最终文件，接续登记不再复制 |
| saved_uncommitted：saved/job 事务未提交 | sealed / 0 job | saved / 1 queued job | 杀进程后两项均回滚，再一起补提交 |
| saved_committed：事务已提交 | saved / 1 job | saved / 同一 job | 已提交状态保留，不重复 stage |
| recovery_renamed：恢复落位后再次中断 | sealed / 0 job | saved / 1 queued job | 恢复本身可重入，第二次从最终文件继续 |
| corrupt：已保存副本被破坏 | saved / 1 job | quarantined / 原 job blocked | 摘要/长度不符，不继续处理 |
| missing：已保存副本被移除 | saved / 1 job | quarantined / 原 job blocked | 缺文件不显示成功，不创建替代来源 |
| invalid_media：无效内容与登记摘要匹配 | sealed / 0 job | quarantined / 0 job | 人工注入错误 sealed 元数据，证明 hash 相等仍不能代替容器解码 |
| input_unavailable：封存后测试导入路径失效 | sealed / 0 job | saved / 1 queued job | 只改名案例输入副本，恢复不依赖该路径 |

汇总：14 个 saved、2 个无文件中断、2 个未完整复制中断、6 个隔离。所有案例的恢复状态/记录数量两次一致，数据库完整性/外键检查通过；有效已恢复文件与基准逐字节一致且原生解码完成。先检查中断后的事务快照，避免恢复修复掩盖半提交问题。

恢复策略在实验中细化：初版保守保留所有未 sealed 内容；随后允许**导入已知完整文件**在全量长度/hash/解码通过后自动续作，并补充恢复前事务快照检查，重新跑完整 24 案例。各开发轮次不累计为更多独立覆盖，以上仅报最终版本。

## 3. 已知完整与未知录制的边界

文件导入可以在复制前记录完整输入的长度/hash，完整副本在 receiving 阶段中断后能独立核验。录制中的最终长度/内容未确定，不能套用这一完成判断；片段存在或能读出前缀不代表全段录制获救。

本轮中断片段仅保留字节，没有修复 MP4/M4A 的截断容器，也不声明这些片段可播放。损坏/缺失后阻断的是探针的待处理记录，未测试已执行动作的撤销。只有两个输入/单音轨，没有并发写入、真实录制、Mac 睡眠、断电/磁盘硬件故障、视频画面、外部同步或语义质量验证。

目录 fsync 在本轮实际完成，但 SIGKILL 不证明断电持久性。最小 SQLite 事务/恢复原型不等于生产 schema、权限/删除屏障或应用 UI；AC-02/13/14 仍 not_run。证据可指导 FI-02/03 的产品导入场景，不能替代 FI-01 录制中断和 FI-04 睡眠/租约测试。

## 4. 证据、复现与下一步

公开[最终证据](evidence/media-recovery-2026-10-10.json)包含检查点、恢复前/后快照、次数、原生元数据和判定；没有原始路径、媒体内容、转写或原件 hash。每个案例的文件/数据库/完整摘要与诊断在 Git 忽略的 `runtime/test-runs/media-recovery-2026-10-10-v3/`。原用户文件及前轮样本 hash 在全部测试后核对未变；无云调用、ASR 重跑、录制或提醒事项操作。

源文件：[恢复驱动](../../scripts/probes/media-recovery-probe.py)、[容器/解码验证](../../scripts/probes/media-container-probe.swift)。按前轮原生工具链编译 validator 后，用如下参数复现；输出必须为新的私有目录，拒绝覆盖：

```sh
python3 scripts/probes/media-recovery-probe.py \
  --fixtures runtime/test-runs/existing-media-2026-10-10/private-manifest.json \
  --validator tmp/research/media-container-probe \
  --output runtime/test-runs/media-recovery-new-run
```

私有 manifest 不在 Git，新环境需先用授权样本生成，不能依赖克隆仓库自动具备个人媒体。本轮支持独立媒体 + SQLite 原子登记的工程路径，ADR-002/003 对生产实现仍 proposed。

下一步建立并核对固定宿主，将验证过的机制转为 **M1 最小文件导入、保存状态与重开查询切片**，保留原生/Core 模块边界。用户暂时不录音不阻碍导入部分推进；麦克风及睡眠仍单列补证据，M1 整体不能提前宣布完成。
