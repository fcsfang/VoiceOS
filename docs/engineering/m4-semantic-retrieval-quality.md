# M4 增量：语义候选质量比较

日期：2026-10-11。状态：研究切片完成，产品语义入口未验收。

## 需求与工程判断

产品仍要求跨措辞找回历史，并保留出处、条件、说话人和观点演进。候选相关性与“支持当前观点”“已经证实”“用户同意”分别处理。此轮只评估原文检索，不生成关系或通知。

工程判断：暂不将系统上下文均值池化、BGE 余弦门限或本地重排直接接入自动关联。“本地召回 + 已有文本模型明确判定相关性”值得进入独立样本验证。可靠的连续文字检索继续可用。模型和门限属于可替换技术假设，没有改变产品愿景。

## 样本与结果

[固定样本](../testing/fixtures/retrieval-quality-v1.json)含 24 条合成原文、12 条校准查询和 12 条保留查询；每组 8 条有相关历史、4 条没有相关历史。正例包含跨措辞、否定、条件与兴趣/承诺，干扰主题包括生活、学习、存储、权限、外部说话人等。标注在测试前写入；同一问题的相反观点可相关，但不算支持证据。标注只代表当前人工设计的合成样本，尚未经过独立审查。

系统 NLContextualEmbedding 均值池化此前在大量厨房干扰中得到正例第一名，但扩展主题后 C01“提取训练/容易忘”目标排第 20 名；无关问题的分数与正例重叠。此前结果保留为局部证据，不能泛化成检索质量通过。

| 方法 | 校准精确率 / 召回率 | 保留组精确率 / 召回率 | 无相关历史不返回：校准 / 保留 |
|---|---|---|---|
| BGE-small-zh-v1.5，top3，余弦 ≥0.57 | 5/6 / 5/11 | 4/5 / 4/10 | 4/4 / 4/4 |
| BGE 先取 top8，BGE-reranker-base 重排后 top3，sigmoid ≥0.53 | 6/7 / 6/11 | 5/5 / 5/10 | 4/4 / 4/4 |
| BGE 先取 top8，gpt-6.1-sol 判断最多 3 条或空 | 9/9 / 9/11 | 9/9 / 9/10 | 4/4 / 4/4 |

精确率统计返回记录中相关记录的比例；召回率统计全部标注相关记录的覆盖率。未经门限筛选，两种方法在各组的 8 个正例查询中都能在 top3 找到至少一条相关记录；这与覆盖全部相关记录、避免误回是不同指标。

两种门限仅用校准组选择：在精确率 ≥0.8 且 4 个无相关问题均不返回的约束下，先最大化召回率，再比较精确率和门限。这个规则是探索标准，并非产品验收标准。保留组不参与 BGE 门限选择；但它已经用于系统模型观察，后续调优须重新冻结独立样本，不能把反复查看的样本称为盲测。

余弦方法漏掉录音权限、条件、取消等正例；重排修复了取消和迁移查询的首位，却仍漏掉遗忘练习、音频分权、条件及英语原话等内容。重排校准组仍把“更正原文”与“上下文长度”错误关联。提高精确率伴随明显漏检，两个纯本地方案均不能据此宣称 AC-12 完成。

文本模型使用固定简短提示，要求同一具体问题直接相关，可返回空，不生成关系或任务；不发送标注或分组。C05/C07/H03 未选到标注的次要相关记录，其余正例均找回，取消、条件及同词异义不误回。本轮只有一次批量调用，不宣称独立盲测、关系判定或产品验收完成。

## 运行与成本边界

本地比较仅从 BAAI 官方仓库下载固定提交的 safetensors 和 tokenizer，禁止远端自定义代码。研究环境位于忽略目录 `runtime/retrieval-validation-2026-10-11/venv`；未增加应用运行依赖。下载后向量与重排计算离线，无私人资料上传或外部资料写入。

文本模型比较另按此前授权使用项目本地配置，模型保持 gpt-6.1-sol。仅发送 24 条合成原文及候选查询，输入 2,413 tokens、输出 351 tokens（含 77 reasoning tokens），共 2,764；单次约 12.88 秒。实际费用以已配置服务方账单为准，不按未验证单价估算。请求 `store:false`、严格结构化输出、无工具与重定向、最多 4,096 输出 tokens，先独占保存尝试记录再发送，错误/未知结果不自动重试。请求和输出 ID 都经过限定；它是独立研究脚本，不实现生产授权或数据版本屏障。

