# Phase-Contract Workflow TODO

记录日期：2026-05-01

## 来龙去脉

Phase-Contract Workflow 当前已经解决了长任务里最基础、也最致命的稳定性问题：AI 不再依赖自己的记忆推进任务，而是通过仓库里的 `manifest.yaml`、`common.md`、phase 合同、execution 合同、`state.yaml`、`handoff.md` 和 `scripts/planctl` 持续续跑。

现有版本的核心能力可以概括为：让一个大任务稳定拆成多个小合同，任意时刻只执行一个 phase；每个 phase 完成后由 `planctl complete` 写回状态、刷新 handoff，并形成 git 里程碑；上下文压缩或新会话后可以用 `planctl resume --strict` 恢复；所有 phase 完成后必须用 `planctl finalize` 输出最终仪表盘，把上线、发版、归档等决策交还人类。

这套机制的当前定位是：从“AI 连续工作 5+ 小时不失忆”开始，逐步走向“12-24 小时不腐化”。下一阶段的重点不是继续加长提示词，而是把更多“是否可以继续”的判断交给脚本强制执行，让 AI 即使疲劳、压缩、换会话，也不能跳过验收、越界修改、隐式改计划或带病续跑。

## 当前现状

- 已有三文件上下文律：工作窗口固定为 `common + phase + execution`。
- 已有双层合同：`plan/phases/*` 定义“是什么”，`plan/execution/*` 定义“能碰什么”。
- 已有占位合同阻断：future phase 未升级成正式合同时，`advance --strict` 会返回 `ACTION: promote_placeholder`，要求先升级合同再实施。
- 已有自动续跑状态机：`advance --strict` 输出 `ACTION: implement` / `promote_placeholder` / `finalize` / `stop`，phase 边界不再天然成为用户确认点。
- 已有状态外部化：`complete` 写入 `plan/state.yaml` 与 `plan/handoff.md`。
- 已有冷启动恢复：`resume --strict` 一次性输出恢复所需上下文。
- 已有路径白名单预检：`allowed_paths` 可在 `complete` 前检查 staged diff 是否越界。
- 已有里程碑提交：`complete` 自动执行 git add / commit / push。
- 已有回退入口：`revert` 可按 phase 回滚 ledger 与 git 历史。
- 已有整体收尾：`finalize` 在所有 phase 完成后输出最终执行仪表盘。
- 已有健康检查：`doctor` 校验 manifest、state、handoff 和 agent 指令（`AGENTS.md` + `CLAUDE.md` 符号链接）一致性。

## 已完成优化：Autonomous Continuation Mode

背景：实测发现每个 phase 完成后，agent 容易停下来请求用户确认。根因是“继续执行”只写在文档规约里，`planctl complete` 只提示用户再运行 `next`，并没有把“下一步动作”变成脚本状态机。

已落地：

- [x] 新增 `planctl advance --strict`，以 `ACTION` 明确下一步。
- [x] `ACTION: implement` 表示当前 phase 可直接实施。
- [x] `ACTION: promote_placeholder` 表示当前 phase 仍是占位合同，应先升级合同，不是用户确认点。
- [x] `ACTION: finalize` 表示全部 phase 已完成，应运行 `finalize` 后把发布/归档等决策交还人类。
- [x] `ACTION: stop` 表示真实 blocker，才需要停下来汇报。
- [x] `complete --continue` 在 phase 完成后自动接上 `advance`。
- [x] `execution_rule.continuation.mode: autonomous` 下，即使遗漏 `--continue`，`complete` 也会自动接上 `advance`。
- [x] 模板和 agent 指令已从 `next --strict` 的人工式循环，升级为 `advance --strict` 的自动续跑状态机。

## 总体演进目标

把当前的“长任务不失忆”升级为“长任务不腐化”：

- 不只知道下一步做什么，还能证明上一 phase 真的通过了验收。
- 不只记录完成状态，还能记录验收命令、失败次数、耗时、风险和回滚点。
- 不只支持线性 phase，还能支持 epic 分组、DAG 并行和多 agent 协作。
- 不只依赖 AI 自觉读上下文，还能通过脚本提供定向上下文检索。
- 不只在最后 finalize，还能在中途周期性重规划和健康熔断。

## 已完成优化：完整性质量门

目标：让 `complete` 从“记录 AI 说完成了”，升级为“只有机器 gate 通过才允许写 state”。

已落地：

- [x] 在 `manifest.yaml` 中定义 `checks.required / checks.optional`。
- [x] 支持 build / lint / test / typecheck / custom command 等 shell gate。
- [x] `planctl complete` 在写入 `state.yaml` 前自动运行 `lint-contracts` 与 required checks。
- [x] 任一 required check 失败或 timeout 时，拒绝写入 `state.yaml`、`handoff.md`，也不 commit / push。
- [x] 将 check 命令、退出码、耗时、状态和输出摘要写入 `completion_log[*].checks`。
- [x] 区分 `required` 和 `optional`，optional 失败只 warning。
- [x] `doctor` 集成当前 phase 的合同 lint。
- [x] 新增 `tests/planctl_quality_gates_test.rb` 覆盖上述质量门。

