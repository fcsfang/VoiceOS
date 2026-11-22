# 179 完成即带走：完整整理与自动收件的完成态入口

来源：阶段 2 审计候选 2（整理好后无需去全局行动找刚才的结果；录制完成后回到本次内容）。

## 179-A（本波）
- ControlCenter 新增 fullRecordingCompletedSourceID（最近一次完整整理产出的材料 id）与 openCompletedFullRecording(_:)（收起面板 + requestWorkspaceSource）。
- completeFullOrganization 成功时记录 sourceID；「已完整整理，未重复调用模型」的复用路径同样记录。
- 自动收件（organizeAutomaticRecordings）成功时记录首份 id 并发 LocalNotice（点开直达材料页，177 的窗口重建补消费保障生效）。
- FullRecordingView 完成态：有产出 id 时显示「打开这篇笔记」（主操作），否则保留「查看任务与后续」。
- 新一轮整理开始时清空完成 id。

## 未做（下一单元候选）
- 菜单「记录想法」sheet 与 QuickNote 保存后回到材料（acceptCaptureRequest 目前只回 Bool）。
- 批量导入报告每行「查看」入口（ImportFileResult 无 sourceID）。
- RecordingInbox 完成行内「打开材料」。

## 验证
parse_exit=0；集成构建 70 结果见 STATUS。

## 179-B
- acceptCaptureRequest 改为返回保存的材料 id（@discardableResult String?）；URL/Intent/文字文件包装层改用 `!= nil`。
- QuickNote 保存成功：close() 后 requestWorkspaceSource(id) 回到这次内容。
- 菜单「记录想法」sheet 的 onSaved：关闭后 requestWorkspaceSource(id)。
- 服务/剪贴板路径保持只保存、不抢窗口。

## 179-C
- ImportFileResult 增加 sourceID；importFiles 媒体成功行、拖放文字/PDF/图片行的保存函数改返回 String? 并透传。
- 导入结果报告成功行加「查看」：关闭报告并 requestWorkspaceSource(id)。
- 单文件粘贴无报告，保持原行为；服务路径不变。
