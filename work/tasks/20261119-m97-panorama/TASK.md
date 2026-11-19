# 波 97 任务 C：全景页空态按状态说话

## 用户诉求

全景页空态此前只按 snapshot 是否存在分支。刚切到全景（state nil / pending）、核对失败（failed / unknown；真实库 23 次尝试中 18 次 failed、5 次 unknown、0 completed）与「真的没有问题」共用同一句发现标题「从表达中发现持续探索的问题」，与材料页此前「未加载显示为空」是同构误导。

## 分支与基线

- 分支：`work/m97-panorama`，工作树 `.worktrees/m97-panorama`，基于 main `1791ddc`。
- `git merge main --no-edit`：`merge_exit=0`（已经是最新的）。

## 改动

只改 `Sources/VoiceOSApp/ThoughtPanoramaView.swift` 的空态区段。数据流、标识、键盘、工具栏状态句与按钮逻辑均未动；未碰 `PanoramaScreenModel.swift`。

- `Sources/VoiceOSApp/ThoughtPanoramaView.swift:615-636`：新增私有 `PanoramaEmptyMode`（loading / needsModel / unverified / needsMaterials / settled），标题与重试按钮文案收在枚举内。
- `Sources/VoiceOSApp/ThoughtPanoramaView.swift:640-647`：`emptyMode` 由 `state` 派生。优先级：无 state → loading；有快照 → settled；failed/unknown 且无快照 → unverified（携带 `state.error`）；`input.units` 为空 → needsMaterials；有单元但未配置模型且未在生成 → needsModel；其余 → loading。
- `Sources/VoiceOSApp/ThoughtPanoramaView.swift:649-667`：空态渲染。loading 显示 `ProgressView`；unverified 副标题直接显示错误原文（无原文回退 toolbarMessage），help 仍保留 `PanoramaFailureAdvice`；重试按钮在 unverified 文案为「继续核对」，其余保持「生成或重试全景」与原禁用条件。
- `Sources/VoiceOSApp/ThoughtPanoramaView.swift:669-672`：`emptyDetail` 选择副标题文本。

状态与文案：

| 状态 | 标题 | 副标题 | 按钮 |
|---|---|---|---|
| state 为 nil / pending / running | 正在载入全景 + ProgressView | toolbarMessage | 打开材料；生成或重试全景（原禁用条件） |
| failed / unknown 且无快照 | 全景尚未通过核对 | `state.error` 原文 | 打开材料；继续核对 |
| units 为空 | 先整理材料，形成完整单元 | toolbarMessage（既有整理引导） | 打开材料 |
| 有单元、未配置模型、未生成 | 选择文本模型后生成全景 | toolbarMessage（提示先选模型） | 打开材料；生成或重试全景（禁用） |
| snapshot 存在且问题为空 | 材料已核对，尚未形成持续问题 | toolbarMessage | 打开材料 |

「从表达中发现持续探索的问题」已从本文件移除；仅 settled 分支保留原有的已核对空结果文案。

## 真实验证

共享锁 `/tmp/voiceos-swift-build.lock` 全程持有，结束释放。

- `swift build -j 2` → `build_exit=0`（`Build complete! (127.34s)`）
- `swift test -j 2` → `test_exit=0`；`Executed 645 tests, with 0 failures (0 unexpected) in 48.876 (48.940) seconds`。基线 645 项 0 失败不变，未新增测试。

## 遗留风险与取舍

1. 新增 needsModel 分支。pending 且文本模型未配置是真实可达状态（`PanoramaScreenModel.refresh` 只在有 port 时启动生成），按任务字面显示「正在载入全景」会变成永动加载指示；这里改为「选择文本模型后生成全景」，动作入口仍在工具栏「连接文本模型」。
2. 原 isGenerating 文案「让完整表达连成脉络」并入 loading；pending / running / 生成中的空态统一为加载指示。
3. 部分快照（`isPartial`）且问题为空时仍显示「材料已核对，尚未形成持续问题」，属既有行为；本波只按诉求处理无快照失败态，未扩大范围。
4. 视图层文案改动不被 645 项测试覆盖；受波约束未重启应用、未读实时库，实机文案未目视确认。
5. 工具栏状态句与空态副标题存在信息重叠（均来自 `toolbarMessage`），按任务要求保持现状，不改逻辑。