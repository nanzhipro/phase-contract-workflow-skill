# Plan Infrastructure Templates

本文件提供 `plan/manifest.yaml`、`plan/common.md`、`plan/state.yaml`、`plan/handoff.md` 四份基础制品的可复制模板。占位符用尖括号标注，生成时逐项替换。

---

## 1. `plan/manifest.yaml`

```yaml
version: 1
kind: <project>-plan-manifest
entrypoints:
  overview: README.md
  common: plan/common.md
  workflow: plan/workflow.md
  handoff: plan/handoff.md
execution_rule:
  description: >-
    执行任一 Phase 时，必须同时携带完整通用上下文和当前 Phase 文档。
    execution 文档负责显式声明这次执行的输入、边界、交付物和完成标准。
  resolver: scripts/planctl
  state_file: plan/state.yaml
  handoff_file: plan/handoff.md
  repo_instructions:
    - .github/copilot-instructions.md   # GitHub Copilot
    - CLAUDE.md                         # Claude Code
    - AGENTS.md                         # Codex / 通用 Agent
  continuous_execution:
    next_command: ruby scripts/planctl next --format prompt --strict
    completion_command: >-
      ruby scripts/planctl complete <phase-id> --summary "<summary>" --next-focus "<next-focus>"
  enforcement:
    dependency_check: true
    stop_on_missing_context: true
    require_execution_file: true
  # 可选：把 phase.allowed_paths 从"仅警告"升级为"违规直接 abort"。
  # 建议在项目稳定后开启，强制 AI 在 phase 边界内产出。
  enforce_allowed_paths: false
  compression_control:
    enabled: true
    max_completion_history: 3
    resume_read_order:
      - plan/manifest.yaml
      - plan/handoff.md
      - next.phase.required_context
    rules:
      - 永远不要一次性加载所有 phase 文档。
      - 只在当前 phase 读取 plan/common.md、当前 phase plan 和当前 phase execution。
      - 每完成一个 phase 后更新 handoff，再进入下一 phase。
  read_order:
    - plan/common.md
    - phase.plan_file
    - phase.execution_file
  required_context:
    - plan/common.md
phases:
  - id: phase-0
    title: <phase-0 标题>
    plan_file: plan/phases/phase-0-<slug>.md
    execution_file: plan/execution/phase-0-<slug>.md
    required_context:
      - plan/common.md
      - plan/phases/phase-0-<slug>.md
      - plan/execution/phase-0-<slug>.md
    depends_on: []
    # 可选：允许改动的路径白名单（glob）。与 execution 的"允许改动"一一对应。
    # 当 execution_rule.enforce_allowed_paths 或 PHASE_CONTRACT_ENFORCE_PATHS=1 时，
    # `complete` 在写回 state.yaml 之前会把 `git diff --cached` 与此白名单比对；
    # 任何越界路径会直接 abort，state.yaml 不会被更新。
    # 留空则退化为只警告（默认行为）。
    allowed_paths: []
  - id: phase-1
    title: <phase-1 标题>
    plan_file: plan/phases/phase-1-<slug>.md
    execution_file: plan/execution/phase-1-<slug>.md
    required_context:
      - plan/common.md
      - plan/phases/phase-1-<slug>.md
      - plan/execution/phase-1-<slug>.md
    depends_on:
      - phase-0
  # …后续 phase 按同样结构追加
```

**检查点**：

- `required_context` 恰好三项（common + plan + execution），不要多也不要少
- `depends_on` 只写真实依赖，禁止循环
- `compression_control.rules` 三条硬规则保持不变

---

## 2. `plan/common.md`

```markdown
# <项目名> 通用规划约束

本文件是 <项目名> 全部 Phase 的长期稳定约束来源。任何单步执行都必须把本文件作为完整上下文的一部分，而不是只看局部任务。

## 结论

<一句话说明项目定位，例如：这是一个面向 XXX 的新建项目，不做兼容迁移；现有实验性代码仅作参考。>

本规划将以下要求视为硬约束，而不是"后续优化项"：

- <硬约束 1>
- <硬约束 2>
- <硬约束 3>

## 产品/项目目标

<该项目要解决的核心问题，尽量单一>

## 非目标

<明确不做的能力，用来对抗 scope creep>

- <非目标 1>
- <非目标 2>

## 硬性工程约束

### 平台与工具链

- <最低系统版本 / 运行时版本>
- <开发工具版本>
- <语言版本>
- <构建工具>

### 依赖边界

禁止引入以下内容：

- <禁用依赖 1>
- <禁用依赖 2>

允许使用的仅限：

- <允许依赖 1>
- <允许依赖 2>

## 质量底线

- <测试策略底线>
- <签名/安全底线>
- <日志/可观测性底线>

## 其他不可跨越的边界

- <如有：国际化、视觉规范、隐私模型、合规条款等>
```

**撰写判据**：一条规则是否该进 common.md？问自己——**任意未来 phase 都可能违反它吗？** 是，才写。

---

## 3. `plan/state.yaml`（初始态）

```yaml
---
version: 1
completed_phases: []
completion_log: []
updated_at: null
```

**注意**：此文件由 `planctl complete` 写入，人类禁止手改。初始只需以上骨架。

---

## 4. `plan/handoff.md`（初始态）

```markdown
# <项目名> Execution Handoff

本文件用于长流程执行时的压缩恢复。不要一次性重新加载全部 phase 文档；恢复时按本文档与 manifest 继续。

## 当前状态

- State file: `plan/state.yaml`
- Handoff file: `plan/handoff.md`
- Updated at: `<尚未开始>`
- Completed phases: `<none>`

## 最近完成

<尚未开始任何 phase>

## 下一 Phase

- `phase-0` <phase-0 标题>
- plan: `plan/phases/phase-0-<slug>.md`
- execution: `plan/execution/phase-0-<slug>.md`

下一步读取顺序：
1. `plan/common.md`
2. `plan/phases/phase-0-<slug>.md`
3. `plan/execution/phase-0-<slug>.md`

## 压缩恢复顺序

1. `plan/manifest.yaml`
2. `plan/handoff.md`
3. `next.phase.required_context`

## 压缩控制规则

- 永远不要一次性加载所有 phase 文档。
- 只在当前 phase 读取 plan/common.md、当前 phase plan 和当前 phase execution。
- 每完成一个 phase 后更新 handoff，再进入下一 phase。

## 连续执行命令

- next: `ruby scripts/planctl next --format prompt --strict`
- complete: `ruby scripts/planctl complete <phase-id> --summary "<summary>" --next-focus "<next-focus>"`
- handoff: `ruby scripts/planctl handoff --write`
```

**注意**：`planctl handoff --write` 会以这个结构覆盖写入；初始手工留一份合格骨架方便首次 `next` 之前查看。
