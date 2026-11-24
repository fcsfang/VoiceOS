# 218 启动权威与入口启动时序

目标：把启动链里的「静默回退覆盖用户配置」改成单一权威，并让资料库与自动入口不依赖主窗口出现。

## 背景（来自 217 的只读发现）

- 启动链：`VOICEOS_MODEL_CONFIG_FILE` 环境变量优先于内部配置，且迁移路径会把文件内容写回内部配置；内部配置存在但钥匙串读不到时，`restoreInternalTextModelConfiguration` 静默返回 false，随后回退到打包时的 `.env` 并覆盖设置页保存的地址与密钥（`VoiceOSApp.swift` 原 1286-1295、1782-1788）。
- `model.start()` 只由 `WorkspaceView` 的 `.task` 触发：主窗口从未出现或刚出现就被关闭时，资料库、菜单栏口述、自动入口都不会启动。
- 语音备忘录目录的任意读取失败都显示成「隐私权限」，目录被系统重建时用户被引去授权页面；且扫描失败后没有轮询恢复，只有 watcher 创建失败才装轮询。

## 改动

1. 启动链改为内部配置权威：`TextModelConfiguration.load() != nil` 时只走内部配置；恢复失败明确提示「密钥或服务地址不可用，请重新保存」，不回退、不覆盖。仅当内部配置不存在且用户未清除时，才用环境变量 / 历史路径 / 打包 `.env` 做一次性迁移。
2. `start()` 加并发闸门（`starting`）；`ApplicationDelegate.applicationDidFinishLaunching` 里等待 `ControlCenter.primary` 出现后启动资料库，窗口 `.task` 保留为幂等回退。
3. 收件箱目录错误分类：目录不存在 →「请移除入口后重新连接」；Cocoa/POSIX 权限错误 → 隐私授权文案；其他 → 原始错误。任何读取失败都启用 10 秒轮询，目录恢复后自动续上。
4. 重复内容跳过时写入状态行，不再静默。

## 验证
- swift build/test 真实退出码。
- 构建 dist 后空闲重启；重启后确认自动入口与「译文对照」可用。

## 完成情况（2026-11-24）

- 启动链：`TextModelConfiguration.load() != nil` 视为权威，恢复失败明确报告；环境变量与打包 `.env` 只在无内部配置且未清除时做一次性迁移。
- 启动时序：`start()` 增加 `starting` 并发闸门；`applicationDidFinishLaunching` 最多等 10 秒 `ControlCenter.primary` 后启动资料库，窗口 `.task` 保留为幂等回退。
- 收件箱：目录不存在（Cocoa no-such-file）与权限错误（Cocoa no-permission / POSIX EACCES）分别给出修复指引；任何读取失败都启用轮询；重复内容跳过写入状态行。
- 验证：build_exit=0；swift test 591/591、test_exit=0。