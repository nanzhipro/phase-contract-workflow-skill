# phase-contract-workflow Changelog

## Unreleased

### Added

- Placeholder-contract enforcement for the current phase. `planctl next`,
  `resolve`, `status`, `resume`, and `doctor` now treat a phase as not
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
- `planctl resume [--strict]` — one-shot cold-start command for
  context-compressed or fresh sessions. Prints the project header,
  handoff snapshot, and a full `next` resolution (required_context,
  read_order, prompt) without requiring the agent to reconstruct the
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
  scripts/planctl next --format prompt --strict` hint at the end of a
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

- Introduced a formal placeholder-contract protocol in
  `references/phase-templates.md`, including the machine-readable
  `PHASE_CONTRACT_PLACEHOLDER` sentinel, paired future-phase stubs, and the
  rule that both contracts must be promoted together before implementation.
- `SKILL.md`, `references/workflow-template.md`, and
  `references/agent-instructions-template.md` now define the same Golden
  Loop boundary behavior: after `complete`, immediately rerun
  `next --strict`; if the new current phase is placeholder-only, upgrade
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
  follow-up `planctl next --strict`.
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
