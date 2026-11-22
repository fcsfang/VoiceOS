# 177 175/176 新代码评审修复

来源：只读评审（git diff 1a0dc6a..a1ce497，逐条核对调用链）。需修四项：

1. 【高】176-B 在「主窗口已关闭、通知唤起重建」的主场景丢失：pendingWorkspaceSourceID 只有 WorkspaceView 的 onChange 一个消费点，视图挂载前写入永远收不到。修复：consumePendingNavigation（onAppear）补消费 pendingWorkspaceSourceID。
2. 【中】175-A 恢复后位置向下漂移：恢复把目标段顶对齐 0，但记录规则是「顶部 96pt 线之上最近的段」，目标段较矮时会立刻把下一段记成位置，每次重开下滑一段。修复：判定基准改为视口顶部（容差 8pt），与 scrollTo(.top) 对齐一致，幂等。
3. 【中】175-B 生成完成没有写首页缓存：生成路径只递增 materialNotesRevision，缓存要等首页读取；生成后第一次返回首页仍跳变。修复：保存成功即写 materialNoteRows[expressionKey]；materialNoteForDisplay 读到最新版也写缓存。
4. 【低】重生成后探针旧锚点残留：段落集合变化后旧 id 残值参与挑选，可能写入不存在的锚点。修复：装载到不同 note id 时清空探针盒与 lastAnchor。

评审另报「缓存合并缺少 rowid tie-break（同秒两版）」为低危潜在项，暂不修（DB 查询有 rowid 决胜，缓存窗口极小）。
