# Phase 双层合同模板

每个正式 phase 必须同时维护两份文档：`plan/phases/phase-X.md` 和 `plan/execution/phase-X.md`。前者定义“这个阶段是什么”，后者定义“这次实施能碰什么、必须证明什么”。两份文档都必须包含稳定 marker，便于 `planctl lint-contracts` 做机器验收。

---

## 1. 正式定位合同：`plan/phases/phase-X-<slug>.md`

```markdown
# Phase X: <标题>

## 阶段定位

<这个阶段在整条链路里解决什么问题，一句话说清>

## 必带上下文

- plan/common.md
- plan/phases/phase-X-<slug>.md
- plan/execution/phase-X-<slug>.md

## 阶段目标

- <客观目标 1>
- <客观目标 2>
- <客观目标 3>

## 实施范围

- <允许涉及的模块 / 文件 / 能力>
- <允许涉及的模块 / 文件 / 能力>

## 本阶段产出

- <具体交付物 1>
- <具体交付物 2>

## 明确不做

- <越界项 1>
- <越界项 2>

## PHASE_CONTRACT:FACT_AUDIT

- 真实入口：<启动入口 / provider / factory / publisher / router>
- 真实调用方：<谁会在生产链路里调用它>
- target / 打包归属：<产物属于哪个 target / package / deployable>
- 证据命令：<rg / git grep / xcodebuild -showBuildSettings / project file 检查方式>

## PHASE_CONTRACT:PRODUCTION_WIRING

### Component Adoption Table

| artifact | producer | production caller | activation condition | fallback behavior | runtime evidence | owning phase |
| --- | --- | --- | --- | --- | --- | --- |
| <类 / target / config / key / log / metric> | <谁生成 / 注册它> | <生产调用点> | <什么条件下激活> | <关闭 / 缺失时退化到什么> | <日志 / 指标 / 文件 / 行为证据> | <phase-id> |

如果当前 phase 没有生产接线，必须显式写：`N/A: <原因>`，例如 `N/A: documentation-only phase`。

## PHASE_CONTRACT:RUNTIME_EVIDENCE

- <能证明真实链路生效的日志 / 指标 / 文件 / 运行行为>
- <冷启动 / 重启 / digest / XPC ready / late reply 等证据点>
- <与 manifest.checks.required / optional 对应的可运行验证>

## PHASE_CONTRACT:FAILURE_MODES

- 启动 / 冷启动：<失败模式 + 期望行为>
- 重启 / 恢复：<失败模式 + 期望行为>
- 超时 / late reply：<失败模式 + 期望行为>
- 并发 / 重复触发：<失败模式 + 期望行为>
- 配置关闭 / 空状态 / fallback：<失败模式 + 期望行为>

## 完成判定

- `ruby scripts/planctl lint-contracts --phase <phase-id>` 返回 0。
- `manifest.yaml` 中该 phase 的 required checks 全部通过。
- Component Adoption Table 中列出的生产调用点都能被 Runtime Evidence 证明。
- 交付检查无主观词，且每一条都可被运行或观察到。

## 依赖关系

- 依赖 <phase-id>
```

### 写作铁律

- `PHASE_CONTRACT:*` 四个 marker 必须原样保留，不能改拼写、不能只写同义词。
- `Fact Audit` 关注“真实入口和真实调用方”，不是实现设想。
- `Production Wiring` 必须说明生产调用点、激活条件和 fallback；只在测试里出现的组件要在表格里标成 `test_only`。
- 如果某组件计划在未来 phase 才接线，当前 phase 必须保持默认关闭，同时在表格里写明 `future_phase:<phase-id>`。
- `Runtime Evidence` 必须证明“真实链路用了它”，不能只写局部单测。
- `Failure Modes` 至少覆盖启动、重启、超时、late reply、并发、配置关闭、空状态。
- 完成判定禁止出现 `良好`、`合理`、`基本完成`、`可接受`、`看起来` 等主观词。

---

## 2. 正式执行合同：`plan/execution/phase-X-<slug>.md`

