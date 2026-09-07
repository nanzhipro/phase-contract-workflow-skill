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
    execution 文档负责显式声明这次执行的输入、边界、交付物、运行证据和完成标准。
  resolver: scripts/planctl
  state_file: plan/state.yaml
  handoff_file: plan/handoff.md
  require_phase_checks: true
  enforce_allowed_paths: true
  repo_instructions:
    - AGENTS.md                         # 唯一真源（Codex / 通用 Agent，含 Copilot）
    - CLAUDE.md                         # Claude Code（符号链接 -> AGENTS.md）
  continuous_execution:
    next_command: ruby scripts/planctl advance --strict
    completion_command: >-
      ruby scripts/planctl complete <phase-id> --summary "<summary>" --next-focus "<next-focus>" --continue
    contract_lint_command: ruby scripts/planctl lint-contracts --phase <phase-id>
    # complete --continue 会在写回 state/handoff 与里程碑提交后立即解析下一内部动作。
    # 若新 current phase 的 plan/execution 仍带 PHASE_CONTRACT_PLACEHOLDER，
    # planctl advance 会返回 ACTION: promote_placeholder；先把两份文件升级成正式合同，
    # 再重跑 advance --strict。不要把这一步当成用户确认点。
  continuation:
    mode: autonomous
    stop_only_on:
      - dependency_missing
      - missing_context
      - required_gate_failed
      - git_conflict
      - destructive_operation_required
      - all_phases_completed
    non_stop_actions:
      - phase_completed
      - next_phase_ready
      - placeholder_contract_promotion
      - optional_check_failed
      - no_remote_configured
  enforcement:
    dependency_check: true
    stop_on_missing_context: true
    require_execution_file: true
    require_contract_lint: true
    require_runtime_evidence: true
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
    allowed_paths:
      - <路径白名单 1>
      - <路径白名单 2>
    checks:
      required:
        - id: contract-lint
          command: ruby scripts/planctl lint-contracts --phase phase-0
          timeout_seconds: 60
        - id: build
          command: <build / test / integration / smoke 命令>
          timeout_seconds: 1800
      optional:
        - id: runtime-smoke
          command: <log / metric / artifact smoke 命令>
          timeout_seconds: 60
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
    allowed_paths:
      - <路径白名单>
    checks:
      required:
        - id: contract-lint
          command: ruby scripts/planctl lint-contracts --phase phase-1
          timeout_seconds: 60
  # 对于尚未进入的 future phase，建议先生成成对占位文件而不是空文件：
  # - plan/phases/phase-X-<slug>.md
  # - plan/execution/phase-X-<slug>.md
  # 两份文件都在前 40 行内保留 `PHASE_CONTRACT_PLACEHOLDER` 哨兵；
  # 当该 phase 成为 current phase 时，`advance --strict` 会返回 ACTION: promote_placeholder，
  # 逼 agent 先补正式合同，再进入实现；这不是用户确认点。
  # …后续 phase 按同样结构追加
```

**检查点**：

- `required_context` 恰好三项（common + plan + execution），不要多也不要少
- `depends_on` 只写真实依赖，禁止循环
- 新项目默认 `execution_rule.require_phase_checks: true` 和 `execution_rule.enforce_allowed_paths: true`
- 当前 phase 必须至少有一个 `checks.required` 条目；旧项目只有在 manifest 显式开启 `require_phase_checks: true` 时才会被 `complete` 阻断
- `allowed_paths` 与 execution 合同中的“本次允许改动”逐项一致，不能为空
- `compression_control.rules` 三条硬规则保持不变
- 尚未进入的 future phase 若不写正式合同，必须使用带 `PHASE_CONTRACT_PLACEHOLDER` 的成对占位文件；不要留空文件
- 所有正式 phase 的 plan / execution 文档都必须包含四个稳定 marker：
  - `PHASE_CONTRACT:FACT_AUDIT`
  - `PHASE_CONTRACT:PRODUCTION_WIRING`
  - `PHASE_CONTRACT:RUNTIME_EVIDENCE`
  - `PHASE_CONTRACT:FAILURE_MODES`

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
finalized_at: null
```

**注意**：此文件由 `planctl complete` 与首次成功的 `planctl finalize` 写入，人类禁止手改。successful `complete` 会把 phase 级 check 摘要写进 `completion_log[*].checks`，每条记录至少包含 `id`、`command`、`exit_code`、`duration_seconds`、`status` 和 `output_tail`。required check 失败时不会写入 `state.yaml`；optional check 失败会 warning，但仍随成功 phase 记录写进 ledger。`finalize` 只有在全部 manifest phase 都已完成且每个 phase 都有成功 completion log 证据时才会写 `finalized_at` 并输出仪表盘；否则 exit 2 且不写 ledger。重复 finalize 保持只读。

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
3. `advance.phase.required_context`

## 压缩控制规则

- 永远不要一次性加载所有 phase 文档。
- 只在当前 phase 读取 plan/common.md、当前 phase plan 和当前 phase execution。
- 每完成一个 phase 后更新 handoff，再进入下一 phase。

## 连续执行命令

- next: `ruby scripts/planctl advance --strict`
- lint: `ruby scripts/planctl lint-contracts --phase <phase-id>`
- complete: `ruby scripts/planctl complete <phase-id> --summary "<summary>" --next-focus "<next-focus>" --continue`
- handoff-repair (manual recovery only): `ruby scripts/planctl handoff --write`
```

**注意**：`planctl handoff --write` 会以这个结构覆盖写入；它是**手动补救**命令，正常 Golden Loop 不需要额外调用，因为 `complete` 已在依赖检查、合同 lint、required checks 和 `allowed_paths` gate 全部通过之后自动刷新 handoff，而首次成功的 `finalize` 也会在写入 `finalized_at` 后自动刷新 handoff。初始手工留一份合格骨架只是为了首次 `advance` 之前可读。
