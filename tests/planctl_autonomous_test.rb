# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

class PlanctlAutonomousTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  SOURCE_PLANCTL = File.join(REPO_ROOT, 'scripts', 'planctl.rb')

  def setup
    @tmpdir = Dir.mktmpdir('phase-contract-autonomous-')
    @repo = @tmpdir
    FileUtils.mkdir_p(File.join(@repo, 'scripts'))
    FileUtils.cp(SOURCE_PLANCTL, File.join(@repo, 'scripts', 'planctl'))
    FileUtils.chmod('+x', File.join(@repo, 'scripts', 'planctl'))
    create_plan_files
    git('init')
    git('config', 'user.email', 'test@example.com')
    git('config', 'user.name', 'Planctl Test')
    git('add', '-A')
    git('commit', '-m', 'baseline')
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_complete_continue_prints_next_phase_action
    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'complete', 'phase-0',
      '--summary', 'Scaffold complete.',
      '--next-focus', 'Implement phase 1.',
      '--continue'
    )

    assert status.success?, err
    assert_includes out, 'Marked complete: phase-0'
    assert_includes out, '=== Phase-Contract Advance ==='
    assert_includes out, 'ACTION: implement'
    assert_includes out, 'PHASE: phase-1'
    refute_includes out, 'asking for an extra confirmation'
  end

  def test_advance_strict_treats_placeholder_as_internal_action_not_blocker
    File.write(File.join(@repo, 'plan/state.yaml'), <<~YAML)
      version: 1
      completed_phases:
        - phase-0
      completion_log: []
    YAML
    File.write(
      File.join(@repo, 'plan/phases/phase-1.md'),
      "# PHASE_CONTRACT_PLACEHOLDER\n\n占位合同，禁止实施。"
    )

    out, err, status = run_planctl('advance', '--strict')

    assert status.success?, err
    assert_includes out, 'ACTION: promote_placeholder'
    assert_includes out, 'PHASE: phase-1'
    assert_includes out, 'STOP_REASON: none'
  end

  def test_resume_strict_uses_advance_actions_for_placeholder_phase
    File.write(File.join(@repo, 'plan/state.yaml'), <<~YAML)
      version: 1
      completed_phases:
        - phase-0
      completion_log: []
    YAML
    File.write(
      File.join(@repo, 'plan/execution/phase-1.md'),
      "# PHASE_CONTRACT_PLACEHOLDER\n\n占位合同，禁止实施。"
    )

    out, err, status = run_planctl('resume', '--strict')

    assert status.success?, err
    assert_includes out, '--- Next action ---'
    assert_includes out, 'ACTION: promote_placeholder'
  end

  def test_reset_rewinds_workflow_to_origin_after_committed_phase
    baseline_head = git_output('rev-parse', 'HEAD').strip
    baseline_handoff = File.read(File.join(@repo, 'plan/handoff.md'))

    complete_phase_with_local_commit('phase-0', 'Phase 0 done.', 'Start phase 1.')

    out, err, status = run_planctl('reset')

    assert status.success?, err
    assert_equal baseline_head, git_output('rev-parse', 'HEAD').strip
    assert_equal baseline_handoff, File.read(File.join(@repo, 'plan/handoff.md'))
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    assert_equal [], state['completed_phases']
    assert_equal [], state['completion_log']
    refute state.key?('finalized_at')
    assert_includes out, 'Workflow state is back at the origin.'
    assert_includes out, 'Next phase: phase-0'

    advance_out, advance_err, advance_status = run_planctl('advance', '--strict')
    assert advance_status.success?, advance_err
    assert_includes advance_out, 'PHASE: phase-0'
  end

  def test_reset_rewinds_finalized_workflow_to_origin
    baseline_head = git_output('rev-parse', 'HEAD').strip
    baseline_handoff = File.read(File.join(@repo, 'plan/handoff.md'))

    complete_all_phases_with_local_commits
    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_PUSH' => '1' },
      'finalize'
    )
    assert status.success?, err
    refute_equal baseline_head, git_output('rev-parse', 'HEAD').strip

    out, err, status = run_planctl('reset')

    assert status.success?, err
    assert_equal baseline_head, git_output('rev-parse', 'HEAD').strip
    assert_equal baseline_handoff, File.read(File.join(@repo, 'plan/handoff.md'))
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    assert_equal [], state['completed_phases']
    assert_equal [], state['completion_log']
    refute state.key?('finalized_at')
    assert_includes out, 'Workflow state is back at the origin.'
  end

  def test_reset_clears_uncommitted_workflow_ledgers_back_to_origin
    baseline_head = git_output('rev-parse', 'HEAD').strip
    baseline_handoff = File.read(File.join(@repo, 'plan/handoff.md'))

    complete_all_phases_with_skip_commit

    out, err, status = run_planctl('reset')

    assert status.success?, err
    assert_equal baseline_head, git_output('rev-parse', 'HEAD').strip
    assert_equal baseline_handoff, File.read(File.join(@repo, 'plan/handoff.md'))
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    assert_equal [], state['completed_phases']
    assert_equal [], state['completion_log']
    refute state.key?('finalized_at')
    assert_includes out, 'No planctl workflow commits found'
    assert_includes out, 'Next phase: phase-0'
  end

  def test_finalize_first_run_records_ledger_and_creates_commit
    complete_all_phases_with_skip_commit

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_PUSH' => '1' },
      'finalize'
    )

    assert status.success?, err
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    refute_nil state['finalized_at']
    refute_empty state['finalized_at']
    assert_equal state['finalized_at'], state['updated_at']
    handoff = File.read(File.join(@repo, 'plan/handoff.md'))
    assert_includes handoff, "Finalized at: `#{state['finalized_at']}`"
    assert_includes out, 'Finalized at:'
    assert_includes out, 'chore(plan): finalize test-project execution'

    log = git_output('log', '-n', '1', '--format=%s%n%b')
    assert_includes log, 'chore(plan): finalize test-project execution'
    assert_includes log, 'Finalized-At:'
    assert_includes log, 'Automated-By: scripts/planctl finalize'
  end

  def test_finalize_second_run_is_read_only_after_finalized_at_exists
    complete_all_phases_with_skip_commit
    run_planctl({ 'PHASE_CONTRACT_SKIP_PUSH' => '1' }, 'finalize')
    baseline_state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    baseline_handoff = File.read(File.join(@repo, 'plan/handoff.md'))
    baseline_head = git_output('rev-parse', 'HEAD').strip

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_PUSH' => '1' },
      'finalize'
    )

    assert status.success?, err
    assert_equal baseline_state, YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    assert_equal baseline_handoff, File.read(File.join(@repo, 'plan/handoff.md'))
    assert_equal baseline_head, git_output('rev-parse', 'HEAD').strip
    assert_includes out, 'Finalized at:'
    refute_includes out, 'Committed finalization ledger'
  end

  def test_finalize_refuses_dashboard_when_completed_phase_lacks_successful_execution_log
    File.write(File.join(@repo, 'plan/state.yaml'), <<~YAML)
      version: 1
      completed_phases:
        - phase-0
        - phase-1
      completion_log:
        - phase_id: phase-0
          completed_at: "2026-01-01T00:00:00Z"
          summary: "Phase 0 done."
          next_focus: "Start phase 1."
          checks:
            - id: contract-lint
              status: passed
              required: true
        - phase_id: phase-1
          completed_at: "2026-01-01T00:01:00Z"
          summary: "Phase 1 failed but was written manually."
          next_focus: "Finalize execution."
          checks:
            - id: build
              status: failed
              required: true
    YAML
    baseline_handoff = File.read(File.join(@repo, 'plan/handoff.md'))

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'finalize'
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes err + out, 'phase-1'
    assert_includes err + out, 'required check build failed'
    refute_includes out, '=== Phase-Contract Final Execution Dashboard ==='
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    refute state.key?('finalized_at')
    assert_equal baseline_handoff, File.read(File.join(@repo, 'plan/handoff.md'))
  end

  def test_finalize_refuses_dashboard_when_declared_required_check_has_no_success_evidence
    manifest_path = File.join(@repo, 'plan/manifest.yaml')
    manifest = YAML.load_file(manifest_path)
    manifest['phases'].last['checks'] = {
      'required' => [
        {
          'id' => 'build',
          'command' => "ruby -e 'exit 0'",
          'timeout_seconds' => 30
        }
      ]
    }
    File.write(manifest_path, YAML.dump(manifest))
    File.write(File.join(@repo, 'plan/state.yaml'), <<~YAML)
      version: 1
      completed_phases:
        - phase-0
        - phase-1
      completion_log:
        - phase_id: phase-0
          completed_at: "2026-01-01T00:00:00Z"
          summary: "Phase 0 done."
          next_focus: "Start phase 1."
          checks:
            - id: contract-lint
              status: passed
              required: true
        - phase_id: phase-1
          completed_at: "2026-01-01T00:01:00Z"
          summary: "Phase 1 claims done."
          next_focus: "Finalize execution."
          checks:
            - id: contract-lint
              status: passed
              required: true
    YAML

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'finalize'
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes err + out, 'phase-1'
    assert_includes err + out, 'missing required check evidence: build'
    refute_includes out, '=== Phase-Contract Final Execution Dashboard ==='
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    refute state.key?('finalized_at')
  end

  private

  def create_plan_files
    FileUtils.mkdir_p(File.join(@repo, 'plan/phases'))
    FileUtils.mkdir_p(File.join(@repo, 'plan/execution'))
    File.write(File.join(@repo, 'plan/common.md'), "# Common\n")
    File.write(File.join(@repo, 'plan/handoff.md'), "# Handoff\n")
    FileUtils.mkdir_p(File.join(@repo, 'Sources/Feature'))
    File.write(File.join(@repo, 'Sources/Feature/phase-0.txt'), "phase-0\n")
    File.write(File.join(@repo, 'Sources/Feature/phase-1.txt'), "phase-1\n")
    File.write(File.join(@repo, 'plan/phases/phase-0.md'), formal_phase_contract('Phase 0'))
    File.write(File.join(@repo, 'plan/execution/phase-0.md'), formal_execution_contract('phase-0.txt'))
    File.write(File.join(@repo, 'plan/phases/phase-1.md'), formal_phase_contract('Phase 1'))
    File.write(File.join(@repo, 'plan/execution/phase-1.md'), formal_execution_contract('phase-1.txt'))
    File.write(File.join(@repo, 'plan/manifest.yaml'), <<~YAML)
      version: 1
      project: test-project
      execution_rule:
        resolver: scripts/planctl
        state_file: plan/state.yaml
        handoff_file: plan/handoff.md
        required_context:
          - plan/common.md
        continuation:
          mode: autonomous
          stop_only_on:
            - blocker
            - dependency_missing
            - missing_context
            - all_phases_completed
        compression_control:
          max_completion_history: 3
          resume_read_order:
            - plan/manifest.yaml
            - plan/handoff.md
            - next.phase.required_context
          rules:
            - Never load all phase docs.
        continuous_execution:
          next_command: ruby scripts/planctl advance --strict
          completion_command: ruby scripts/planctl complete <phase-id> --summary "<summary>" --next-focus "<next-focus>" --continue
      phases:
        - id: phase-0
          title: Scaffold
          plan_file: plan/phases/phase-0.md
          execution_file: plan/execution/phase-0.md
          depends_on: []
          allowed_paths:
            - Sources/Feature/**
        - id: phase-1
          title: Implement
          plan_file: plan/phases/phase-1.md
          execution_file: plan/execution/phase-1.md
          depends_on:
            - phase-0
          allowed_paths:
            - Sources/Feature/**
    YAML
    File.write(File.join(@repo, 'plan/state.yaml'), <<~YAML)
      version: 1
      completed_phases: []
      completion_log: []
    YAML
  end

  def formal_phase_contract(title)
    <<~MARKDOWN
      # #{title}

      ## 阶段定位

      - 验证 autonomous 流程。

      ## PHASE_CONTRACT:FACT_AUDIT

      - 确认 phase 对应的 Sources/Feature 路径已纳入生产边界。

      ## PHASE_CONTRACT:PRODUCTION_WIRING

      | artifact | producer | production caller | activation condition | fallback behavior | runtime evidence | owning phase |
      | --- | --- | --- | --- | --- | --- | --- |
      | phase fixture | test setup | phase runtime | default enabled | keep current phase | phase log | #{title.downcase.gsub(' ', '-')} |

      ## PHASE_CONTRACT:RUNTIME_EVIDENCE

      - `planctl complete` 成功写入 state 与 handoff。

      ## PHASE_CONTRACT:FAILURE_MODES

      - 阻断 placeholder、越界路径和缺失上下文。

      ## 完成判定

      - phase 可被 `complete` 正常完成。
    MARKDOWN
  end

  def formal_execution_contract(artifact_name)
    <<~MARKDOWN
      # Execution #{artifact_name}

      ## 必带上下文

      - plan/common.md
      - plan/phases/current.md

      ## PHASE_CONTRACT:FACT_AUDIT

      - 产物位于 Sources/Feature 下。

      ## PHASE_CONTRACT:PRODUCTION_WIRING

      | artifact | producer | production caller | activation condition | fallback behavior | runtime evidence | owning phase |
      | --- | --- | --- | --- | --- | --- | --- |
      | #{artifact_name} | test setup | phase runtime | default enabled | keep current phase | phase log | autonomous-test |

      ## PHASE_CONTRACT:RUNTIME_EVIDENCE

      - `complete --continue` 输出下一步 ACTION。

      ## PHASE_CONTRACT:FAILURE_MODES

      - placeholder 升级前不得实施。

      ## 本次允许改动

      - Sources/Feature/**

      ## 交付检查

      - `complete` 或 `finalize` 按预期输出。
    MARKDOWN
  end

  def run_planctl(*args)
    env = args.first.is_a?(Hash) ? args.shift : {}
    Open3.capture3(env, 'ruby', 'scripts/planctl', *args, chdir: @repo)
  end

  def complete_phase_with_local_commit(phase_id, summary, next_focus)
    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_PUSH' => '1' },
      'complete', phase_id,
      '--summary', summary,
      '--next-focus', next_focus
    )
    raise "#{phase_id} complete failed: #{err}\n#{out}" unless status.success?
  end

  def complete_all_phases_with_local_commits
    complete_phase_with_local_commit('phase-0', 'Phase 0 done.', 'Start phase 1.')
    complete_phase_with_local_commit('phase-1', 'Phase 1 done.', 'Finalize execution.')
  end

  def complete_all_phases_with_skip_commit
    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'complete', 'phase-0',
      '--summary', 'Phase 0 done.',
      '--next-focus', 'Start phase 1.'
    )
    raise "phase-0 complete failed: #{err}\n#{out}" unless status.success?

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'complete', 'phase-1',
      '--summary', 'Phase 1 done.',
      '--next-focus', 'Finalize execution.'
    )
    raise "phase-1 complete failed: #{err}\n#{out}" unless status.success?
  end

  def git_output(*args)
    out, err, status = Open3.capture3('git', *args, chdir: @repo)
    raise err unless status.success?

    out
  end

  def git(*args)
    Open3.capture3('git', *args, chdir: @repo).tap do |_out, err, status|
      raise err unless status.success?
    end
  end
end
