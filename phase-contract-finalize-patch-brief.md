# Phase-Contract Workflow Finalize Patch Brief

## Title

Make `finalize` the true last step of the phase-contract workflow: on first successful run it should write the finalization ledger and auto commit/push; on repeated runs it must stay read-only.

## Background

Current workflow behavior is inconsistent:

- `complete` already writes `plan/state.yaml` and `plan/handoff.md`, then records a git milestone via commit/push.
- `finalize` only prints the final dashboard and recommendations.

That means each phase completion is auditable in git, but the final plan completion is not. The goal of this patch is to close that gap.

## Scope

This patch is for workflow infrastructure only. Do not change product/business code or phase ordering.

Files that must be updated:

- `scripts/planctl`
- `plan/workflow.md`
- `.github/copilot-instructions.md`
- `CLAUDE.md`
- `AGENTS.md`

Important constraint:

- `.github/copilot-instructions.md`, `CLAUDE.md`, and `AGENTS.md` must remain byte-identical.

## Target Behavior

When all manifest phases are complete, the first successful execution of:

```bash
ruby scripts/planctl finalize
```

must do the following in order:

1. Verify all phases are complete, keeping the existing precondition checks.
2. Write `finalized_at` into `plan/state.yaml`.
3. Refresh `plan/handoff.md`.
4. Execute the final git close-out:
   - `git add -A`
   - `git commit -F -`
   - `git push`
5. Print the final execution dashboard.

If commit or push fails:

- print warnings only
- do not roll back `finalized_at`
- do not roll back `plan/state.yaml`
- do not roll back `plan/handoff.md`

If `finalized_at` already exists, repeated `finalize` runs must be read-only:

- do not rewrite the ledger
- do not create another commit
- do not push again
- only regenerate the dashboard

## Required Script Changes

### 1. Update `finalize(format:)`

In `scripts/planctl`, insert a finalize-ledger write step before building the dashboard payload.

Suggested flow:

- load state
- verify no phases remain
- call a helper like `write_finalize_ledger_if_needed!(state)`
- build dashboard from the returned state
- render dashboard as text or json

### 2. Add a finalize ledger helper

Add a helper with semantics equivalent to:

- read `state['finalized_at']`
- if present and non-empty, return the current state unchanged
- otherwise:
  - generate a UTC ISO8601 timestamp
  - write `state['finalized_at'] = timestamp`
  - write `state['updated_at'] = timestamp`
  - persist state via existing `write_state`
  - refresh handoff via existing `write_handoff_file`
  - trigger finalization commit/push helper

### 3. Add a finalization commit/push helper

Implement a helper dedicated to finalization git handling. It should mirror the existing milestone flow used by `complete`, but for the whole-plan close-out.

Required behavior:

- honor `PHASE_CONTRACT_SKIP_COMMIT=1`
- honor `PHASE_CONTRACT_SKIP_PUSH=1`
- use `git add -A`
- if nothing is staged, print a no-op message and return
- if commit fails, print warnings only
- if push fails, print warnings only
- if no upstream exists, fall back to `git push -u <remote> HEAD`
- if no remote exists, keep the local commit and warn

### 4. Add a finalization commit message builder

Recommended commit message shape:

- Subject: `chore(plan): finalize <project> execution`
- Body: explain that the finalization ledger was recorded after all phases completed
- Trailers:
  - `Finalized-At: <timestamp>`
  - `Automated-By: scripts/planctl finalize`

### 5. Surface `finalized_at` in outputs

The following outputs must include the finalization timestamp:

- handoff snapshot
- handoff markdown
- final dashboard payload
- final dashboard text render

## Required Documentation Changes

Update `plan/workflow.md` so the Finalization section states clearly:

1. On the first successful run, `finalize` will:
   - write `finalized_at`
   - refresh `plan/handoff.md`
   - auto commit/push the finalization ledger
2. Only after that does it print the final execution dashboard.
3. Repeated `finalize` runs are read-only if `finalized_at` already exists.
4. Even though `finalize` now commits and pushes, AI still must not make human release/archive decisions automatically.

## Required Agent Instruction Changes

Update all three files below and keep them byte-identical:

- `.github/copilot-instructions.md`
- `CLAUDE.md`
- `AGENTS.md`

The Finalization section must say:

1. First successful `finalize` run:
   - writes `plan/state.yaml.finalized_at`
   - refreshes `plan/handoff.md`
   - runs `git add -A` -> `git commit -F -` -> `git push`
   - leaves ledger intact if commit/push fails
2. Repeated `finalize` runs:
   - are read-only once `finalized_at` exists
   - do not rewrite ledger
   - do not commit again
   - do not push again

## Out of Scope

Do not change:

- `plan/manifest.yaml`
- phase ordering
- business/product code
- phase execution contracts unrelated to finalization behavior

If this patch is applied back to a template or skill repository, do not bake project-specific `plan/state.yaml` or `plan/handoff.md` instance content into the template.

## Validation Checklist

### Syntax check

```bash
ruby -c scripts/planctl
```

### First finalize run

Using a repository whose manifest phases are all complete but which does not yet have `finalized_at`:

```bash
ruby scripts/planctl finalize
```

Expected:

- `plan/state.yaml` gains `finalized_at`
- `plan/handoff.md` is refreshed
- a finalization commit is created
- if a remote exists, it is pushed automatically
- dashboard shows `Finalized at`

### Repeated finalize run

Run again:

```bash
ruby scripts/planctl finalize
```

Expected:

- no new commit
- no second push
- dashboard still renders
- behavior is read-only

### Agent instruction parity

```bash
shasum -a 256 .github/copilot-instructions.md CLAUDE.md AGENTS.md
```

Expected:

- all three hashes are identical

## Suggested Commit Strategy

If split into two commits:

1. implement `scripts/planctl` finalization ledger + auto commit/push + idempotent reruns
2. sync `plan/workflow.md` and the three agent instruction files

If done as one commit, script and docs must still land together.

## One-Line Summary

This patch upgrades `finalize` from a read-only reporting step into the true final workflow step: first run records the finalization ledger and auto commit/pushes it; later reruns remain read-only.
