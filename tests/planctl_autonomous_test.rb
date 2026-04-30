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

  private

  def create_plan_files
    FileUtils.mkdir_p(File.join(@repo, 'plan/phases'))
    FileUtils.mkdir_p(File.join(@repo, 'plan/execution'))
    File.write(File.join(@repo, 'plan/common.md'), "# Common\n")
    File.write(File.join(@repo, 'plan/handoff.md'), "# Handoff\n")
    File.write(File.join(@repo, 'plan/phases/phase-0.md'), "# Phase 0\n")
    File.write(File.join(@repo, 'plan/execution/phase-0.md'), "# Execution 0\n")
    File.write(File.join(@repo, 'plan/phases/phase-1.md'), "# Phase 1\n")
    File.write(File.join(@repo, 'plan/execution/phase-1.md'), "# Execution 1\n")
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
        - id: phase-1
          title: Implement
          plan_file: plan/phases/phase-1.md
          execution_file: plan/execution/phase-1.md
          depends_on:
            - phase-0
    YAML
    File.write(File.join(@repo, 'plan/state.yaml'), <<~YAML)
      version: 1
      completed_phases: []
      completion_log: []
    YAML
  end

  def run_planctl(*args)
    env = args.first.is_a?(Hash) ? args.shift : {}
    Open3.capture3(env, 'ruby', 'scripts/planctl', *args, chdir: @repo)
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