```markdown
# Phase X 执行包

本文件不能单独使用。执行当前 phase 时，必须同时携带完整的 `plan/common.md` 和配对的 `plan/phases/phase-X-<slug>.md`。

## 必带上下文

- plan/common.md
- plan/phases/phase-X-<slug>.md
- plan/execution/phase-X-<slug>.md

## 执行目标

- <这次实施要真正落地的目标 1>
- <这次实施要真正落地的目标 2>

## 本次允许改动

- <路径白名单 1>
- <路径白名单 2>
- <路径白名单 3>

## 本次不要做

- <禁止涉及的模块 / 重构 / feature>
- <禁止修改的配置 / 依赖 / 部署面>

## PHASE_CONTRACT:FACT_AUDIT

- 检查命令：<rg / git grep / project file / package metadata>
- 实际生产入口：<入口函数 / 注册点 / 配置装配点>
- 实际消费方：<服务 / 控制器 / worker / UI / 任务调度器>

## PHASE_CONTRACT:PRODUCTION_WIRING

### Component Adoption Table

| artifact | producer | production caller | activation condition | fallback behavior | runtime evidence | owning phase |
| --- | --- | --- | --- | --- | --- | --- |
| <类 / target / config / key / log / metric> | <谁生成 / 注册它> | <生产调用点> | <什么条件下激活> | <关闭 / 缺失时退化到什么> | <哪条日志 / 指标 / 文件 / 行为能证明它> | <phase-id> |

如果没有生产接线，必须显式写：`N/A: <原因>`。

## PHASE_CONTRACT:RUNTIME_EVIDENCE

- required checks：<与 manifest.checks.required 对齐>
- optional checks：<与 manifest.checks.optional 对齐>
- 运行时证据：<日志 / metrics / 文件 / 进程行为 / XPC / 网络交互>

## PHASE_CONTRACT:FAILURE_MODES

- 冷启动 / 重启：<要观察什么>
- timeout / late reply：<要观察什么>
- 并发 / 重复请求：<要观察什么>
- 关闭开关 / 空状态 / fallback：<要观察什么>

## 交付检查

- `ruby scripts/planctl lint-contracts --phase <phase-id>` 返回 0。
- required checks 全绿；optional checks 若失败，必须有 warning 和 completion log 记录。
- `allowed_paths` 与“本次允许改动”逐项对齐。
- Runtime Evidence 能直接映射到 Production Wiring 表中的每一行。

## 执行裁决规则

- 如果发现真实生产调用点不在当前 phase 约定范围内，停止并回到规划边界。
- 如果只能用测试代码证明组件存在、却不能证明生产链路使用它，判定为未完成。
- 如果新增组件要到未来 phase 才接线，当前 phase 必须默认关闭，并在合同与 manifest 中留出后续承接。
```

### 写作铁律

- execution 是围栏，不是脚本，不要把它写成“第一步做 A，第二步做 B”。
- `本次允许改动` 必须与 manifest 的 `allowed_paths` 一一对应。
- `交付检查` 要比定位合同的“完成判定”更细，而且必须能被 `complete` 的质量门证明。
- 新增类、target、config、key、log、metric，如果会影响真实链路，都必须进入 Component Adoption Table。

---

## 3. 未来 phase 的占位合同

当 manifest 需要提前引用未来 phase 的 `plan_file` / `execution_file`，但当前还没有进入该 phase 时，先生成一对占位合同。占位合同只负责保留 phase id、标题和 manifest 引用，不得冒充正式合同。

### 3.1 占位定位合同

```markdown
# Phase X: <标题>

> PHASE_CONTRACT_PLACEHOLDER
> 当前为占位合同，禁止实施。
> 进入本 phase 时，必须先把本文件和配对 execution 文件升级成正式合同，再开始任何实现。

## 当前状态

- 当前尚未进入本 phase
- 本文件仅用于保留标题与 manifest 引用
```

### 3.2 占位执行合同

```markdown
# Phase X 执行包

> PHASE_CONTRACT_PLACEHOLDER
> 当前为占位合同，禁止实施。
> 进入本 phase 时，必须先把本文件和配对 phase 文件升级成正式合同，再开始任何实现。

## 当前状态

- 当前尚未进入本 phase
- 本文件不是执行边界，不能直接用于实施
```

### 3.3 占位合同铁律

- `PHASE_CONTRACT_PLACEHOLDER` 必须保留在文件前 40 行内，直到正式合同写完再删除。
- 占位 phase 轮到当前时，`planctl advance --strict` 会返回 `ACTION: promote_placeholder`；先升级两份合同，再重跑 strict 命令。
- 不要只升级一份，单边升级会让“目标”和“边界”漂移。

---

## 4. 自检清单

- [ ] 两份正式合同都包含四个 `PHASE_CONTRACT:*` marker。
- [ ] effective `required_context` 恰好是 `common + phase + execution` 三份。
- [ ] `allowed_paths` 非空，且与 execution 的“本次允许改动”一致。
- [ ] Component Adoption Table 已覆盖所有新增类 / target / config / key / log / metric。
- [ ] 只在测试里出现的组件已标 `test_only`。
- [ ] 未来 phase 才接线的组件已默认关闭，并标明 `future_phase:<phase-id>`。
- [ ] `Runtime Evidence` 证明的是真实运行链路，不是局部实现存在。
- [ ] `Failure Modes` 覆盖启动、重启、超时、late reply、并发、配置关闭、空状态。
- [ ] “完成判定”和“交付检查”没有主观词。
- [ ] required checks 与 optional checks 已在 manifest 中声明。

任一项不过，就不要进入实现。

---

## 5. 常见反模式

| 反模式 | 表现 | 修正 |
| --- | --- | --- |
| 只写单测，不写真实接线 | 组件类存在，但生产入口没有接上 | 在 `Fact Audit` 和 `Production Wiring` 中补真实调用点 |
| Runtime Evidence 只有“测试通过” | 无法证明真实链路用了该组件 | 改成日志 / 指标 / 文件 / 行为级证据 |
| Production Wiring 表为空且不说明原因 | AI 不知道是不是遗漏 | 写清 `N/A: <原因>` |
| allowed_paths 留空 | 范围边界无法机器化 | 在 manifest 填非空白名单，并和 execution 对齐 |
| 只升级 phase 文档，不升级 execution 文档 | 目标和边界失步 | 成对升级，再重跑 `advance --strict` |
| 完成判定写“看起来没问题” | 只能主观判断 | 改写成可运行、可观察、可勾选的客观项 |
