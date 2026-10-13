# VoiceOS Lite 清理计划

## 原则
**保留有价值的核心代码，删除过度工程的部分**

---

## 第一阶段：删除冗余文档（立即执行）

### 删除
- `docs/adr/` - 45个ADR文档
- `docs/research/evidence/` - 证据文档
- `docs/testing/` - 测试计划和审查
- `docs/planning/overnight-*` - 夜间自动化相关
- `docs/agents/` - Agent配置
- `docs/engineering/development-guide.md` - 过时的开发指南
- `.agents/` - Agent任务目录

### 保留
- `docs/VoiceOS：产品愿景与概念设计文档 v1.1/` - 核心愿景
- `docs/README.md` - 简化后作为项目概览
- `AGENTS.md` - 新的开发原则
- `ROADMAP.md` - 路线图

---

## 第二阶段：简化测试（立即执行）

### 当前状态
- 583个测试
- 覆盖各种边缘情况
- 每次运行26秒

### 目标
- 10个核心测试
- 只测完整闭环
- 5秒内完成

### 保留的测试
1. 录音 → 转写 → 理解 → 保存 → 查询（完整闭环）
2. 创建任务 → 同步到提醒事项
3. 数据库基本操作

### 删除
- 所有单元测试
- 边缘情况测试
- 迁移测试
- 冻结/补偿测试

---

## 第三阶段：重构数据库（谨慎执行）

### 当前状态
- 26个表
- schema38
- 复杂的validity/frozen/migration机制

### 目标
- 3个核心表：expressions, knowledge, tasks
- 简单的JSON存储（不拆分太细）
- 删除迁移脚本

### 保留的核心表
```sql
-- 只保留最核心的字段
CREATE TABLE expressions (
    id TEXT PRIMARY KEY,
    audio_path TEXT,
    transcript TEXT,
    understanding TEXT,  -- JSON
    created_at INTEGER
);

CREATE TABLE knowledge (
    id TEXT PRIMARY KEY,
    expression_id TEXT,
    content TEXT,
    type TEXT,
    created_at INTEGER
);

CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    expression_id TEXT,
    title TEXT,
    reminders_id TEXT,
    completed INTEGER,
    created_at INTEGER
);
```

---

## 第四阶段：简化代码（逐步执行）

### 删除的模块
- 复杂的版本管理
- 冻结/补偿机制
- 完整的迁移系统
- 过度的错误恢复

### 保留的核心模块
- Recording（录音）
- Transcription（转写）
- Understanding（理解）
- Storage（存储）
- Reminders（提醒事项）

---

## 执行顺序

1. ✅ 建立新原则（AGENTS.md）
2. ✅ 创建路线图（ROADMAP.md）
3. ⏳ 删除文档（不可逆，但可以从main恢复）
4. ⏳ 删除测试（不可逆，但可以从main恢复）
5. ⏳ 创建新的简化数据库schema
6. ⏳ 重构核心代码
7. ⏳ 实现MVP
8. ⏳ 测试验证

---

## 风险控制

- main分支保留完整历史
- 可以随时从main恢复任何文件
- voiceos-lite是实验分支
- 如果失败，可以重新开始

