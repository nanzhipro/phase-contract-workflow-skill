<div align="center">

<img src="./assets/phase-contract-logo.svg" alt="Phase-Contract Workflow" width="720">

# Phase-Contract Workflow

**About**: Disk-backed scaffolding for long-running AI workflows that survive context compression, fresh sessions, and Agent switches.

Model any long project as an **ordered chain of contracts**: progress, dependencies, and blast radius all live on disk. Stability comes from files and scripts in the repo, not from the model's memory.

> _"Move AI stability out of model memory and into the repository filesystem."_

[![install](https://img.shields.io/badge/install-npx%20skills%20add-informational?logo=npm)](https://www.npmjs.com/package/skills)
[![Copilot](https://img.shields.io/badge/GitHub%20Copilot-supported-24292e?logo=github)](./references/agent-instructions-template.md)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-supported-d97757)](./references/agent-instructions-template.md)
[![Codex](https://img.shields.io/badge/Codex-supported-10a37f)](./references/agent-instructions-template.md)

**English** · [中文](./README.zh-CN.md)

</div>

---

**Quick links**: [Install](#install--update) · [Quick start](#quick-start) · [How it works](#how-it-works) · [Documentation](#documentation-map)

## Why

Any AI Agent running continuously for 3+ hours will reliably hit four failure modes: **progress drift, scope creep, goal amnesia, and compression amnesia**. Writing a longer and more detailed `Plan.md` and trusting the model to self-police will still break at hour 2-3. This project shuts those failures down with **mechanism**, not with discipline.

## Core idea

One line: **move AI stability out of "model memory" and into "repository filesystem".** The Agent only completes small contracts inside a small window; continuity across hours, sessions, and Agent switches is carried by scripts and files on disk.

Four load-bearing claims:

- **A long task is an ordered contract chain.** Decompose a month-scale project into `Phase₀ → Phase₁ → … → Phaseₙ`. Every Phase is defined by two documents: a _positioning contract_ (what it is) and an _execution contract_ (what it may touch). Goal and blast radius stay orthogonal.
- **Three invariants are non-negotiable.** **I1** exactly one active Phase at any time; **I2** the working window always contains `common + phase + execution` - three docs, no more; **I3** completion only counts after it is written to `state.yaml`. Break any one and a long task will eventually derail.
- **Mechanism beats discipline.** Progress is persisted atomically by the scheduler, blast radius is enforced by path-whitelist diffing, dependencies are blocked by `--strict`, and recovery is governed by `handoff.md` as a protocol. Stability is externally enforced, not begged for in the prompt.
- **Scheduling is separated from execution.** `planctl` decides _what's next_; the AI only decides _how_. This is the only known way to keep the same AI capability usable five hours in.

Corollary: this is neither a smarter prompt nor an Agent Framework. It is the minimum infrastructure that makes a **generic AI behave like a long-horizon engineer** under disk-level constraints.

## How it works

Three layers, cleanly separated:

| Layer | Role | Authored by |
| --- | --- | --- |
| **Enforcement**<br>`.github/copilot-instructions.md` · `CLAUDE.md` · `AGENTS.md` | Turns the rules from "suggestions" into session-level preconditions | Human (all three kept byte-identical) |
| **Scheduler**<br>`scripts/planctl` | Decides the next step, checks dependencies, writes the ledger atomically | Reuse the script in this repo |
| **Contracts**<br>`plan/manifest.yaml` · `plan/common.md` · `plan/phases/*` · `plan/execution/*` | Defines _what to do_ (Phase) and _what may be touched_ (Execution) | Human (AI-assisted) |

Runtime state lives in two files, owned exclusively by the scheduler:

- `plan/state.yaml` — objective progress ledger (atomically written on `complete`)
- `plan/handoff.md` — compression-recovery anchor (auto-refreshed on `complete`)

## Install & update

Use the [`skills`](https://www.npmjs.com/package/skills) CLI to install this repo as an Agent Skill into the skills directory of Copilot / Claude Code / Codex. One command handles fetch, registration, and future upgrades.

```bash
# Install into the current Agent's default skills directory (auto-detected)
npx skills add nanzhipro/phase-contract-workflow-skill

# Target a specific Agent explicitly
npx skills add github:nanzhipro/phase-contract-workflow-skill --agent claude
npx skills add github:nanzhipro/phase-contract-workflow-skill --agent copilot
npx skills add github:nanzhipro/phase-contract-workflow-skill --agent codex

# Update to latest main
npx skills update phase-contract-workflow-skill

# Force reinstall (overwrites local edits - back up first)
npx skills add nanzhipro/phase-contract-workflow-skill --force

# Remove
npx skills remove phase-contract-workflow-skill
```

Once installed, just tell the Agent "plan XXX with Phase-Contract" in any session. The Skill's discovery description lives in the [SKILL.md](./SKILL.md) frontmatter.

## Golden loop

Every Phase runs the same loop. You can compress or swap sessions at any breakpoint - re-entering from the top loses nothing.

```text
next --strict  →  load 3 docs  →  execute (within execution boundary)
                                           ↓
                    ← handoff (by script) ← complete <id>
```

A single command kicks off or resumes:

```bash
ruby scripts/planctl next --format prompt --strict     # new session / daily driver
ruby scripts/planctl resume --strict                   # cold start after compression
ruby scripts/planctl complete <id> --summary "..." --next-focus "..."
ruby scripts/planctl doctor                            # repo health check (SHA256-diff the three instruction files, etc.)
```

Phase boundaries are internal, not user confirmation points. After `complete`, immediately rerun `next --strict`; if the new current Phase is still a placeholder pair, promote both contracts to formal docs first. Details live in [references/phase-templates.md](./references/phase-templates.md) and [references/workflow-template.md](./references/workflow-template.md).

## Design principles

- **Externalize state** - progress goes to files, not memory.
- **Separate scheduling from execution** - the script decides _what_, the AI decides _how_.
- **Three-file context law** - the working window is always `common + phase + execution`.
- **Two-layer contract** - `phases/*` says _what it is_; `execution/*` says _what may be touched_ - goal and boundary kept orthogonal.
- **Done means written** - a Phase that is not in `state.yaml` is not done, however eloquently the AI reports otherwise.
- **Recovery is a first-class citizen** - `handoff.md` is a protocol, not a scratchpad.

Full eight principles, three invariants, failure model, and mitigation mapping: [references/methodology.md](./references/methodology.md).

## When to use

**Use it for**: 0-to-1 product builds, framework/SDK migrations, major version upgrades, architecture replacements, long-form documentation projects, compliance remediation, long-pipeline ETL rebuilds.

**Do not use it for**: single small fixes (too heavy); exploratory research (Phase boundaries cannot be predefined - use a ReAct-style loop instead); stretches where requirements are still unstable and Phases get rewritten repeatedly (stabilize requirements first).

## Prerequisites

- The target repo is a Git worktree (`git rev-parse --is-inside-work-tree` returns `true`). Outside a Git workspace there is no objective basis for Phase-level whitelist diffing or rollback; this is blocked by default. Explicit opt-out only: `PHASE_CONTRACT_ALLOW_NON_GIT=1`.
- `ruby` 2.6 or newer is available locally. `planctl` is a single-file Ruby script with zero gem dependencies.

## Quick start

When used as an Agent Skill, just say "plan XXX with Phase-Contract" inside Copilot / Claude Code / Codex. The Skill interactively collects project framing, Phase decomposition, and hard constraints, then generates the full artifact set following the Procedure in [SKILL.md](./SKILL.md):

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

For manual installation into an existing project, copy `scripts/planctl.rb` in and generate the rest from the templates - details in [SKILL.md](./SKILL.md).

Only the current Phase needs a formal contract on day one. Future Phases can stay as placeholder pairs until entry, then be promoted when `next --strict` reaches them.

## Roadmap

From "no amnesia" (today) toward "no rot" (12-hour autonomy), in priority order:

1. **Machine-verifiable completion gates** (P0) - let `execution` declare build / lint / test / diff gates; `complete` runs them first and refuses to write state on red.
2. **Git-level checkpoints and rollback** (P0) - auto-branch and tag each Phase; `complete` merges on green, resets on red; support per-Phase rollback instead of rerunning the whole chain.
3. **Meta-Phase Replan** (P1) - force a replanning Phase every N execution Phases; manifest edits go through `planctl amend` for an audit trail.
4. **Contract DAG with parallel execution** (P1) - `next --parallel N` plus Git worktrees; compress a 12 h sequential plan into 6-8 h.
5. **Targeted context retrieval** (P2) - `planctl context <phase>` pulls relevant excerpts from completed artifacts; forbid the AI from free-form grep.
6. **Budgets, health, circuit breakers** (P2) - token / time / retry budgets; escalate to a human on repeated failure.

The evolutionary motto stays the same: **replace "AI self-discipline" with "script enforcement".**

## Documentation map

- [SKILL.md](./SKILL.md) - full scaffolding procedure and quality gates
- [references/glossary.md](./references/glossary.md) - glossary of concepts and terms (contract chain, three invariants, four failure modes, scheduler commands, adjacent-concept comparison)
- [references/methodology.md](./references/methodology.md) - complete methodology (three invariants, eight principles, enforcement layer, hard constraints)
- [references/templates.md](./references/templates.md) - `manifest` / `common` / `state` / `handoff` templates
- [references/phase-templates.md](./references/phase-templates.md) - two-layer contract templates (positioning + execution)
- [references/workflow-template.md](./references/workflow-template.md) - `plan/workflow.md` template, rollback and close-out flows
- [references/agent-instructions-template.md](./references/agent-instructions-template.md) - shared template for the three Agent instruction files
- [assets/README.md](./assets/README.md) - logo / mark assets and design rationale
- [CHANGELOG.md](./CHANGELOG.md) - version history

## License

Shares the license of the parent Agent Skill library. `scripts/planctl.rb` has no external dependencies and can be copied out and reused standalone.

<div align="center">

[English](./README.md) · [中文](./README.zh-CN.md)

</div>