向量资产约 96 MB，重排资产约 1.13 GB，合计约 1.23 GB，不含 Python 依赖。当前 24 条短文本的 CPU float32/4 线程，向量模型加载和计算约 0.14 秒；含 top8 重排约 2.41 秒。计时排除下载、Python 启动和模块导入，文件缓存可能已暖，不能视为原生应用延迟或容量保证。离线重复运行得到相同排名、门限和指标；批量模型请求不能推断单次用户查询的响应时间。

完整模型身份、文件摘要、每条 top3、筛选结果和不足见[证据摘要](../research/evidence/semantic-retrieval-2026-10-11.json)。完整矩阵和资产留在忽略的测试目录。93 项应用自动化测试重新通过，0 失败、0 跳过；23 份愿景原始资料摘要一致。应用源码、数据格式和界面未改动，本轮没有新增界面验收。

## 复现

```sh
python3 -m venv runtime/retrieval-quality/venv
runtime/retrieval-quality/venv/bin/python -m pip install torch==2.9.0 transformers==4.57.1 safetensors==0.6.2
runtime/retrieval-quality/venv/bin/python scripts/probes/chinese-retrieval-quality.py docs/testing/fixtures/retrieval-quality-v1.json runtime/retrieval-quality/bge runtime/retrieval-quality/embedding.json --download
runtime/retrieval-quality/venv/bin/python scripts/probes/chinese-retrieval-quality.py docs/testing/fixtures/retrieval-quality-v1.json runtime/retrieval-quality/bge runtime/retrieval-quality/rerank.json --reranker-dir runtime/retrieval-quality/reranker --download
env -u SDKROOT xcrun --sdk macosx swift scripts/probes/contextual-retrieval-matrix.swift docs/testing/fixtures/retrieval-quality-v1.json > runtime/retrieval-quality/contextual.json
```

首次显式 `--download` 只下载模型资产；移除此选项便要求已有模型，校验首次记录的文件摘要，并离线加载。样本必须显式 `synthetic: true`；不打开实际资料库或读取 API 配置。样本超过 token 上限报错，不静默截断。系统探针缺已有中文资产时报告 not_run，不自动下载。

模型判定探针独立运行，默认只预览请求，不读密钥或发送请求：

```sh
python3 scripts/probes/retrieval-relevance-model.py docs/testing/fixtures/retrieval-quality-v1.json runtime/retrieval-quality/embedding.json runtime/retrieval-quality/model-attempt-1.json
```

按授权显式追加 `--send` 才读取本地 `.env` 并发送一次；已存在的 receipt 路径拒绝覆盖或再次调用。不会把标注与分组发给模型。结构化响应格式遵循 [OpenAI Docs](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)，实际已配置服务方兼容性由本次成功回包确认。

同一命令追加 `--evaluate-existing` 可离线核对已有完成回执、候选身份和标注指标，不读取密钥或再次请求。它不能与 `--send` 同用。

## 下一切片

1. 冻结新的独立主题/同词异义/长段落/否定条件样本和标注规则，审查广泛相关与同一具体问题的边界；原样本保留为回归集。
2. 对已初测通过的明确“可无相关候选”的模型判定做独立样本与长文本验证，不按此轮保留组重新调提示。云端研究只使用合成样本；实际仅本地历史继续留在本机，云端判定不能藏在本地端口内。
3. 工程筛选建议：新样本精确率至少 90%、相关记录召回率至少 80%，无相关问题全部不返回，必测遗忘练习与条件案例均找回。属于下一轮工程质量门槛，不替代产品全部验收。未达标继续研究，不开启自动关联。
4. 若质量通过，再验证 100/1000 条不同主题、800 标量片段分词切分、冷启动/取消/内存、模型资源可迁移与原生分发；沿用已有来源/文字/权限版本重验，再接入候选展示与静默反馈。

当前没有需要用户改变产品方向的决策。独立本地模型的包体、依赖和运行成本仍是待验证取舍，未定为产品架构。

若采用混合方案，工程实现顺序是：先建立独立相关性判定端口；只把云端授权候选及主动查询纳入持久请求快照，遵守现有文字预算；发送前/返回后重验来源、文字、权限和查询版本；候选选择只能引用快照中的 ID，不产生派生原文；取消及未知调用结果不得自动重发。仅本地来源继续保留本机候选通路。共享批量合成文档的研究请求不可直接复制到生产发送逻辑。

方法参考：BAAI [官方模型说明](https://huggingface.co/BAAI/bge-small-zh-v1.5)规定短查询可加检索指令、原文不加指令，使用 CLS 表示并归一化；[重排模型](https://huggingface.co/BAAI/bge-reranker-base)对查询/原文成对评分。分数只用于相关性排序，不表示事实可靠性。
