#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'pathname'
require 'time'
require 'yaml'

class PlanCtl
  GIT_OPT_OUT_ENV = 'PHASE_CONTRACT_ALLOW_NON_GIT'
  SKIP_PUSH_ENV = 'PHASE_CONTRACT_SKIP_PUSH'
  SKIP_COMMIT_ENV = 'PHASE_CONTRACT_SKIP_COMMIT'
  ENFORCE_PATHS_ENV = 'PHASE_CONTRACT_ENFORCE_PATHS'
  GIT_GUARD_EXIT_CODE = 3
  ALWAYS_ALLOWED_PATHS = %w[plan/state.yaml plan/handoff.md .gitignore].freeze
  STATE_SCHEMA_VERSION = 1

  def initialize(repo_root)
    @repo_root = Pathname.new(repo_root)
    @manifest_path = @repo_root.join('plan', 'manifest.yaml')
    @manifest = load_yaml(@manifest_path)
  end

  def resolve(phase_id, format:, strict:)
    ensure_git_repo!
    result = build_resolve_result(fetch_phase(phase_id), load_state)

    render_resolve(result, format)
    exit(2) if strict && !result['ready']
  end

  def next_phase(format:, strict:)
    ensure_git_repo!
    state = load_state
    phase = first_remaining_phase(Array(state['completed_phases']))

    unless phase
      render_no_remaining_phases(format)
      return
    end

    result = build_resolve_result(phase, state)
    render_resolve(result, format)
    exit(2) if strict && !result['ready']
  end

  def status(format:)
    warn_if_not_git_repo
    result = build_status_result(load_state)

    case format
    when 'json'
      puts JSON.pretty_generate(result)
    else
      puts 'Phase-Contract plan state'
      puts "State file: #{result['state_file']}"
      puts "Handoff file: #{result['handoff_file']}"
      puts
      puts "Completed phases: #{result['completed_phases'].empty? ? 'none' : result['completed_phases'].join(', ')}"
      puts
      if result['next_phase']
        puts "Next phase: #{result['next_phase']['phase_id']} #{result['next_phase']['title']}"
      else
        puts 'Next phase: none'
      end
      puts
      puts 'Available phases:'
      if result['available_phases'].empty?
        puts '- none'
      else
        result['available_phases'].each do |phase|
          puts "- #{phase['phase_id']}: #{phase['title']}"
        end
      end
      puts
      puts 'Blocked phases:'
      if result['blocked_phases'].empty?
        puts '- none'
      else
        result['blocked_phases'].each do |phase|
          puts "- #{phase['phase_id']}: waiting for #{phase['missing_dependencies'].join(', ')}"
        end
      end
      puts
      puts 'Remaining queue:'
      if result['remaining_queue'].empty?
        puts '- none'
      else
        result['remaining_queue'].each do |phase|
          detail = phase['missing_dependencies'].empty? ? phase['status'] : "#{phase['status']} (waiting for #{phase['missing_dependencies'].join(', ')})"
          puts "- #{phase['phase_id']}: #{phase['title']} [#{detail}]"
        end
      end
    end
  end

  def complete(phase_id, summary:, next_focus:)
    ensure_git_repo!
    if blank?(summary)
      warn "Cannot complete #{phase_id}: --summary is required and must be non-empty."
      warn "Summaries become the commit subject and the handoff ledger; a blank summary leaves the next session blind."
      exit 2
    end
    if blank?(next_focus)
      warn "Cannot complete #{phase_id}: --next-focus is required and must be non-empty."
      warn "Next-focus seeds the handoff and the next phase's resume prompt; an empty value wastes the primary resumption hint."
      exit 2
    end
    if summary.lines.first.to_s.strip.length > 120
      warn "[planctl] warning: summary first line exceeds 120 chars; commit subject will be long. Consider tightening."
    end
    phase = fetch_phase(phase_id)
    state = load_state(create_if_missing: true)
    completed = Array(state['completed_phases'])
    missing_dependencies = Array(phase['depends_on']) - completed

    unless missing_dependencies.empty?
      warn "Cannot complete #{phase_id}. Missing dependencies: #{missing_dependencies.join(', ')}"
      exit 2
    end

    if completed.include?(phase_id)
      puts "Phase already completed: #{phase_id}"
      return
    end

    # Pre-flight allowed_paths enforcement. Runs BEFORE any state write so a
    # strict violation aborts cleanly without leaving the ledger ahead of
    # the git history. Works best-effort when git is disabled — enforcement
    # simply no-ops because we can't diff.
    unless precheck_allowed_paths!(phase)
      exit 2
    end

    completed << phase_id
    ordered = manifest_phases.map { |entry| entry['id'] }.select { |id| completed.include?(id) }
    completion_log = Array(state['completion_log'])
    timestamp = Time.now.utc.iso8601
    completion_entry = {
      'phase_id' => phase_id,
      'completed_at' => timestamp
    }
    completion_entry['summary'] = summary unless blank?(summary)
    completion_entry['next_focus'] = next_focus unless blank?(next_focus)
    completion_log << completion_entry

    new_state = state.merge(
      'version' => state['version'] || STATE_SCHEMA_VERSION,
      'completed_phases' => ordered,
      'completion_log' => completion_log,
      'updated_at' => timestamp
    )

    write_state(new_state)
    write_handoff_file(new_state)
    puts "Marked complete: #{phase_id}"
    puts "Updated state file: #{state_file_relative}"
    puts "Updated handoff file: #{handoff_file_relative}"

    commit_and_push_milestone!(phase_id, phase['title'], summary, next_focus)

    # Hint the agent toward the next Golden-Loop step so a fresh session
    # does not have to re-derive it from the manifest.
    next_phase = first_remaining_phase(ordered)
    if next_phase
      puts "Next phase: #{next_phase['id']} (#{next_phase['title']}). Run: ruby scripts/planctl next --format prompt --strict"
    else
      puts 'All phases are completed. No remaining work.'
    end
  end

  # Revert a previously completed phase:
  #   1. Locate its milestone commit via `git log --grep "Phase-Id: <id>"`.
  #   2. Either `git revert` (default, safe) or `git reset --hard` that commit.
  #   3. Remove the phase from completed_phases and append a reverted_at
  #      entry to completion_log so the ledger reflects reality.
  #   4. Rewrite state.yaml + handoff.md, then push the new history.
  # The phase itself is NOT marked "to redo" — if you want to redo it, run
  # `planctl next --strict` afterwards; the dependency graph will put it
  # back on the queue.
  def revert(phase_id, mode:, summary:)
    ensure_git_repo!
    phase = fetch_phase(phase_id)
    state = load_state
    completed = Array(state['completed_phases'])

    unless completed.include?(phase_id)
      warn "Cannot revert #{phase_id}: it is not in completed_phases."
      exit 2
    end

    dependents = manifest_phases.select do |candidate|
      Array(candidate['depends_on']).include?(phase_id) && completed.include?(candidate['id'])
    end
    unless dependents.empty?
      warn "Cannot revert #{phase_id}: the following completed phases depend on it — #{dependents.map { |d| d['id'] }.join(', ')}."
      warn '[planctl] Revert the dependents first (in reverse order), then revert this phase.'
      exit 2
    end

    unless %w[revert reset].include?(mode)
      warn "Unknown --mode #{mode.inspect}; use 'revert' or 'reset'."
      exit 1
    end

    commit_sha = find_milestone_commit(phase_id)
    if commit_sha.nil? || commit_sha.empty?
      warn "[planctl] No milestone commit found for #{phase_id} (searched git log for `Phase-Id: #{phase_id}` trailer)."
      warn '[planctl] state.yaml will still be rolled back, but no git history change is performed. You must reconcile manually.'
    else
      case mode
      when 'revert'
        unless run_git('revert', '--no-edit', commit_sha)
          warn "[planctl] git revert #{commit_sha} failed; resolve conflicts or abort, then retry."
          exit 2
        end
        puts "[planctl] Reverted milestone commit #{commit_sha[0, 10]} for #{phase_id}."
      when 'reset'
        unless run_git('reset', '--hard', "#{commit_sha}^")
          warn "[planctl] git reset --hard #{commit_sha}^ failed."
          exit 2
        end
        puts "[planctl] Hard-reset past milestone commit #{commit_sha[0, 10]} for #{phase_id}. History rewritten."
      end
    end

    timestamp = Time.now.utc.iso8601
    new_completed = completed.reject { |id| id == phase_id }
    completion_log = Array(state['completion_log'])
    revert_entry = {
      'phase_id' => phase_id,
      'reverted_at' => timestamp,
      'mode' => mode
    }
    revert_entry['summary'] = summary unless blank?(summary)
    revert_entry['commit'] = commit_sha if commit_sha && !commit_sha.empty?
    completion_log << revert_entry

    new_state = state.merge(
      'version' => state['version'] || STATE_SCHEMA_VERSION,
      'completed_phases' => new_completed,
      'completion_log' => completion_log,
      'updated_at' => timestamp
    )

    write_state(new_state)
    write_handoff_file(new_state)
    puts "Marked reverted: #{phase_id}"
    puts "Updated state file: #{state_file_relative}"
    puts "Updated handoff file: #{handoff_file_relative}"

    commit_and_push_revert!(phase_id, phase['title'], mode, commit_sha, summary)
  end

  def find_milestone_commit(phase_id)
    out = capture_git('log', '--format=%H', "--grep=^Phase-Id: #{phase_id}$", '-E', '--max-count=1')
    out.strip.split("\n").first
  end

  def commit_and_push_revert!(phase_id, title, mode, commit_sha, summary)
    return if git_opt_out?
    return unless git_work_tree?
    return if env_truthy?(SKIP_COMMIT_ENV)

    unless run_git('add', '-A')
      warn '[planctl] git add -A failed; revert ledger not committed.'
      return
    end

    if run_git('diff', '--cached', '--quiet')
      puts "[planctl] Nothing to commit after revert (#{phase_id})."
    else
      subject_base = title && !title.strip.empty? ? title.strip : phase_id
      subject = "chore(plan): revert #{phase_id} — #{subject_base}"
      subject = subject[0, 100] if subject.length > 100
      body = summary && !summary.strip.empty? ? summary.strip : 'Phase rolled back via planctl revert.'
      lines = [subject, '', body, '', "Phase-Id: #{phase_id}", "Revert-Mode: #{mode}"]
      lines << "Reverted-Commit: #{commit_sha}" if commit_sha && !commit_sha.empty?
      lines << 'Automated-By: scripts/planctl revert'
      message = lines.join("\n") + "\n"
      unless run_git_with_stdin(message, 'commit', '-F', '-')
        warn "[planctl] git commit failed after revert of #{phase_id}; state is rolled back but no ledger commit was recorded."
        return
      end
      puts "[planctl] Committed revert ledger: #{phase_id}"
    end

    return if env_truthy?(SKIP_PUSH_ENV)

    if mode == 'reset'
      warn '[planctl] --mode reset rewrote history; skipping automatic push.'
      warn '[planctl] If this branch has no remote collaborators, push manually with: git push --force-with-lease'
      return
    end

    push_milestone!(phase_id)
  end

  def handoff(format:, write:)
    ensure_git_repo!
    state = load_state(create_if_missing: write)
    snapshot = build_handoff_snapshot(state)

    write_handoff_file(state, snapshot) if write
    render_handoff(snapshot, format)
    puts "Updated handoff file: #{handoff_file_relative}" if write && format != 'json'
  end

  # Cold-start macro: prints everything an AI agent needs to resume work
  # after a compression / fresh session. Combines manifest overview,
  # handoff snapshot, and the `next` resolve result in one shot so the
  # agent does not have to orchestrate multiple calls.
  def resume(strict:)
    warn_if_not_git_repo
    state = load_state
    snapshot = build_handoff_snapshot(state)

    puts '=== Phase-Contract Resume ==='
    puts "Project: #{@manifest['project'] || '(unnamed)'}"
    puts "Repository: #{@repo_root}"
    puts "State file: #{snapshot['state_file']}"
    puts "Handoff file: #{snapshot['handoff_file']}"
    puts "Updated at: #{snapshot['updated_at'] || 'not recorded yet'}"
    puts
    puts "Read these files first (compression-safe resume order):"
    snapshot['resume_read_order'].each_with_index { |p, i| puts "  #{i + 1}. #{p}" }
    puts
    puts "--- Handoff snapshot ---"
    render_handoff(snapshot, 'prompt')
    puts
    puts "--- Next phase ---"
    phase = snapshot['next_phase'] && fetch_phase(snapshot['next_phase']['phase_id'])
    if phase
      result = build_resolve_result(phase, state)
      render_resolve(result, 'prompt')
      exit(2) if strict && !result['ready']
    else
      puts 'All phases are completed. Nothing to resume.'
    end
  end

  # Repository integrity checker. Returns exit 0 when healthy, 2 when
  # critical problems found, and prints a structured report either way.
  # Checks:
  #   * Ruby runtime version (>= 2.7)
  #   * git work tree + optional remote
  #   * manifest phases -> plan_file / execution_file exist
  #   * state.yaml completed_phases -> each id exists in manifest
  #   * state.yaml <-> handoff.md coherence (both exist or both missing)
  #   * Three agent instruction files identical SHA256:
  #       .github/copilot-instructions.md, CLAUDE.md, AGENTS.md
  def doctor
    require 'digest'
    problems = []
    warnings = []

    puts '=== Phase-Contract Doctor ==='
    puts "Ruby: #{RUBY_VERSION}"
    ruby_major, ruby_minor = RUBY_VERSION.split('.').first(2).map(&:to_i)
    if ruby_major < 2 || (ruby_major == 2 && ruby_minor < 6)
      warnings << "Ruby #{RUBY_VERSION} is older than 2.6; upgrade if you see YAML.safe_load errors."
    end

    if git_work_tree?
      puts 'Git work tree: ok'
      remotes = capture_git('remote').split("\n").reject(&:empty?)
      if remotes.empty?
        warnings << 'No git remote configured; `complete` will commit locally, skip push, and continue.'
      else
        puts "Git remotes: #{remotes.join(', ')}"
      end
    else
      problems << "#{@repo_root} is not a git work tree."
    end

    manifest_phases.each do |phase|
      %w[plan_file execution_file].each do |key|
        path = phase[key]
        if path.nil? || path.empty?
          problems << "manifest phase #{phase['id']} missing #{key}."
        elsif !@repo_root.join(path).file?
          problems << "manifest phase #{phase['id']}: #{key} #{path} does not exist."
        end
      end
    end

    state_path = state_file_path
    handoff_path = handoff_file_path
    if state_path.file?
      state = load_state
      known_ids = manifest_phases.map { |p| p['id'] }
      Array(state['completed_phases']).each do |id|
        problems << "state.yaml lists completed phase #{id}, which is not in manifest." unless known_ids.include?(id)
      end
      warnings << 'state.yaml exists but plan/handoff.md is missing; run `planctl handoff --write`.' unless handoff_path.file?
    else
      warnings << 'state.yaml not created yet; run `planctl next --strict` or complete a phase.' if handoff_path.file?
    end

    instruction_files = %w[.github/copilot-instructions.md CLAUDE.md AGENTS.md]
    existing = instruction_files.select { |p| @repo_root.join(p).file? }
    if existing.empty?
      warnings << 'No agent instruction files found (.github/copilot-instructions.md, CLAUDE.md, AGENTS.md).'
    elsif existing.length < instruction_files.length
      missing = instruction_files - existing
      warnings << "Agent instruction file(s) missing: #{missing.join(', ')}."
    else
      hashes = existing.map { |p| [p, Digest::SHA256.hexdigest(@repo_root.join(p).read)] }
      unique = hashes.map(&:last).uniq
      if unique.length == 1
        puts "Agent instructions in sync: sha256=#{unique.first[0, 12]}"
      else
        problems << "Agent instruction files diverge (copilot/CLAUDE/AGENTS are not byte-identical): #{hashes.map { |p, h| "#{p}=#{h[0, 8]}" }.join(', ')}."
      end
    end

    puts
    if warnings.any?
      puts 'Warnings:'
      warnings.each { |w| puts "- #{w}" }
      puts
    end
    if problems.empty?
      puts 'All checks passed.'
    else
      puts 'Problems:'
      problems.each { |p| puts "- #{p}" }
      exit 2
    end
  end

  private

  def ensure_git_repo!
    return if git_opt_out?
    return if git_work_tree?

    warn git_guard_message
    exit GIT_GUARD_EXIT_CODE
  end

  def warn_if_not_git_repo
    return if git_opt_out?
    return if git_work_tree?

    warn '[planctl] warning: current directory is not a git work tree.'
    warn "[planctl] warning: `next` / `resolve` / `complete` / `handoff` will refuse to run (exit #{GIT_GUARD_EXIT_CODE}) until a git baseline exists."
    warn "[planctl] warning: see `plan/workflow.md` for the `git init` instructions or set #{GIT_OPT_OUT_ENV}=1 to opt out explicitly."
  end

  def git_opt_out?
    value = ENV[GIT_OPT_OUT_ENV]
    return false if value.nil? || value.empty?

    %w[1 true yes on].include?(value.downcase)
  end

  def git_work_tree?
    output = IO.popen(['git', '-C', @repo_root.to_s, 'rev-parse', '--is-inside-work-tree'], err: [:child, :out], &:read)
    $?.success? && output.strip == 'true'
  rescue Errno::ENOENT
    # git not installed — fall back to checking for a .git entry so the tool
    # remains usable on minimal environments, but warn the operator.
    warn '[planctl] warning: `git` executable not found; falling back to .git presence check.'
    @repo_root.join('.git').exist?
  end

  def git_guard_message
    lines = []
    lines << "[planctl] error: #{@repo_root} is not a git work tree."
    lines << '[planctl] Phase-Contract Workflow relies on git for phase-level whitelist diffing, rollback, and handoff verification.'
    lines << '[planctl] Without git, `complete` cannot be audited and any write to plan/state.yaml would be unverifiable.'
    lines << ''
    lines << 'Fix it with:'
    lines << "  cd #{@repo_root}"
    lines << '  git init'
    lines << '  git add -A'
    lines << "  git commit -m 'baseline'"
    lines << ''
    lines << "If this project intentionally does not use git, set #{GIT_OPT_OUT_ENV}=1 and record the deviation (with a rollback/audit plan) in plan/common.md."
    lines.join("\n")
  end

  # Automatically commit + push the current phase's work as a milestone.
  # Designed to run unattended:
  #   * `git add -A` stages every change under the work tree (phase output +
  #     state.yaml + handoff.md). If the AI updated `.gitignore` while
  #     reasoning about transient artifacts, that change is staged too.
  #   * When nothing is staged we skip commit silently.
  #   * Commit message follows a Conventional-Commits-ish layout with
  #     idiomatic English wording, derived from phase id, title, summary and
  #     next-focus. Nothing is translated - user-provided text is preserved
  #     inside the body.
  #   * `git push` targets the currently tracked upstream. If no upstream is
  #     configured we push to the default remote / current branch and fall
  #     back to `git push -u <remote> HEAD` so the first run also succeeds.
  #   * Hard failures (commit / push) are surfaced as warnings. State is
  #     already written, so the phase is still considered complete; the
  #     operator just needs to resolve the git issue manually.
  # Escape hatches (unattended-friendly):
  #   PHASE_CONTRACT_SKIP_COMMIT=1  -> skip commit and push entirely
  #   PHASE_CONTRACT_SKIP_PUSH=1    -> commit locally, skip push
  def commit_and_push_milestone!(phase_id, title, summary, next_focus)
    return if git_opt_out?
    return unless git_work_tree?

    if env_truthy?(SKIP_COMMIT_ENV)
      puts "[planctl] #{SKIP_COMMIT_ENV} is set; skipping auto-commit and auto-push."
      return
    end

    unless run_git('add', '-A')
      warn '[planctl] git add -A failed; milestone not committed. Resolve and commit manually.'
      return
    end

    # `git diff --cached --quiet` exits 0 when nothing is staged.
    if run_git('diff', '--cached', '--quiet')
      puts "[planctl] Nothing to commit for #{phase_id}; working tree already clean."
      return
    end

    message = build_commit_message(phase_id, title, summary, next_focus)
    unless run_git_with_stdin(message, 'commit', '-F', '-')
      warn "[planctl] git commit failed for #{phase_id}; state is marked complete but no milestone commit was recorded."
      warn '[planctl] Resolve the commit manually (hooks, signing, identity) and commit the pending changes.'
      return
    end
    puts "[planctl] Committed milestone: #{phase_id}"

    if env_truthy?(SKIP_PUSH_ENV)
      puts "[planctl] #{SKIP_PUSH_ENV} is set; skipping push. Milestone is stored locally only."
      return
    end

    push_milestone!(phase_id)
  end

  def push_milestone!(phase_id)
    remotes = capture_git('remote').split("\n").reject(&:empty?)
    if remotes.empty?
      warn '[planctl] No git remote configured; milestone committed locally only, skipping push and continuing.'
      warn "[planctl] Add a remote and run `git push` manually, or set #{SKIP_PUSH_ENV}=1 to silence this warning."
      return
    end

    # Prefer pushing to the tracked upstream (fast path for subsequent runs).
    return if run_git('push')

    # First push of a branch typically has no upstream. Fall back to an
    # explicit `push -u <remote> HEAD` against the first available remote
    # (usually `origin`) so the unattended flow still succeeds end to end.
    target_remote = remotes.include?('origin') ? 'origin' : remotes.first
    if run_git('push', '-u', target_remote, 'HEAD')
      puts "[planctl] Pushed milestone to #{target_remote} (set upstream)."
      return
    end

    warn "[planctl] git push failed for #{phase_id}; milestone is committed locally only."
    warn '[planctl] Resolve the push (auth, protected branch, diverged history) and push manually.'
  end

  def build_commit_message(phase_id, title, summary, next_focus)
    subject_base = title && !title.strip.empty? ? title.strip : phase_id
    subject = "chore(plan): complete #{phase_id} — #{subject_base}"
    subject = subject[0, 100] if subject.length > 100

    lines = [subject, '']
    body = summary && !summary.strip.empty? ? summary.strip : 'Milestone recorded by planctl after phase completion.'
    lines << body
    lines << ''
    lines << "Phase-Id: #{phase_id}"
    lines << "Next-Focus: #{next_focus.strip}" if next_focus && !next_focus.strip.empty?
    lines << 'Automated-By: scripts/planctl complete'
    lines.join("\n") + "\n"
  end

  # Pre-commit enforcement: stages every change via `git add -A` and
  # compares the staged paths against the phase's allowed_paths globs.
  # Returns true when safe to proceed, false when a hard violation should
  # abort. Default mode is "warn" (prints offending paths but returns
  # true). Set PHASE_CONTRACT_ENFORCE_PATHS=1 or
  # manifest.execution_rule.enforce_allowed_paths: true to switch to
  # abort-mode. No-op when git is disabled / not a work tree.
  def precheck_allowed_paths!(phase)
    return true if git_opt_out?
    return true unless git_work_tree?
    return true if env_truthy?(SKIP_COMMIT_ENV)

    allowed = Array(phase['allowed_paths'])
    return true if allowed.empty?

    unless run_git('add', '-A')
      warn '[planctl] git add -A failed during allowed_paths pre-check.'
      return true # don't block on git failure; let commit step surface it
    end

    staged = capture_git('diff', '--cached', '--name-only').split("\n").reject(&:empty?)
    return true if staged.empty?

    whitelist = (allowed + ALWAYS_ALLOWED_PATHS).uniq
    violations = staged.reject { |path| path_matches_any?(path, whitelist) }
    return true if violations.empty?

    enforce = env_truthy?(ENFORCE_PATHS_ENV) || @manifest.dig('execution_rule', 'enforce_allowed_paths')
    header = "[planctl] phase #{phase['id']} staged files outside allowed_paths:"
    if enforce
      warn header
      violations.each { |path| warn "  - #{path}" }
      warn '[planctl] aborting before state write. Either add the path to allowed_paths or unstage the file; state.yaml is unchanged.'
      false
    else
      warn header
      violations.each { |path| warn "  - #{path} (warning only; enable enforcement via #{ENFORCE_PATHS_ENV}=1 or manifest.execution_rule.enforce_allowed_paths: true)" }
      true
    end
  end

  def path_matches_any?(path, globs)
    globs.any? do |glob|
      File.fnmatch(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
        (glob.end_with?('/') && path.start_with?(glob)) ||
        File.fnmatch(File.join(glob, '**'), path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end
  end

  def run_git(*args)
    system('git', '-C', @repo_root.to_s, *args)
  end

  def run_git_with_stdin(stdin_text, *args)
    IO.popen(['git', '-C', @repo_root.to_s, *args], 'w') { |io| io.write(stdin_text) }
    $?.success?
  end

  def capture_git(*args)
    IO.popen(['git', '-C', @repo_root.to_s, *args], err: [:child, :out], &:read).to_s
  rescue Errno::ENOENT
    ''
  end

  def env_truthy?(name)
    value = ENV[name]
    return false if value.nil? || value.empty?

    %w[1 true yes on].include?(value.downcase)
  end

  def build_resolve_result(phase, state)
    completed = Array(state['completed_phases'])
    dependencies = Array(phase['depends_on'])
    missing_dependencies = dependencies - completed
    required_context = normalized_context_for(phase)
    missing_context_files = required_context.reject { |path| @repo_root.join(path).file? }

    {
      'phase_id' => phase['id'],
      'title' => phase['title'],
      'plan_file' => phase['plan_file'],
      'execution_file' => phase['execution_file'],
      'required_context' => required_context,
      'depends_on' => dependencies,
      'completed_dependencies' => dependencies & completed,
      'missing_dependencies' => missing_dependencies,
      'missing_context_files' => missing_context_files,
      'resolver' => @manifest.dig('execution_rule', 'resolver'),
      'state_file' => state_file_relative,
      'handoff_file' => handoff_file_relative,
      'ready' => missing_dependencies.empty? && missing_context_files.empty?
    }
  end

  def build_status_result(state)
    completed = Array(state['completed_phases'])
    phases = manifest_phases
    available = phases.select do |phase|
      !completed.include?(phase['id']) && (Array(phase['depends_on']) - completed).empty?
    end

    blocked = phases.each_with_object([]) do |phase, result|
      next if completed.include?(phase['id'])
      next if available.any? { |candidate| candidate['id'] == phase['id'] }

      result << {
        'phase_id' => phase['id'],
        'title' => phase['title'],
        'missing_dependencies' => Array(phase['depends_on']) - completed
      }
    end

    remaining_queue = phases.reject { |phase| completed.include?(phase['id']) }.map do |phase|
      missing_dependencies = Array(phase['depends_on']) - completed
      summarize_phase(phase).merge(
        'status' => missing_dependencies.empty? ? 'ready' : 'blocked',
        'missing_dependencies' => missing_dependencies
      )
    end

    {
      'completed_phases' => completed,
      'available_phases' => available.map { |phase| summarize_phase(phase) },
      'blocked_phases' => blocked,
      'remaining_queue' => remaining_queue,
      'next_phase' => remaining_queue.first,
      'state_file' => state_file_relative,
      'handoff_file' => handoff_file_relative
    }
  end

  def build_handoff_snapshot(state)
    status = build_status_result(state)
    next_phase = status['next_phase']
    next_required_context = if next_phase
                              normalized_context_for(fetch_phase(next_phase['phase_id']))
                            else
                              []
                            end

    {
      'state_file' => state_file_relative,
      'handoff_file' => handoff_file_relative,
      'updated_at' => state['updated_at'],
      'completed_phases' => status['completed_phases'],
      'recent_completions' => Array(state['completion_log']).last(compression_history_limit).map { |entry| decorate_completion_entry(entry) },
      'next_phase' => next_phase,
      'next_required_context' => next_required_context,
      'remaining_queue' => status['remaining_queue'],
      'resume_read_order' => resume_read_order,
      'compression_rules' => compression_rules,
      'continuous_execution' => @manifest.dig('execution_rule', 'continuous_execution') || {}
    }
  end

  def summarize_phase(phase)
    {
      'phase_id' => phase['id'],
      'title' => phase['title'],
      'plan_file' => phase['plan_file'],
      'execution_file' => phase['execution_file']
    }
  end

  def render_resolve(result, format)
    case format
    when 'json'
      puts JSON.pretty_generate(result)
    when 'paths'
      puts result['required_context'].join("\n")
    else
      puts 'Phase-Contract phase context'
      puts "Target phase: #{result['phase_id']} #{result['title']}"
      puts "Resolver: #{result['resolver']}"
      puts "State file: #{result['state_file']}"
      puts "Handoff file: #{result['handoff_file']}"
      puts
      puts 'Read these files in order before making changes:'
      result['required_context'].each_with_index do |path, index|
        puts "#{index + 1}. #{path}"
      end
      puts
      puts 'Dependency status:'
      puts "- depends_on: #{format_list(result['depends_on'])}"
      puts "- completed: #{format_list(result['completed_dependencies'])}"
      puts "- missing: #{format_list(result['missing_dependencies'])}"
      puts
      puts 'Context file status:'
      puts "- missing files: #{format_list(result['missing_context_files'])}"
      puts
      puts 'Execution contract:'
      puts '- Do not start implementation before reading every required_context file.'
      puts '- Treat plan/common.md as the global hard constraints.'
      puts '- Treat the execution file as the scope boundary, deliverable contract, and completion checklist.'
      puts '- If dependencies or required context files are missing, stop and report the blocker instead of editing files.'
      puts '- For long multi-phase runs, complete this phase with a summary and refresh plan/handoff.md before moving on.'
    end
  end

  def render_no_remaining_phases(format)
    result = {
      'complete' => true,
      'message' => 'All phases are completed.',
      'state_file' => state_file_relative,
      'handoff_file' => handoff_file_relative
    }

    case format
    when 'json'
      puts JSON.pretty_generate(result)
    else
      puts 'All phases are completed.'
      puts "State file: #{result['state_file']}"
      puts "Handoff file: #{result['handoff_file']}"
    end
  end

  def render_handoff(snapshot, format)
    case format
    when 'json'
      puts JSON.pretty_generate(snapshot)
    else
      puts 'Phase-Contract execution handoff'
      puts "State file: #{snapshot['state_file']}"
      puts "Handoff file: #{snapshot['handoff_file']}"
      puts "Updated at: #{snapshot['updated_at'] || 'not recorded yet'}"
      puts
      puts "Completed phases: #{snapshot['completed_phases'].empty? ? 'none' : snapshot['completed_phases'].join(', ')}"
      puts
      if snapshot['recent_completions'].empty?
        puts 'Recent completions: none'
      else
        puts 'Recent completions:'
        snapshot['recent_completions'].each do |entry|
          detail = entry['summary'] || 'no summary recorded'
          puts "- #{entry['phase_id']}: #{detail}"
          puts "  next focus: #{entry['next_focus']}" if entry['next_focus']
        end
      end
      puts
      if snapshot['next_phase']
        puts "Next phase: #{snapshot['next_phase']['phase_id']} #{snapshot['next_phase']['title']}"
        puts 'Read these files next:'
        snapshot['next_required_context'].each_with_index do |path, index|
          puts "#{index + 1}. #{path}"
        end
      else
        puts 'Next phase: none'
      end
      puts
      puts 'Compression-safe resume order:'
      snapshot['resume_read_order'].each_with_index do |item, index|
        puts "#{index + 1}. #{item}"
      end
      puts
      puts 'Compression rules:'
      snapshot['compression_rules'].each do |rule|
        puts "- #{rule}"
      end
    end
  end

  def decorate_completion_entry(entry)
    phase = fetch_phase(entry['phase_id'])
    {
      'phase_id' => entry['phase_id'],
      'title' => phase['title'],
      'completed_at' => entry['completed_at'],
      'summary' => entry['summary'],
      'next_focus' => entry['next_focus']
    }
  end

  def handoff_markdown(snapshot)
    lines = []
    lines << '# Phase-Contract Execution Handoff'
    lines << ''
    lines << '本文件用于长流程执行时的压缩恢复。不要一次性重新加载全部 phase 文档；恢复时按本文档与 manifest 继续。'
    lines << ''
    lines << '## 当前状态'
    lines << ''
    lines << "- State file: `#{snapshot['state_file']}`"
    lines << "- Handoff file: `#{snapshot['handoff_file']}`"
    lines << "- Updated at: `#{snapshot['updated_at'] || 'not recorded yet'}`"
    lines << "- Completed phases: `#{snapshot['completed_phases'].empty? ? 'none' : snapshot['completed_phases'].join(', ')}`"
    lines << ''

    lines << '## 最近完成'
    lines << ''
    if snapshot['recent_completions'].empty?
      lines << '- none'
    else
      snapshot['recent_completions'].each do |entry|
        lines << "- `#{entry['phase_id']}` #{entry['title']}: #{entry['summary'] || 'no summary recorded'}"
        lines << "- next focus: #{entry['next_focus']}" if entry['next_focus']
      end
    end
    lines << ''

    lines << '## 下一 Phase'
    lines << ''
    if snapshot['next_phase']
      lines << "- `#{snapshot['next_phase']['phase_id']}` #{snapshot['next_phase']['title']}"
      lines << "- plan: `#{snapshot['next_phase']['plan_file']}`"
      lines << "- execution: `#{snapshot['next_phase']['execution_file']}`"
      lines << ''
      lines << '下一步读取顺序：'
      snapshot['next_required_context'].each_with_index do |path, index|
        lines << "#{index + 1}. `#{path}`"
      end
    else
      lines << '- none'
    end
    lines << ''

    lines << '## 压缩恢复顺序'
    lines << ''
    snapshot['resume_read_order'].each_with_index do |item, index|
      lines << "#{index + 1}. `#{item}`"
    end
    lines << ''

    lines << '## 压缩控制规则'
    lines << ''
    snapshot['compression_rules'].each do |rule|
      lines << "- #{rule}"
    end
    lines << ''

    lines << '## 连续执行命令'
    lines << ''
    continuous_execution = snapshot['continuous_execution']
    lines << "- next: `#{continuous_execution['next_command']}`" if continuous_execution['next_command']
    lines << "- complete: `#{continuous_execution['completion_command']}`" if continuous_execution['completion_command']
    lines << "- handoff: `ruby scripts/planctl handoff --write`"
    lines << ''

    lines.join("\n")
  end

  def normalized_context_for(phase)
    unique_paths(
      Array(@manifest.dig('execution_rule', 'required_context')) +
      Array(phase['required_context']) +
      [phase['plan_file'], phase['execution_file']]
    )
  end

  def unique_paths(paths)
    paths.compact.each_with_object([]) do |path, result|
      result << path unless result.include?(path)
    end
  end

  def first_remaining_phase(completed)
    manifest_phases.find { |phase| !completed.include?(phase['id']) }
  end

  def blank?(value)
    value.nil? || value.strip.empty?
  end

  def format_list(values)
    values.empty? ? 'none' : values.join(', ')
  end

  def fetch_phase(phase_id)
    phase = manifest_phases.find { |entry| entry['id'] == phase_id }
    return phase if phase

    warn "Unknown phase: #{phase_id}"
    warn "Known phases: #{manifest_phases.map { |entry| entry['id'] }.join(', ')}"
    exit 1
  end

  def manifest_phases
    Array(@manifest['phases'])
  end

  def load_state(create_if_missing: false)
    path = state_file_path
    if path.file?
      state = load_yaml(path)
      check_state_schema!(state, path)
      return state
    end

    default_state = {
      'version' => STATE_SCHEMA_VERSION,
      'completed_phases' => [],
      'completion_log' => []
    }

    write_state(default_state) if create_if_missing
    default_state
  end

  def check_state_schema!(state, path)
    version = state['version']
    return if version.nil? # legacy file without version — tolerate
    return if version.is_a?(Integer) && version <= STATE_SCHEMA_VERSION

    warn "[planctl] error: #{path} declares schema version #{version.inspect}, but this planctl only understands <= #{STATE_SCHEMA_VERSION}."
    warn '[planctl] Upgrade scripts/planctl before continuing, or restore the previous state.yaml.'
    exit 2
  end

  def write_state(state)
    path = state_file_path
    path.dirname.mkpath
    atomic_write(path, YAML.dump(state))
  end

  def write_handoff_file(state, snapshot = nil)
    path = handoff_file_path
    path.dirname.mkpath
    atomic_write(path, handoff_markdown(snapshot || build_handoff_snapshot(state)))
  end

  # Atomic write via tmp + rename. Prevents half-written state.yaml /
  # handoff.md if the process is interrupted mid-write. Keeps state and
  # handoff in lock-step when `complete` writes them back-to-back: the old
  # file stays intact until the new payload is fully flushed to disk.
  def atomic_write(path, content)
    path = Pathname.new(path)
    tmp = path.sub_ext(path.extname + ".tmp.#{Process.pid}")
    File.open(tmp, 'w') do |f|
      f.write(content)
      f.flush
      begin
        f.fsync
      rescue NotImplementedError, Errno::EINVAL
        # fsync unsupported on some filesystems (tmpfs on CI); skip silently.
      end
    end
    File.rename(tmp, path)
  end

  def state_file_relative
    @manifest.dig('execution_rule', 'state_file') || 'plan/state.yaml'
  end

  def state_file_path
    @repo_root.join(state_file_relative)
  end

  def handoff_file_relative
    @manifest.dig('execution_rule', 'handoff_file') || 'plan/handoff.md'
  end

  def handoff_file_path
    @repo_root.join(handoff_file_relative)
  end

  def compression_history_limit
    @manifest.dig('execution_rule', 'compression_control', 'max_completion_history') || 3
  end

  def resume_read_order
    Array(@manifest.dig('execution_rule', 'compression_control', 'resume_read_order'))
  end

  def compression_rules
    Array(@manifest.dig('execution_rule', 'compression_control', 'rules'))
  end

  def load_yaml(path)
    YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
  rescue Psych::SyntaxError => error
    warn "Failed to parse YAML: #{path}"
    warn error.message
    exit 1
  end
end

def usage
  <<~USAGE
    Usage:
      ruby scripts/planctl resolve <phase-id> [--format prompt|json|paths] [--strict]
      ruby scripts/planctl next [--format prompt|json|paths] [--strict]
      ruby scripts/planctl status [--format text|json]
      ruby scripts/planctl complete <phase-id> [--summary TEXT] [--next-focus TEXT]
      ruby scripts/planctl revert <phase-id> [--mode revert|reset] [--summary TEXT]
      ruby scripts/planctl handoff [--format prompt|json] [--write]
      ruby scripts/planctl resume [--strict]
      ruby scripts/planctl doctor
  USAGE
end

script_path = File.expand_path(__FILE__)
repo_root = File.expand_path('..', File.dirname(script_path))
planctl = PlanCtl.new(repo_root)

command = ARGV.shift

case command
when 'resolve'
  options = { format: 'prompt', strict: false }
  parser = OptionParser.new do |opts|
    opts.banner = usage
    opts.on('--format FORMAT', 'prompt, json, or paths') { |value| options[:format] = value }
    opts.on('--strict', 'Exit non-zero if dependencies or context files are missing') { options[:strict] = true }
  end
  parser.parse!(ARGV)
  phase_id = ARGV.shift
  if phase_id.nil? || ARGV.any?
    warn parser.to_s
    exit 1
  end
  planctl.resolve(phase_id, format: options[:format], strict: options[:strict])
when 'next'
  options = { format: 'prompt', strict: false }
  parser = OptionParser.new do |opts|
    opts.banner = usage
    opts.on('--format FORMAT', 'prompt, json, or paths') { |value| options[:format] = value }
    opts.on('--strict', 'Exit non-zero if dependencies or context files are missing') { options[:strict] = true }
  end
  parser.parse!(ARGV)
  if ARGV.any?
    warn parser.to_s
    exit 1
  end
  planctl.next_phase(format: options[:format], strict: options[:strict])
when 'status'
  options = { format: 'text' }
  parser = OptionParser.new do |opts|
    opts.banner = usage
    opts.on('--format FORMAT', 'text or json') { |value| options[:format] = value }
  end
  parser.parse!(ARGV)
  if ARGV.any?
    warn parser.to_s
    exit 1
  end
  planctl.status(format: options[:format])
when 'complete'
  options = { summary: nil, next_focus: nil }
  parser = OptionParser.new do |opts|
    opts.banner = usage
    opts.on('--summary TEXT', 'Concise completion summary to persist for resume') { |value| options[:summary] = value }
    opts.on('--next-focus TEXT', 'Concise note about what should happen next') { |value| options[:next_focus] = value }
  end
  parser.parse!(ARGV)
  phase_id = ARGV.shift
  if phase_id.nil? || ARGV.any?
    warn parser.to_s
    exit 1
  end
  planctl.complete(phase_id, summary: options[:summary], next_focus: options[:next_focus])
when 'revert'
  options = { mode: 'revert', summary: nil }
  parser = OptionParser.new do |opts|
    opts.banner = usage
    opts.on('--mode MODE', 'revert (default, safe) or reset (destructive, rewrites history)') { |value| options[:mode] = value }
    opts.on('--summary TEXT', 'Optional reason recorded in the completion log') { |value| options[:summary] = value }
  end
  parser.parse!(ARGV)
  phase_id = ARGV.shift
  if phase_id.nil? || ARGV.any?
    warn parser.to_s
    exit 1
  end
  planctl.revert(phase_id, mode: options[:mode], summary: options[:summary])
when 'handoff'
  options = { format: 'prompt', write: false }
  parser = OptionParser.new do |opts|
    opts.banner = usage
    opts.on('--format FORMAT', 'prompt or json') { |value| options[:format] = value }
    opts.on('--write', 'Write the current handoff snapshot to plan/handoff.md') { options[:write] = true }
  end
  parser.parse!(ARGV)
  if ARGV.any?
    warn parser.to_s
    exit 1
  end
  planctl.handoff(format: options[:format], write: options[:write])
when 'resume'
  options = { strict: false }
  parser = OptionParser.new do |opts|
    opts.banner = usage
    opts.on('--strict', 'Exit non-zero if next phase is not ready') { options[:strict] = true }
  end
  parser.parse!(ARGV)
  if ARGV.any?
    warn parser.to_s
    exit 1
  end
  planctl.resume(strict: options[:strict])
when 'doctor'
  parser = OptionParser.new { |opts| opts.banner = usage }
  parser.parse!(ARGV)
  if ARGV.any?
    warn parser.to_s
    exit 1
  end
  planctl.doctor
else
  warn usage
  exit 1
end