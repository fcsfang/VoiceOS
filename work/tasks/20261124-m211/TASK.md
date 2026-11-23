# 211 板上待办勾选的完成入口修正

自查发现：板上的 todo 勾选调用 completeActionLocally，而该函数要求「已有提醒事项关联」，无关联时直接返回错误——板上大多数待办勾选会失败。

## 改动
- 勾选改为 model.changeAction(action, state: .completed)：有提醒关联时同步并回读，无关联时本地完成；返回 nil（失败）时在笔记顶部显示原因（boardNotice），不再静默失败。

## 验证
parse_exit=0；构建 129 全量。
