# 概念与名词表 / Glossary

> 一份 Phase-Contract Workflow 的"词典"。读完任一 README 之后再看本表，可把零散概念钉成一张图。

> "Stability comes from files on disk, not from the model's memory."  
> — Phase-Contract Workflow

---

## 1. 核心模型（Core Model）

| 名词 | 英文 | 在本工作流中的作用 |
| --- | --- | --- |
| 合同链 | Contract Chain | 把一个跨月、跨百小时的长任务建模为 `Phase₀ → Phase₁ → … → Phaseₙ` 的**有序**序列。合同链是整个方法论的基本形状；脱离它谈 planctl / handoff 都是零散工具。 |
| Phase | Phase | 合同链的基本单元。一个 phase = 一次"可独立验收、可独立回滚、产物可落盘"的工作段。phase 数推荐 5–12 个，超 12 要拆层或引入 epic 分组。 |
| 定位合同 | Positioning Contract (`plan/phases/phase-X.md`) | 回答"**这个 phase 是什么**"——目标、范围、完成判定。完成判定必须是客观勾选项，禁止"良好 / 合理 / 基本完成"等主观词。 |
| 执行合同 | Execution Contract (`plan/execution/phase-X.md`) | 回答"**这个 phase 能碰什么**"——允许改动的路径白名单、禁止改动项、交付检查清单、一票否决的裁决规则。它是**围栏而非脚手架**，不写"先做 A 再做 B"。 |
| 双层合同 | Two-Layer Contract | 定位合同 + 执行合同。二者正交：前者管"目标"，后者管"边界"。合并写一份是常见误区，会让边界随目标漂移。 |

## 2. 三不变量（Three Invariants）

Phase-Contract 的"地基"。违反任何一条，长任务都会在 2–3 小时内退化。

| 代号 | 名词 | 含义 | 违反后果 |
| --- | --- | --- | --- |
| **I1** | 单一活跃合同 / Single Active Phase | 任意时刻只有一个 phase 处于"执行中" | 目标漂移、边界越界 |
| **I2** | 三文件上下文律 / Three-File Context Law | 工作窗口恒定为 `common.md + phases/phase-X.md + execution/phase-X.md` 三份 | 注意力稀释、长任务必崩 |
| **I3** | 完成即事实 / Done Means Written | phase 完成必须写入 `state.yaml`，否则不视为完成 | 进度失真、无法恢复 |

## 3. 四类失败模式（Failure Modes）

本工作流要封堵的根本敌人。读到任何设计时都应能对回去："这是在挡哪一种？"

| 失败 | 症状 | Phase-Contract 的封堵手段 |
| --- | --- | --- |
| 进度漂移 / Progress Drift | 记不清做到哪一步，把"打算做"当成"已经做完" | `state.yaml` 原子写回 + `complete` 强制入口 |
| 边界越界 / Scope Creep | 改着改着顺手动了无关模块 | `execution/*` 路径白名单 + `complete` diff 校验 |
| 目标遗忘 / Goal Amnesia | 忘记最初的版本、依赖禁区、质量底线 | `common.md` 永恒硬约束 + 三份 agent 指令强制注入 |
| 压缩失忆 / Compression Amnesia | 上下文被压缩或换会话后隐式状态全部丢失 | `handoff.md` 作为协议 + `resume --strict` 一键恢复 |

## 4. 制品文件（Artifacts）

| 文件 | 角色 | 写入者 |
| --- | --- | --- |
| `plan/manifest.yaml` | 流程清单：phase 顺序、`depends_on`、`required_context` | 人（AI 辅助） |
| `plan/common.md` | 全局硬约束：永恒不变项（版本、依赖禁区、质量底线、非目标） | 人 |
| `plan/phases/phase-X.md` | 定位合同（见 §1） | 人 |
| `plan/execution/phase-X.md` | 执行合同（见 §1） | 人 |
| `plan/workflow.md` | 工作流说明、回退与结束流程 | 人（模板复用） |
| `plan/state.yaml` | **执行账本**：已完成的 phase 列表与时间戳 | **脚本独占**，勿手改 |
| `plan/handoff.md` | **压缩恢复锚点**：下一步做什么、守什么约束 | **脚本独占**，勿手改 |

## 5. 强制层（Enforcement Layer）

三份字节同步的 agent 指令，在每个会话开场被自动注入，把规约从"建议"变成"前置条件"：

| 文件 | 目标 agent |
| --- | --- |
| `.github/copilot-instructions.md` | GitHub Copilot |
| `CLAUDE.md` | Claude Code |
| `AGENTS.md` | Codex / 通用 `AGENTS.md` 协议的 agent |

**三份必须字节一致**。任何"仅 Claude 看"、"仅 Copilot 看"的差异都会让 `planctl doctor` 的 SHA256 比对报错，也会在切换 agent 时产生隐性漂移。差异化诉求改写进 `plan/common.md` 的"按 agent 区分"小节。

## 6. 调度器（Scheduler：`scripts/planctl`）

单文件 Ruby 脚本，是整个工作流的**唯一流程入口**。AI 不允许绕过它自行判断进度。

