# 206 模型配置应用内化

用户要求：模型型号与思考强度可在设置页直接更改；所有配置由应用内部统一维护，不依赖外部 .env。

## 实现
- LocalTextModel：模型名不再硬编码（原 18 处 gpt-6.1-sol）；新增 Settings（address/key/model/noteEffort/topicEffort）与 loadSuite(settings:)；文件加载改为 settings(from:) → loadSuite(settings:)；inspect(file) 供导入迁移。.env 可选键 VOICEOS_TEXT_MODEL / VOICEOS_NOTE_EFFORT / VOICEOS_TOPIC_EFFORT 作为开发回退。
- 端口：note 与 topic 端口接收 effort 参数（默认 high），payload 使用配置值；域分类保持 low。
- TextModelConfiguration（Platform，Codable + UserDefaults voiceos.textModel.internal.v1）：baseURL/model/noteEffort/topicEffort，validated() 校验地址；TextModelKeychain 用 Security 存 API Key（service local.voiceos.textmodel），不进 UserDefaults、不打印。
- ControlCenter：configureTextModel(file) 变为导入入口（读取后迁移进内部配置与钥匙串并删除路径依赖）；安装端口抽成 installTextModelSuite；新增 applyTextModelConfiguration（设置页保存：校验→钥匙串→存配置→装端口）；启动优先级：开发 env 文件 > 应用内配置 > 历史文件路径；clearTextModel 同时清内部配置与钥匙串。
- 设置页「应用内模型配置」：地址/模型/密钥（SecureField）/笔记与主题思考强度（minimal…xhigh）；保存并启用；onAppear 回填。抽出 internalModelSettings 属性防类型检查超时。

## 测试 +3
配置编解码与默认值、地址校验、Settings 字段构建。

## 验证
构建 121/122 因 VoiceOSError 缺 import 与钥匙串字典键类型失败；修正后构建 123 验证中（重启闸门等待）。