下一步：

- [ ] 在 `finalize` 仪表盘里按 phase 汇总 gate 结果，而不是只留在 `completion_log`。
- [ ] 为失败的 preflight checks 增加结构化失败日志，方便后续 repair / retry 命令复用。

## P0：两阶段 Complete 事务

目标：避免 `state.yaml` 领先于 git commit、push 或验收结果。

TODO：

- [ ] 将 `complete` 拆成 checking、writing_state、committing、completed 等阶段。
- [ ] 在 `state.yaml` 或临时 ledger 中记录 in-progress complete 状态。
- [ ] commit 失败时输出可恢复指令，而不是让 ledger 和 git 历史长期分叉。
- [ ] 支持 `planctl repair-complete <phase-id>` 重放未完成的 commit / push / handoff。
- [ ] 明确哪些失败会阻塞 phase 完成，哪些失败只产生 warning。

设计备注：

- 当前 `complete` 已经先写 state 再 commit。如果 commit hook、签名、push 权限失败，phase 会被视为完成但 git 里程碑可能缺失。短任务可以接受，12 小时以上任务应更严格。

## P0：默认严格路径边界

目标：让 phase 越界修改默认被阻断，而不是仅 warning。

TODO：

- [x] 将新生成项目的 `execution_rule.enforce_allowed_paths` 默认设为 `true`。
- [x] `planctl lint-contracts` 检查当前正式 phase 的 `allowed_paths` 是否为空，并要求与 execution 合同一致。
- [x] `planctl complete` 在写 state 前把越界路径当作 hard gate。
- [ ] 在 phase 占位模板中强制要求填写 `allowed_paths`（占位 phase 仍允许稍后补正式值）。
- [ ] `planctl doctor` 对当前 phase 缺少 `allowed_paths` 给出更明确的专门提示，而不只依赖合同 lint。
- [ ] 为临时放宽边界提供显式 override，并要求写入风险说明。

设计备注：

- 路径边界是防止长任务“顺手修一下别的地方”的关键机制。越长的任务，越应该默认严格。

## P1：Git 检查点与 Phase 隔离

目标：把每个 phase 从“一个提交”升级为“一个可隔离、可审计、可回退的事务单元”。

TODO：

- [ ] 每个 phase 自动创建 `phase/<phase-id>` 分支或 worktree。
- [ ] phase 只在隔离分支 / worktree 中实施。
- [ ] required checks 全绿后再 merge 回主工作分支。
- [ ] phase 完成后自动创建轻量或注释 tag，例如 `phase/<phase-id>`。
- [ ] `revert` 支持基于 phase tag / branch checkpoint 回退。
- [ ] `finalize` 显示每个 phase 对应的 branch、merge commit 和 tag。

设计备注：

- 当前已有 commit/push 与 `revert`，但仍然是在同一个工作树里推进。更长任务需要更强隔离，避免一个失败 phase 污染主线。

## P1：Meta-Phase Replan

目标：允许长期任务在中途正式重规划，但禁止 AI 偷偷改 manifest。

TODO：

- [ ] 新增 `planctl amend` 命令，所有 manifest 变更必须通过它。
- [ ] 每 N 个实施 phase 后强制插入一次 `meta-replan`。
- [ ] `amend` 只能修改未完成 phase，不能改写已完成 ledger。
- [ ] manifest 变更写入 `plan/amendments.log` 或 `state.yaml` 的 amendment ledger。
- [ ] 支持拆分 phase、合并 future phase、调整 depends_on、升级 allowed_paths。
- [ ] `doctor` 检查 manifest 变更是否有审计记录。
- [ ] `finalize` 展示整个计划的 replan 历史。

设计备注：

- 5 小时任务可以依赖初始 plan，12 小时以上任务必须承认现实会变化。关键不是禁止重规划，而是让重规划显式、可审计、不可偷偷发生。

## P1：Epic 分组层

目标：支持超过 12 个 phase 的超长任务，而不是把 phase 平铺成一条过长队列。

TODO：

- [ ] 在 manifest 中引入 `epics` 层级。
- [ ] 每个 epic 有自己的目标、验收、phase 列表和收尾摘要。
- [ ] `advance` 支持按 epic 顺序推进。
- [ ] `status` 显示 epic 级进度。
- [ ] `finalize` 先输出 epic ledger，再输出全局 ledger。
- [ ] 文档中明确：phase 仍保持 30-90 分钟粒度，超长项目靠 epic 承载规模。

设计备注：

- 当前文档要求 phase 数超过 12 时重切或引入 epic。下一步应把 epic 从建议变成正式能力。

