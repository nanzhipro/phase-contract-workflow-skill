# phase-contract-workflow Changelog

## Unreleased

### Added

- `planctl lint-contracts [--phase <phase-id> | --all]` — machine lint for
  phase contracts. It validates the effective three-file context law
  (`common + phase + execution`), required marker sections
  (`PHASE_CONTRACT:FACT_AUDIT`, `:PRODUCTION_WIRING`,
  `:RUNTIME_EVIDENCE`, `:FAILURE_MODES`), non-empty `allowed_paths`,
  current-phase placeholder promotion rules, and the presence of at least
  one required check when `execution_rule.require_phase_checks: true` is
  enabled.
- End-to-end completion quality gates for `planctl complete`. Before any
  state write, `complete` now executes dependency validation,
  `lint-contracts`, manifest-declared required checks, and strict
  `allowed_paths` verification. Required failures and timeouts abort with
  exit 2 and leave `plan/state.yaml`, `plan/handoff.md`, commit, and push
  untouched. Optional check failures only warn.
- Phase completion logs now persist check summaries in
  `completion_log[*].checks`, including each check's `id`, `command`,
  `exit_code`, `duration_seconds`, `status`, and truncated `output_tail`.
- `planctl doctor` now lint-checks the current phase contract in addition
  to the existing manifest/state/agent-instruction integrity checks.
- `tests/planctl_quality_gates_test.rb` — regression coverage for required
  check success/failure, optional warning-only checks, timeouts,
  `require_phase_checks`, contract-marker linting, strict `allowed_paths`,
  completion-log check summaries, and doctor integration.

- `planctl advance [--format prompt|json] [--strict]` — autonomous
  continuation state machine. It emits `ACTION: implement`,
  `ACTION: promote_placeholder`, `ACTION: finalize`, or `ACTION: stop` so
  phase boundaries stop behaving like user confirmation points. In
  `--strict`, placeholder contracts remain an internal action with exit 0;
  only real blockers such as missing dependencies or missing context exit 2.
- `planctl complete ... --continue` — after state/handoff writeback and
  milestone handling, immediately chains into `advance --strict`. Projects
  can also set `execution_rule.continuation.mode: autonomous` so `complete`
  auto-advances even if `--continue` is omitted.

- `planctl finalize [--format text|json]` — explicit whole-plan wrap-up.
  Refuses to run (exit 2) until every manifest phase is in
  `state.yaml.completed_phases`; on the first successful run it now records
  `state.yaml.finalized_at`, refreshes `plan/handoff.md`, auto-commits the
  finalization ledger, and attempts a best-effort push before aggregating project metadata,
  per-phase ledger (with `Phase-Id:` milestone commit lookup), repository
  state (branch, upstream, ahead/behind, working tree, remotes, last
  commit), doctor-style health checks, and a tailored "human next steps"
  checklist into a single dashboard. Repeated `finalize` runs become read-only once
  `finalized_at` exists. `complete`, `advance`, `next`, and `resume` now
  point at `finalize` as the mandatory final step instead of stopping at
  "All phases are completed". Agent instruction template gains §12
  Finalization rule binding the AI to run `finalize`, layer deep review
  on top, and surface decision points (release tag, archiving `plan/`,
  long-term maintenance) back to the human without auto-executing them.

- Placeholder-contract enforcement for the current phase. `planctl advance`,
  `next`, `resolve`, `status`, `resume`, and `doctor` now treat a phase as not
  ready when its `plan_file` / `execution_file` still carry
  `PHASE_CONTRACT_PLACEHOLDER` (or legacy placeholder phrasing in the file
  header). In `--strict`, this exits 2 and tells the agent to upgrade both
  contracts before implementation.

- `planctl revert <phase-id> [--mode revert|reset] [--summary TEXT]`
  — rolls a completed phase back by locating its milestone commit, running
  either `git revert` (default, safe to push) or `git reset --hard`
  (history-rewriting, left unpushed for manual `--force-with-lease`), and
  rewriting `state.yaml` + `plan/handoff.md`. Refuses to revert a phase
  that still has completed downstream dependencies.
- `planctl reset` — rewinds the entire workflow to its origin. If planctl
  milestone / finalize / revert commits exist, it hard-resets to the
  parent of the oldest such commit so `advance --strict` resolves phase-0
  again. If no planctl commit exists yet, it restores tracked files to the
  current `HEAD` baseline and removes untracked workflow ledger files.
- `planctl resume [--strict]` — one-shot cold-start command for
  context-compressed or fresh sessions. Prints the project header,
  handoff snapshot, and the same autonomous `advance` ACTION used by the
  normal Golden Loop, without requiring the agent to reconstruct the
  reading order by hand.
- `planctl doctor` — repository health check. Validates Ruby version,
  `git` work-tree / remotes, manifest `plan_file` / `execution_file`
  existence, state vs handoff coherence, and SHA256 byte-identity of
  the three agent instruction files (`.github/copilot-instructions.md`,
  `CLAUDE.md`, `AGENTS.md`). Exits 2 when any problem is found.
