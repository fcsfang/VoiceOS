# 166 删除全景特性（用户产品取舍：效果差、已不使用）

## 背景与决定
用户明确：「全景图效果非常差，其实我已经用不到了……要么就直接删掉这个功能」。决定：**完整删除 Panorama 特性**（UI、屏幕模型、生成流程、提示词/端口、存储扩展、专用测试），**保留**与其相邻但独立的基础设施：`model_attempts`/`contexts`/`claims`（理解与观点管线共用）、数据库表结构（不写迁移、不 DROP 表，老库继续可打开）、认知地图（Reflection）与其余一切功能。

## 删除文件（整个文件删除）
- Sources/VoiceOSCore/：PanoramaModelInput.swift、ThoughtPanoramaStore.swift、PanoramaThemeReply.swift、ResponsesPanoramaStages.swift、PanoramaWorkflow.swift、ResponsesPanoramaPort.swift、PanoramaRefreshPolicy.swift、ThoughtPanorama.swift、PanoramaSlicing.swift、PanoramaThemeIdentity.swift
- Sources/VoiceOSApp/：PanoramaScreenModel.swift、PanoramaConstellation.swift、ThoughtPanoramaView.swift
- Tests/VoiceOSCoreTests/：PanoramaThemeIdentityChecks.swift、PanoramaValidationRetryChecks.swift、PanoramaFlowChecks.swift、PanoramaRefreshPolicyChecks.swift

## 宿主文件清理（保留其余功能）
1. **WorkspaceView.swift**：删除 `homeShowsPanorama` 及其全部使用（首页「最近/全景」Picker、PanoramaHome 分支与 `model.panorama` 访问、`setPanoramaVisible` 的 task/onChange/onDisappear、`openPanoramaDiscussion`、`homeCanDiscuss` 中全景分支、讨论路由中的全景分支、`panoramaTopicLinks`、`panoramaSourceEditor`/`panoramaClaimEditor` sheets 与相关 state）。首页只保留「最近」内容，删除视图切换控件。
2. **VoiceOSApp.swift**：删除 `panorama` 屏幕模型、`panoramaPolicy`、`panoramaModel`、`retryPanorama`/`generateDraftPanorama`/`themeReply`/`beginPanoramaDiscussion`/`setPanoramaVisible`/`refreshPanorama` 及全部调用点（含菜单项、通知、启动任务、60s 刷新策略中的全景触发）。不删除 model_attempts/contexts 相关代码。
3. **WorkspaceProcessingView.swift**：删除「全景生成未完成」区块（含可见性条件与动作），其余区块不动。
4. **Sources/VoiceOSPlatform/LocalTextModel.swift**（或引用 ResponsesPanoramaPort 的位置）：删除全景端口实现/扩展，保留其余端口。
5. **Sources/VoiceOSCore/Store.swift 与 PortablePackage.swift**：仅移除对已删除类型的引用；**数据库 DDL 与表清单保持原样**（panorama_* 表可留作休眠数据）；若 PortablePackage 校验/导出清单列举 panorama 表，改为忽略（老包仍可恢复，未知表跳过），不得破坏包格式兼容。
6. **Tests/VoiceOSCoreTests/CoreFlowTests.swift、PackageRoundTripChecks.swift**：删除/改写其中涉及 Panorama 的测试方法与断言，其余测试保持。

## 验证要求
- 删除后全仓 grep 以下符号应为 0 引用（除数据库表名字符串可保留）：`Panorama`、`panorama`（区分：`model_attempts`/`contexts` 相关不算）、`全景`（用户可见文案中应无）。
- 对每个被编辑的宿主文件运行 `xcrun --sdk macosx swiftc -parse`，真实退出码 0；不跑 swift build/test（集成构建由调度方执行）。
- 完成后 git add -A + commit（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：删除文件清单、每处宿主清理摘要、保留项说明（DB 表/共用基建/包兼容策略）、残留 grep 结果、parse 退出码、diff --stat。