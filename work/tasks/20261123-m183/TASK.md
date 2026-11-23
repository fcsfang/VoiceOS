# 183 178–182 评审确认项修复

来源：只读评审工作流（三视角 + 对抗验证，13 候选去重后 5 条全部 CONFIRMED）。

1. 【中】只保存原件重复入库：saveFullRecordingOnly 改用与完整整理相同的幂等键 "full-recording:<path:track:size:mtime>"，重复点击或「先保存后整理」复用同一材料；已存在时直接提示未重复导入。
2. 【中】完成 id 残留：chooseFullRecording 复位时清空 fullRecordingCompletedSourceID，换录音后不再指向上一份。
3. 【中】速记不开窗：QuickNote 保存后先 openMainWindow() 再 requestWorkspaceSource，主窗口关闭的主场景成立；pending 请求由 WorkspaceView onAppear 补消费。
4. 【低】底部处理条：WorkspaceProcessingStatus 新增 dictationSavesOnly，文案与按钮按模型缺失显示「停止后保存原音 / 停止并保存」。
5. 【低】ToggleDictation Intent 超时：2s → 10s，忙时继续等待并按 busy 区分失败文案，不再在录音随后开始时误报失败。

测试 +1：dictationSavesOnly 的标题。