## P1：合同 DAG 与并行执行

目标：让没有依赖冲突的 phase 可以并行推进，适配多 agent 或多工作树协作。

TODO：

- [ ] 新增 `planctl ready`，返回所有依赖已满足且未完成的 phase。
- [ ] 新增 `planctl next --parallel N`。
- [ ] 支持为并行 phase 分配独立 git worktree。
- [ ] `state.yaml` 写入加锁，避免多个 agent 同时 complete。
- [ ] merge 前统一运行 required checks。
- [ ] 对同路径 `allowed_paths` 冲突的 phase 标记为不可并行。
- [ ] `finalize` 展示并行执行拓扑和实际耗时。

设计备注：

- 线性合同链最稳，但不一定最快。DAG 并行适合 12 小时以上任务压缩总耗时，同时需要更强的 git 隔离和 state 锁。

## P2：定向上下文检索

目标：保留三文件上下文律，同时允许当前 phase 安全引用历史产物。

TODO：

- [ ] 新增 `planctl context <phase-id>`。
- [ ] 新增 `planctl decisions`，输出历史关键决策。
- [ ] 新增 `planctl artifacts`，输出各 phase 交付物索引。
- [ ] 新增 `planctl diff-summary <phase-id>`，输出某 phase 的变更摘要。
- [ ] 禁止 agent 自由加载全部历史 phase 文档；需要历史信息时优先使用 context 命令。
- [ ] 在 handoff 中记录下一 phase 最可能需要的历史片段。

设计备注：

- 长任务后期必然需要回看历史。但如果让 AI 自由 grep，三文件上下文律会被慢慢腐蚀。正确方向是脚本提供窄输出。

## P2：预算、健康度与熔断

目标：让流程能识别“继续跑下去不健康”，并自动停下来交还人类或触发 replan。

TODO：

- [ ] 在 state 中记录 phase 开始时间、完成时间、耗时。
- [ ] 记录每个 phase 的 retry 次数和 gate 失败次数。
- [ ] 记录最近失败原因和恢复建议。
- [ ] 支持 phase 级时间预算、重试预算和 diff 规模预算。
- [ ] 同一 gate 连续失败达到阈值时自动熔断。
- [ ] 单 phase 超出预算时要求 replan 或人工确认。
- [ ] `status` 和 `finalize` 输出健康度评分。
- [ ] `doctor` 将健康风险分为 warning 和 blocker。

设计备注：

- 长任务不是一直往前跑才好。真正可靠的长任务系统，要知道什么时候停下来。

## P2：合同质量 Lint

目标：把文档里的 Quality Gates 变成机器可运行的检查。

TODO：

- [x] 新增 `planctl lint-contracts`。
- [x] 检查 completion criteria / delivery checks 是否包含“良好”“合理”“基本完成”等主观词。
- [x] 检查 effective `required_context` 是否恰好三份。
- [x] 检查当前 phase 是否仍是占位合同，并对 future placeholder 保持兼容。
- [x] 检查当前正式 phase 是否包含非空 `allowed_paths`。
- [x] 检查四个稳定 marker 与 `Production Wiring` 表是否存在。
- [ ] 检查 execution 中的“本次允许改动”是否与 manifest `allowed_paths` 逐项一致，而不只是非空。
- [ ] 增加对 `test_only` / `future_phase:<id>` 标注完整性的专项 lint。
- [ ] 检查 execution 是否写成步骤清单，而不是边界围栏。
- [ ] 检查 common.md 是否混入某个 phase 专属规则或实施步骤。
- [ ] 将 lint 结果接入 `doctor`。

设计备注：

- 当前 Quality Gates 已写在文档里。下一步应把“人肉 checklist”升级成 `planctl` 可执行命令。

## 建议实施顺序

1. 先做 P0 机器验收 gate。
2. 再做两阶段 `complete`，把 gate、state、commit 变成更一致的事务。
3. 将 `allowed_paths` 默认严格化，并补 `lint-contracts` 的最小版本。
4. 做 `planctl amend`，给长期任务提供正式重规划入口。
5. 引入 epic 层，解决超过 12 phase 的计划结构问题。
6. 在 git 隔离成熟后，再做 DAG 并行和 worktree 支持。
7. 最后补齐定向 context、预算熔断和健康仪表盘。

## 核心判断

后续优化不应把单个 phase 做大，也不应把 agent 指令写得越来越长。正确方向是继续把判断外部化：

- 能否开始，由 `advance` / `resolve` 判断。
- 能否完成，由 machine checks 判断。
- 能否越界，由 `allowed_paths` 判断。
- 能否改计划，由 `amend` 判断。
- 能否继续跑，由 health / budget / circuit breaker 判断。
- 能否结束，由 `finalize` 判断。

Phase-Contract Workflow 的长期价值，不是让 AI 更自觉，而是让 AI 在长时间运行后仍然被一套仓库内机制稳稳约束。
