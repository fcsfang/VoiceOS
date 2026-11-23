# 187 启动时自动补齐主题维度

缺口：旧主题只在「主题整理」流程末尾才被归域，而整理不会无故自动重跑——升级后主题页会一直显示「未归类」。

## 改动
- store.backfillTopicDomains(using:) 转为 public（返回写入条数），整理流程内部照旧调用；只写仍为空的行。
- ControlCenter.startTopicDomainBackfillIfNeeded：每个运行期一次，初始化且文本模型就绪时调用；写入 >0 后 refresh 让主题页立即分组。
- 触发点：启动的全量 refresh（scope == .full）与文本模型配置完成后。

## 验证
parse_exit=0；集成构建 84；重启后主题页应出现人生维度分组。