| 命令 | 作用 |
| --- | --- |
| `planctl next --strict` | 计算下一个应执行的 phase，返回 `required_context`；`--strict` 阻断未满足依赖的跳步 |
| `planctl resume --strict` | 压缩后冷启动一键恢复：项目概览 + handoff 快照 + 下一 phase resolve 结果 |
| `planctl complete <id>` | 完成入口：原子写回 `state.yaml` + 刷新 `handoff.md` + `git add/commit/push` 里程碑 |
| `planctl revert <id>` | 回退某个 phase：默认 `git revert` 保留历史；下游依赖未回退时拒绝执行 |
| `planctl doctor` | 仓库体检：SHA256 比对三份 agent 指令、校验 manifest/state/handoff 引用一致性 |
| `planctl status` | 查看当前进度 |
| `planctl handoff --write` | **手动补救**通道（正常循环不用）：重放 handoff 刷新 |

## 7. Golden Loop（黄金环路）

每个 phase 走同一条五步环路。中断点随时可压缩或换会话，下轮从起点重入即**无损续跑**。

```text
next --strict  →  读 3 份上下文  →  实施（守 execution 边界）
                                            ↓
                     ← handoff (脚本自动)  ←  complete <id>
```

## 8. 三阶段恢复协议（Recovery Protocol）

压缩或新会话冷启动的**唯一合法路径**。AI 不得"凭记忆"继续。

```text
1. 读 plan/manifest.yaml   —— 拿到全局地图
2. 读 plan/handoff.md      —— 拿到上次留下的锚点
3. 跑 planctl next --strict —— 拿到下一步要做什么与 required_context
```

一条命令版：`ruby scripts/planctl resume --strict`。

## 9. 关键设计原则（Design Principles，八原则摘要）

| # | 原则 | 一句话 |
| --- | --- | --- |
| P1 | 状态外部化 | 进度写文件，不写记忆 |
| P2 | 调度与执行分离 | 脚本决定做什么，AI 决定怎么做 |
| P3 | 三文件上下文律 | 工作窗口恒为 common + phase + execution |
| P4 | 双层合同 | 目标与边界正交，不合并 |
| P5 | 依赖强制校验 | `depends_on` + `--strict` 阻断跳步 |
| P6 | 完成即写入 | `complete` 是唯一写回入口 |
| P7 | 固定恢复协议 | 压缩后永远三步：manifest → handoff → next |
| P8 | 里程碑外部化 | `complete` 自动 commit + push；有 remote 时同步到远端，无 remote 时保留本地可回滚记录 |

完整论述：[references/methodology.md](./methodology.md)。

## 10. 相邻概念对比（Adjacent Concepts）

下列术语常被混用，务必区分清楚，避免误用。

| 概念 | 本质 | 与 Phase-Contract 的关系 |
| --- | --- | --- |
| **ReAct** | 动态 `Thought → Action → Observation` 循环；走一步看一步 | **互斥的使用场景**：ReAct 用于探索型任务（路径未知），Phase-Contract 用于工程型任务（路径已知、可预切 phase） |
| **Agent Framework** (LangChain / AutoGPT / crewAI) | 运行时编排工具调用与多 agent 协作 | 正交层。Phase-Contract 不提供工具调用能力，只提供"让同一个 agent 长跑"的基础设施；可以嵌在任意 framework 里 |
| **Plan.md / TODO.md** | 一份静态的自然语言计划 | 被 Phase-Contract 取代的"前一代"。它把"进度判断"留给 AI 记忆，2–3 小时必崩 |
| **Prompt Engineering** | 优化单次提示词 | 正交层。Phase-Contract 不依赖更聪明的提示词，依赖磁盘约束 |
| **MCP / Tool Use** | 标准化的模型-工具接口协议 | 正交层。`planctl` 是"工具"的一种实现，可通过 MCP 暴露，但工作流的稳定性与 MCP 本身无关 |
| **Context Engineering** | 泛指管理 LLM 上下文窗口的工程实践 | Phase-Contract 是 context engineering 的一个**具体、强约束**实例：把上下文固定为三份文档 |

## 11. 评估口径（Evaluation Vocabulary）

阅读 README 与方法论时可能遇到的量化词：

| 术语 | 含义 |
| --- | --- |
| **5h+ 连续工作** | 单个 agent 在不依赖人工干预、允许跨压缩与跨会话的前提下，持续推进合同链 5 小时以上 |
| **12h 自治**（Roadmap 目标） | 进一步叠加"完成判定机器可验收 + 失败自动回滚 + meta-phase 重规划"后的长程目标 |
| **无损续跑** | 压缩或换会话后，下一轮通过恢复协议即可完全恢复工作状态，不丢失任何已完成进度与已决定的边界 |
| **phase 级回滚** | 只撤销某个 phase 的代码 + state + handoff，不影响已完成的其他 phase；默认用 `git revert` 保留历史 |

---

<div align="center">

回到 [中文 README](../README.zh-CN.md) · [English README](../README.md)

</div>