- Pre-write `allowed_paths` enforcement. `complete` now runs
  `git add -A && git diff --cached --name-only` and matches each staged
  path against the phase's `allowed_paths:` globs (plus the always-allowed
  `plan/state.yaml` / `plan/handoff.md`). When strict mode is active
  (`execution_rule.enforce_allowed_paths: true` in `manifest.yaml` or
  `PHASE_CONTRACT_ENFORCE_PATHS=1`), any off-scope path aborts the
  command **before** `state.yaml` is updated, so the ledger never gets
  ahead of the git history. Warn-only mode (default) simply prints the
  offenders.
- `plan/state.yaml` now carries `version: 1`. `load_state` refuses to
  operate on a state file declaring a schema version newer than the
  script understands and hints the user to upgrade `planctl` first.
  Missing `version:` is tolerated so legacy state files keep working.
- `complete` now prints a `Next phase: <id> (<title>). Run: ruby
  scripts/planctl advance --strict` hint at the end of a
  successful run (or `All phases are completed. No remaining work.`
  when none remain), so a fresh session does not have to re-derive the
  next step from the manifest.
- `complete` now rejects blank `--summary` with exit 2 and soft-warns
  when the first line exceeds 120 chars.
- `complete` now also rejects blank `--next-focus` with exit 2. An
  empty next-focus wastes the primary resumption hint rendered into
  `plan/handoff.md` and the next phase's resume prompt.
- `write_state` and `write_handoff_file` now use atomic `tmp + rename`
  writes (with best-effort `fsync`). An interruption mid-write can no
  longer leave `state.yaml` half-written or desynchronized from
  `handoff.md`.

### Fixed

- `planctl status` no longer raises `NameError: undefined local variable
  'blocked'` when printing blocked-phase information.
- Downgraded the `planctl doctor` Ruby version check from hard error to
  warning, so systems still on Ruby 2.6 keep working while being nudged
  to upgrade.

### Documentation

- `SKILL.md`, `README.md`, `README.zh-CN.md`,
  `references/phase-templates.md`, `references/templates.md`,
  `references/workflow-template.md`, and
  `references/agent-instructions-template.md` now describe the new
  end-to-end integrity contract: Fact Audit, Production Wiring,
  Runtime Evidence, Failure Modes, Component Adoption Table,
  `lint-contracts`, manifest `checks.required/optional`, and the rule that
  required gates must pass before `state.yaml` may advance.

- `README.md`, `README.zh-CN.md`, `SKILL.md`,
  `references/templates.md`, `references/workflow-template.md`,
  `references/methodology.md`, `references/glossary.md`, and
  `references/agent-instructions-template.md` now describe `advance` as the
  default Golden Loop entry and `complete --continue` as the normal phase
  completion command.
- Introduced a formal placeholder-contract protocol in
  `references/phase-templates.md`, including the machine-readable
  `PHASE_CONTRACT_PLACEHOLDER` sentinel, paired future-phase stubs, and the
  rule that both contracts must be promoted together before implementation.
- `SKILL.md`, `references/workflow-template.md`, and
  `references/agent-instructions-template.md` now define the same Golden
  Loop boundary behavior: after `complete --continue`, follow the
  `advance` ACTION; if the new current phase is placeholder-only, upgrade
  both contracts first instead of asking the user for confirmation.
- `references/methodology.md`, `README.md`, and `README.zh-CN.md` now say
  the same thing about phase boundaries and clarify that
  `planctl handoff --write` is a manual recovery tool, not a normal
  follow-up step after every `complete`.

- `references/methodology.md` §9 now declares 10 hard constraints, with
  a new rule forbidding agents from running `git commit` / `git push` /
  `git tag` during phase execution — milestone commit authority is
  exclusively `planctl complete`.
- `references/templates.md` documents the new optional
  `phases[].allowed_paths:` manifest field and the top-level
  `execution_rule.enforce_allowed_paths:` strict-mode switch.
- `references/workflow-template.md` now includes a "如何回退一个 Phase"
  section covering `--mode revert` vs `--mode reset` and the expected
  follow-up `planctl advance --strict`.
- `references/agent-instructions-template.md` §八 adds rule #10 requiring
  all phase rollbacks to go through `planctl revert`, never manual
  `git revert` / `git reset` / manual `state.yaml` edits; and clarifies
  that `complete` already refreshes `handoff.md` atomically so
  `handoff --write` is a manual recovery tool, not a required follow-up.
- `SKILL.md` Quality Gate references "10 条硬约束", Decision Points
  gained dedicated entries for revert, allowed_paths enforcement,
  cold-start resume, and repo doctor; Prerequisites now lists Ruby
  ≥ 2.6 alongside the git work-tree check; Golden Loop no longer
  tells users to run `handoff --write` after every `complete`.
- `README.md` seven principles block was promoted to eight principles
  (P1→P8, adding milestone externalization) and the enforcement-layer
  bullet list was updated to forbid in-phase `git commit/push/tag`
  and mention the single-step `planctl resume --strict` path.
