# 216 核对流程优化（对标笔记生成）

目标：把「完整转写核对」从一次拘谨的字符串修补，升级成与笔记 v6 同等的能力优先流程；让 10 份待处理材料能顺利核对并整理成笔记。

## 现状问题

1. 模型与强度写死在 Python：`ask()` 固定 `gpt-6.1-sol` + effort high。设置页选的 6.2-sol、笔记/主题强度对核对与整理完全无效。
2. 应用内配置无法驱动 Python：`FullRecordingOrganizer` 只认配置**文件**。设置页保存内部配置后启动不再走文件，`textConfigurationFile` 为空，核对、完整整理、录音收件箱都会报「请配置 Qwen 与文本模型」。
3. 产出形状是「最小替换 edits」：要求 `before` 在片段内逐字出现且只出现一次，失败就整份核对失败并进入最多 2 轮「定位修复」。这类失败与转写质量无关，纯粹是输出协议脆弱。
4. 提示词是围栏式（一堆「不」），与笔记提示词 v6 的能力优先风格不一致。
5. 笔记首页的批量「整理所选」直接走理解/再识别，不先核对转写；10 份材料会逐份失败在门控上。

## 改动

### Python（scripts/organize_podcast.py、organizer_quality.py）
- `settings()` 优先读环境变量 `VOICEOS_TEXT_BASE_URL` / `VOICEOS_TEXT_API_KEY` / `VOICEOS_TEXT_MODEL` / `VOICEOS_TEXT_EFFORT`，退回配置文件；`ask()` 使用该型号与强度，不再写死。密钥只进环境、不落盘、不打印。
- 核对输出改为「按片段校正后的完整文字」：`corrections:[{span_id,text,note}]`，未改片段不列；本地按片段拼接并重算 textStart/textEnd，彻底去掉 before 定位、重叠校验和两轮定位修复。保留一轮格式修复（未知 span_id、空文字）。
- `CONTEXT_REVIEW_VERSION = 4`，写入 `corrections`（截断展示）、`correction_count`、`unresolved_issues`。
- 提示词重写为能力优先：说明这份文字是下游唯一原文、要求逐段读完全文、用领域知识判断同音/专名/术语/断句，保留作者语气与判断，只把确实影响意思的列为疑点。

### Swift
- `TextModelConfiguration` 增加 `reviewEffort`（旧配置缺省 high，兼容解码）；设置页加「核对与整理强度」。
- 新增 `textModelOrganizerEnvironment`：内部配置 + 钥匙串 → 进程环境；文件导入配置也能转成同一环境。`FullRecordingOrganizer` 改为接收环境字典，不再要求配置文件。
- `isCompleteFullTextReview` 接受 `context_review_version 3 或 4`。
- 笔记首页「整理所选」改为：先核对（如需要），再直接生成笔记；逐份进度与结果汇总留在 status。

## 验证
- `python3 -m unittest discover -s scripts/tests`（新增纯函数测试：片段替换、重复/未知 id、用户更正稿保护）。
- swift build/test 真实退出码；隔离副本跑 note-status 与一次核对（若可用）。
- 构建 dist 后空闲时重启，用户在笔记首页选 10 份点「整理所选」。
## 完成情况（2026-11-24）

- Python：settings() 四元组（env > JSON 配置 > .env），ask() 使用设置页型号与强度；review_transcript 改为按片段校正，`CONTEXT_REVIEW_VERSION=4`，只保留一轮格式校验修复；新增 6 个纯函数单测。
- Swift：TextModelConfiguration.reviewEffort（旧数据缺省 high）；设置页「核对与整理思考强度」；FullRecordingOrganizer 改为进程环境传模型配置，内部配置与导入文件统一；isCompleteFullTextReview 接受 v4。
- 笔记首页：待处理显示 12 条；「整理成笔记（N 份）」逐份核对→生成，成功后标记已读，末尾汇总；移除旧的 reidentify 批量函数。
- 自动入口：阻塞原因拆分为具体项；同一文件重试成功后清掉旧失败条目。
- 验证：python3 unittest 6/6 通过、py_compile 0；构建 build_exit=0；swift test 591/591；真实数据核对：20261124 134727 语音备忘录按 v4 完成 11 处修正、2 处疑点并入库。
