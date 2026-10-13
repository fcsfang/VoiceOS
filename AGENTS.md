# VoiceOS 开发原则

**版本**: Lite v1.0  
**日期**: 2026-10-13  
**理念**: 从愿景出发，快速验证核心闭环

---

## 核心信念

### 1. 愿景驱动
- **每一行代码都必须直接服务于用户可见的闭环**
- 参考：`docs/VoiceOS：产品愿景与概念设计文档 v1.1/VoiceOS_产品愿景与概念设计文档_v1.1.md`
- 三个必须跑通的场景：技术访谈闭环、灵感复用、英语练习反馈

### 2. 简单优先
- 能用一个表解决的，不用两个表
- 能用JSON字段的，不建关联表
- 能用SQLite的，不用复杂的ORM
- **目标：3个核心表就够了**（expressions, knowledge, tasks）

### 3. 闭环验证
- 只验证端到端的用户体验
- 测试目标：10个核心测试覆盖完整闭环
- **不追求100%覆盖率，不测试边缘情况**

### 4. 快速迭代
- 先让功能跑起来，再优化
- MVP阶段允许破坏性变更
- 数据丢了就重新录一次（开发阶段）
- **每个功能3天内完成，自己用一周再决定下一步**

---

## 禁止的行为（开发阶段）

- ❌ **不写ADR**：技术决策直接在代码注释中说明，5行以内
- ❌ **不做向后兼容**：MVP阶段schema可以随时重建
- ❌ **不过度测试**：不写单元测试，只写集成测试
- ❌ **不写证据文档**：代码和用户反馈就是证据
- ❌ **不做完美迁移**：没有schema升级脚本，直接重建
- ❌ **不开审查会**：代码即文档，有问题直接改
- ❌ **不建复杂的错误恢复机制**：先确保正常流程跑通
- ❌ **不做性能优化**：除非真的慢到影响使用

---

## 允许的行为

- ✅ **直接在main提交**：不需要PR、不需要review
- ✅ **删除代码**：不确定的代码直接删，需要时再写
- ✅ **重构**：感觉复杂就重构，不需要理由
- ✅ **简化测试**：测试失败？删掉，重写简单的
- ✅ **破坏性变更**：数据格式变了？删库重建
- ✅ **问自己**：这个功能用户真的需要吗？

---

## 开发流程

### 标准迭代周期（10天）

```
Day 1-3:  实现一个场景的最简版本
Day 4-10: 自己真实使用这个场景
Day 11:   收集问题，决定下一步
```

### 当前目标（第一个迭代）

**场景A：技术访谈认知闭环**
1. Mac录音 → 保存音频文件
2. 调用转写API → 得到文本
3. 调用GPT-4 → 提取观点和任务
4. 保存到SQLite（3个表）
5. 显示在简单的UI中
6. 创建Apple提醒事项

**验收标准**：
- [ ] 能录制一次3分钟的技术评论
- [ ] 自动生成1-3条观点
- [ ] 自动创建1个提醒事项
- [ ] 能看到历史记录
- [ ] **3天内完成**

---

## 技术决策

### 架构
- **语言**: Swift（macOS原生）
- **数据库**: SQLite（3个表）
- **转写**: Whisper API或本地Whisper
- **理解**: GPT-4（直接调用，不封装）
- **UI**: SwiftUI（最简单的List和Button）

### 不使用的技术
- ❌ Core Data（太重）
- ❌ 自定义ORM（直接用SQL）
- ❌ 复杂的状态管理（@State就够了）
- ❌ 响应式框架（Combine太复杂）

### 数据库设计（v1）

```sql
-- 表达
CREATE TABLE expressions (
    id TEXT PRIMARY KEY,
    audio_path TEXT NOT NULL,
    transcript TEXT,
    understanding TEXT,  -- GPT返回的JSON
    created_at INTEGER NOT NULL
);

-- 知识
CREATE TABLE knowledge (
    id TEXT PRIMARY KEY,
    expression_id TEXT NOT NULL,
    content TEXT NOT NULL,
    type TEXT NOT NULL,  -- 'claim' | 'question' | 'idea'
    created_at INTEGER NOT NULL,
    FOREIGN KEY(expression_id) REFERENCES expressions(id)
);

-- 任务
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    expression_id TEXT NOT NULL,
    reminders_id TEXT,  -- Apple提醒事项ID
    title TEXT NOT NULL,
    completed INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    FOREIGN KEY(expression_id) REFERENCES expressions(id)
);
```

---

## 与AI协作的规则

### 当Claude Code（你）帮我开发时

1. **默认删除，不默认保留**
   - 看到复杂的代码？删掉重写
   - 看到冗长的测试？删掉
   - 看到无用的文档？删掉

2. **默认简单，不默认完整**
   - 只实现当前需要的功能
   - 不考虑"将来可能需要"
   - 不预留扩展点

3. **默认行动，不默认讨论**
   - 看到问题直接改
   - 不需要问我"是否可以"
   - 改完告诉我改了什么

4. **默认验证，不默认测试**
   - 写完代码运行一次
   - 能跑就行，不写测试
   - 真正需要测试时再写

### 当我说"太复杂了"

- 立即停止当前方向
- 删除刚写的代码
- 用最简单的方式重新实现
- 不要解释为什么之前那样做

### 当我说"继续"

- 不要总结已完成的工作
- 直接进行下一步
- 保持代码简洁

---

## 当前状态

- **分支**: `voiceos-lite`
- **基线**: 从main分支的3016ef9开始
- **目标**: 3天内完成场景A的MVP
- **进度**: Day 1 - 开始清理和重构

---

## 记住

> **VoiceOS的愿景是让人能毫无负担地表达，让思想被忠实理解、长期记住、恰当唤起。**
> 
> **如果代码让开发变得有负担，那就删掉它。**
> **如果测试让迭代变得缓慢，那就简化它。**
> **如果文档没人看，那就不写它。**
> 
> **快速验证核心价值，其他都不重要。**
