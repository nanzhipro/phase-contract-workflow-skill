<div align="center">

<img src="./assets/phase-contract-logo.svg" alt="Phase-Contract Workflow" width="720">

# Phase-Contract Workflow

**让 AI agent 连续工作 5 小时以上，跨上下文压缩、跨会话、跨 agent 无损续跑。**

把长任务建模为**有序合同链**——进度、依赖、边界全部落盘；稳定性来自仓库里的文件与脚本，而不是模型记忆。

> _"把 AI 的稳定性从模型记忆迁移到仓库文件系统。"_

[![install](https://img.shields.io/badge/install-npx%20skills%20add-informational?logo=npm)](https://www.npmjs.com/package/skills)
[![Copilot](https://img.shields.io/badge/GitHub%20Copilot-supported-24292e?logo=github)](./references/agent-instructions-template.md)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-supported-d97757)](./references/agent-instructions-template.md)
[![Codex](https://img.shields.io/badge/Codex-supported-10a37f)](./references/agent-instructions-template.md)

**中文** · [English](./README.en.md)

</div>

---

## Why

AI 连续工作 3 小时以上会稳定出现四类失败：**进度漂移、边界越界、目标遗忘、压缩失忆**。写一份越长越详细的 `Plan.md` 让 AI 自己判断，到 2–3 小时必崩。本项目用**机制**而非**自觉**封堵这四类失败。

## Core idea

一句话：**把 AI 的稳定性从"模型记忆"迁移到"仓库文件系统"。** AI 只在小窗口里完成小合同，跨小时、跨会话、跨 agent 的连续性由磁盘上的脚本与文件承载。

四条底层主张：

- **长任务 = 有序合同链**。把工期以月计的项目拆成一串 `Phase₀ → Phase₁ → … → Phaseₙ`；每个 phase 由「定位合同（是什么）」和「执行合同（能碰什么）」双文档定义，目标与边界正交。
- **三不变量不可破**。**I1** 任意时刻只有一个活跃 phase；**I2** 工作窗口恒定为 `common + phase + execution` 三份文档；**I3** 完成必须落盘到 `state.yaml`，否则不视为完成。违反任一条，长任务必崩。
- **机制 > 自觉**。进度由脚本原子写回，边界由路径白名单 diff 校验，依赖由 `--strict` 阻断跳步，压缩恢复由 `handoff.md` 充当协议——所有稳定性都来自外部强制，而不是提示词恳求。
- **调度与执行分离**。`planctl` 脚本决定"下一步做什么"，AI 只决定"怎么做"。这是把同一段 AI 能力在 5 小时后仍然可用的唯一已知办法。

推论：这不是一个"更聪明的 Prompt"，也不是一个 agent framework，而是一套**让普通 AI 在磁盘约束下表现得像长程工程师**的最小基础设施。

## How it works

三层设计，各层职责正交：

| 层 | 作用 | 写入者 |
| --- | --- | --- |
| **Enforcement**<br>`.github/copilot-instructions.md` · `CLAUDE.md` · `AGENTS.md` | 把规约从"建议"变成会话级前置条件 | 人（三份字节同步） |
| **Scheduler**<br>`scripts/planctl` | 决定下一步做什么、校验依赖、原子写回账本 | 复用本仓库脚本 |
| **Contracts**<br>`plan/manifest.yaml` · `plan/common.md` · `plan/phases/*` · `plan/execution/*` | 定义"做什么 (phase)"和"能碰什么 (execution)" | 人（AI 辅助） |

执行态由脚本独占维护的两份文件承载：

- `plan/state.yaml` — 客观进度账本（`complete` 原子写入）
- `plan/handoff.md` — 压缩恢复锚点（`complete` 自动刷新）

## Install & update

推荐用 [`skills`](https://www.npmjs.com/package/skills) CLI 把本仓库作为 Agent Skill 安装到 Copilot / Claude Code / Codex 的 skills 目录，一条命令完成拉取、注册与后续升级。

```bash
# 安装（自动识别当前 agent 的默认 skills 目录）
npx skills add nanzhipro/phase-contract-workflow-skill

# 显式指定目标 agent
npx skills add github:nanzhipro/phase-contract-workflow-skill --agent claude
npx skills add github:nanzhipro/phase-contract-workflow-skill --agent copilot
npx skills add github:nanzhipro/phase-contract-workflow-skill --agent codex

# 升级到最新 main
npx skills update phase-contract-workflow-skill

# 重装（覆盖本地修改，请先备份）
npx skills add nanzhipro/phase-contract-workflow-skill --force

# 卸载
npx skills remove phase-contract-workflow-skill
```

安装后在对应 agent 会话里直接说「用 Phase-Contract 规划 XXX 项目」即可触发；skill 的发现描述见 [SKILL.md](./SKILL.md) 的 frontmatter。

## Golden Loop

每个 phase 走同一条环路；中断点随时可以压缩或换会话，下轮从起点重入即可无损续跑：

```text
next --strict  →  读 3 份上下文  →  实施（守 execution 边界）
                                             ↓
                       ← handoff (脚本自动)  ←  complete <id>
```

一条命令即可启动或恢复：

```bash
ruby scripts/planctl next --format prompt --strict     # 新会话 / 日常推进
ruby scripts/planctl resume --strict                   # 压缩后冷启动
ruby scripts/planctl complete <id> --summary "..." --next-focus "..."
ruby scripts/planctl doctor                            # 仓库体检（三份指令 SHA256 比对等）
```

## Design principles

- **状态外部化**：进度写文件，不写记忆。
- **调度与执行分离**：脚本决定做什么，AI 决定怎么做。
- **三文件上下文律**：工作窗口恒定为 `common + phase + execution` 三份。
- **双层合同**：`phases/*` 说"是什么"，`execution/*` 说"能碰什么"——目标与边界正交。
- **完成即事实**：未进 `state.yaml` 的 phase 不视为完成，不管 AI 自述多么漂亮。
- **恢复是一等公民**：`handoff.md` 不是备忘录，是协议。

完整的八原则、三不变量、失败模型与封堵映射，参见 [references/methodology.md](./references/methodology.md)。

## When to use

**适用**：大型从 0 到 1 产品、框架/SDK 迁移、大版本升级、架构替换、长文档工程、合规整改、长链路 ETL 重建。

**不适用**：单次小修复（太重）；探索型研究（没有可预定义 phase，应走 ReAct 一类方法）；需求高度不稳、phase 会反复改写的阶段（先等需求稳定）。

## Prerequisites

- 目标仓库是 git 工作区（`git rev-parse --is-inside-work-tree` 为 `true`）。非 git 目录下无法做 phase 级白名单比对与回滚，默认禁止，仅允许显式 opt-out：`PHASE_CONTRACT_ALLOW_NON_GIT=1`。
- 本地有 `ruby`，版本 ≥ 2.6。planctl 是单文件脚本，不依赖任何 gem。

## Quick start

当作 Agent Skill 使用时，在 Copilot / Claude Code / Codex 里直接说「帮我用 Phase-Contract 规划 XXX 项目」即可。Skill 会交互收集项目定位、phase 切分、硬约束，并按 [SKILL.md](./SKILL.md) 的 Procedure 生成完整制品：

```text
<project>/
├── .github/copilot-instructions.md
├── CLAUDE.md
├── AGENTS.md
├── plan/
│   ├── manifest.yaml
│   ├── common.md
│   ├── workflow.md
│   ├── state.yaml
│   ├── handoff.md
│   ├── phases/phase-0-*.md
│   └── execution/phase-0-*.md
└── scripts/planctl
```

手工安装脚手架到已有项目时，直接把 `scripts/planctl.rb` 复制过去并按模板生成其他文件即可；细节见 [SKILL.md](./SKILL.md)。

## Roadmap

从"不失忆"（当前版本）走向"不腐化"（12h 自治）的演进优先级：

1. **机器可验收的完成判定**（P0）——`execution` 声明 build/lint/test/diff 的 gate，`complete` 先跑 gate，红就拒绝写 state。
2. **git 级检查点 + 回滚**（P0）——每 phase 自动建分支打 tag，`complete` 成功合并，失败 reset；支持定点回滚单段而不是重跑全链。
3. **Meta-phase replan**（P1）——每 N 个实施 phase 强制插入一次重规划，manifest 变更走 `planctl amend` 留审计。
4. **合同 DAG + 并行执行**（P1）——`next --parallel N` 配合 git worktree，把 12h 串行压到 6–8h。
5. **定向上下文检索**（P2）——`planctl context <phase>` 从已完成产物抓片段，禁止 AI 自由 grep。
6. **预算、健康度、熔断**（P2）——token/时长/重试预算，连续失败自动 escalate 等人工。

演进哲学一以贯之：**把"AI 自律"换成"脚本强制"**。

## Documentation map

- [SKILL.md](./SKILL.md) — 生成脚手架的完整流程与 Quality Gates
- [references/glossary.md](./references/glossary.md) — 概念与名词表（合同链 / 三不变量 / 四类失败 / 调度器命令 / 相邻概念对比）
- [references/methodology.md](./references/methodology.md) — 方法论全文（三不变量 + 八原则 + 强制层 + 硬约束）
- [references/templates.md](./references/templates.md) — `manifest` / `common` / `state` / `handoff` 模板
- [references/phase-templates.md](./references/phase-templates.md) — 双层合同（phase 定位 + execution 围栏）模板
- [references/workflow-template.md](./references/workflow-template.md) — `plan/workflow.md` 模板与回退 / 结束全流程
- [references/agent-instructions-template.md](./references/agent-instructions-template.md) — 三份 agent 指令的共同模板
- [assets/README.md](./assets/README.md) — Logo / mark 资产与设计语义
- [CHANGELOG.md](./CHANGELOG.md) — 版本演进记录

## License

与本 agent skill 库同源；单独使用 `scripts/planctl.rb` 无外部依赖，按需复制即可。

<div align="center">

**中文** · [English](./README.en.md)

</div>
