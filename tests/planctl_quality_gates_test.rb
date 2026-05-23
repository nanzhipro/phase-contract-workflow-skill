# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

class PlanctlQualityGatesTest < Minitest::Test
  REPO_ROOT = File.expand_path('..', __dir__)
  SOURCE_PLANCTL = File.join(REPO_ROOT, 'scripts', 'planctl.rb')

  def setup
    @tmpdir = Dir.mktmpdir('phase-contract-quality-gates-')
    @repo = @tmpdir
    FileUtils.mkdir_p(File.join(@repo, 'scripts'))
    FileUtils.cp(SOURCE_PLANCTL, File.join(@repo, 'scripts', 'planctl'))
    FileUtils.chmod('+x', File.join(@repo, 'scripts', 'planctl'))
    git('init')
    git('config', 'user.email', 'test@example.com')
    git('config', 'user.name', 'Planctl Test')
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_complete_allows_state_write_after_required_checks_pass
    create_repo_fixture(
      require_phase_checks: true,
      required_checks: [
        {
          'id' => 'build',
          'command' => "ruby -e 'puts :ok'",
          'timeout_seconds' => 30
        }
      ]
    )

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'complete', 'phase-0',
      '--summary', 'Required checks passed.',
      '--next-focus', 'Review completion log.'
    )

    assert status.success?, err
    assert_includes out, 'Marked complete: phase-0'

    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    assert_equal ['phase-0'], state['completed_phases']
    checks = state.fetch('completion_log').last.fetch('checks')
    assert_equal 'build', checks.last.fetch('id')
    assert_equal 'passed', checks.last.fetch('status')
  end

  def test_complete_refuses_to_write_state_when_required_check_fails
    create_repo_fixture(
      require_phase_checks: true,
      required_checks: [
        {
          'id' => 'build',
          'command' => "ruby -e 'warn :boom; exit 1'",
          'timeout_seconds' => 30
        }
      ]
    )
    baseline_handoff = File.read(File.join(@repo, 'plan/handoff.md'))

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'complete', 'phase-0',
      '--summary', 'Should be blocked.',
      '--next-focus', 'Do not advance.'
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes err + out, 'build'
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    assert_equal [], state['completed_phases']
    assert_equal [], state['completion_log']
    assert_equal baseline_handoff, File.read(File.join(@repo, 'plan/handoff.md'))
  end

  def test_dry_run_does_not_modify_state_or_journal
    create_repo_fixture(
      require_phase_checks: true,
      required_checks: [
        {
          'id' => 'build',
          'command' => "ruby -e 'puts :ok'",
          'timeout_seconds' => 30
        }
      ]
    )
    baseline_state = File.read(File.join(@repo, 'plan/state.yaml'))
    baseline_handoff = File.read(File.join(@repo, 'plan/handoff.md'))

    out, err, status = run_planctl('complete', 'phase-0', '--dry-run')

    assert status.success?, err + out
    assert_includes out, 'DRY RUN'
    assert_includes out, 'ok: contract-lint'
    assert_includes out, 'ok: required check build'
    assert_equal baseline_state, File.read(File.join(@repo, 'plan/state.yaml'))
    assert_equal baseline_handoff, File.read(File.join(@repo, 'plan/handoff.md'))
    refute File.exist?(File.join(@repo, 'plan/journal/phase-0.jsonl'))
  end

  def test_dry_run_returns_nonzero_when_required_check_fails
    create_repo_fixture(
      require_phase_checks: true,
      required_checks: [
        {
          'id' => 'build',
          'command' => "ruby -e 'warn :boom; exit 1'",
          'timeout_seconds' => 30
        }
      ]
    )
    baseline_state = File.read(File.join(@repo, 'plan/state.yaml'))

    out, err, status = run_planctl('complete', 'phase-0', '--dry-run')

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes err + out, 'build'
    assert_equal baseline_state, File.read(File.join(@repo, 'plan/state.yaml'))
    refute File.exist?(File.join(@repo, 'plan/journal/phase-0.jsonl'))
  end

  def test_advance_demotes_implement_to_promote_placeholder_when_lint_fails
    # Build a fixture where phase-0 has no sentinel but its formal contract
    # is missing required markers — lint will report problems and advance
    # --strict should demote ACTION: implement to ACTION: promote_placeholder
    # with lint_problems rendered to the agent.
    create_repo_fixture(require_phase_checks: false, required_checks: [])
    broken_plan = File.join(@repo, 'plan/phases/phase-0.md')
    File.write(broken_plan, <<~MARKDOWN)
      # Phase 0

      ## 阶段定位

      - 测试 lint 降级路径

      ## 完成判定

      - placeholder removed but markers missing
    MARKDOWN

    out, err, status = run_planctl('advance', '--strict')

    # promote_placeholder remains an internal Golden Loop action (exit 0),
    # the agent is expected to fix the lint and rerun the same strict cmd.
    assert status.success?, "advance should succeed (exit 0) on lint demotion: #{out + err}"
    assert_includes out, 'ACTION: promote_placeholder'
    assert_includes out, 'STOP_REASON: lint_failed'
    assert_includes out, 'still fail contract lint'
    assert_includes out, 'missing marker PHASE_CONTRACT:FACT_AUDIT'

    # And — crucially — no current_phase was written (advance must not auto-
    # start a phase whose contract lint is still failing).
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    refute state.key?('current_phase')
  end

  def test_optional_check_failure_warns_but_still_completes
    create_repo_fixture(
      require_phase_checks: true,
      required_checks: [
        {
          'id' => 'build',
          'command' => "ruby -e 'puts :ok'",
          'timeout_seconds' => 30
        }
      ],
      optional_checks: [
        {
          'id' => 'log-smoke',
          'command' => "ruby -e 'warn :missing_log; exit 1'",
          'timeout_seconds' => 30
        }
      ]
    )

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'complete', 'phase-0',
      '--summary', 'Optional check warning only.',
      '--next-focus', 'Inspect warnings.'
    )

    assert status.success?, err
    assert_includes err + out, 'optional'
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    checks = state.fetch('completion_log').last.fetch('checks')
    optional = checks.find { |entry| entry['id'] == 'log-smoke' }
    refute_nil optional
    assert_equal 'failed', optional.fetch('status')
  end

  def test_required_check_timeout_blocks_completion_and_reports_timeout
    create_repo_fixture(
      require_phase_checks: true,
      required_checks: [
        {
          'id' => 'slow-check',
          'command' => "ruby -e 'sleep 2'",
          'timeout_seconds' => 1
        }
      ]
    )

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'complete', 'phase-0',
      '--summary', 'Timeout should block.',
      '--next-focus', 'Shorten timeout.'
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes err + out, 'timeout'
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    assert_equal [], state['completed_phases']
  end

  def test_require_phase_checks_blocks_when_phase_has_no_checks
    create_repo_fixture(require_phase_checks: true)

    out, err, status = run_planctl('lint-contracts', '--phase', 'phase-0')

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes err + out, 'at least one required check'
  end

  def test_lint_contracts_reports_missing_required_markers
    create_repo_fixture(
      require_phase_checks: true,
      required_checks: [
        {
          'id' => 'build',
          'command' => "ruby -e 'exit 0'",
          'timeout_seconds' => 30
        }
      ],
      phase_doc: "# Phase 0\n\n## 完成判定\n- 只写一个结果。\n",
      execution_doc: "# Execution 0\n\n## 交付检查\n- 只写一个结果。\n"
    )

    out, err, status = run_planctl('lint-contracts', '--phase', 'phase-0')

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes err + out, 'PHASE_CONTRACT:PRODUCTION_WIRING'
    assert_includes err + out, 'PHASE_CONTRACT:RUNTIME_EVIDENCE'
  end

  def test_allowed_paths_strict_mode_blocks_out_of_scope_changes
    create_repo_fixture(
      require_phase_checks: true,
      required_checks: [
        {
          'id' => 'build',
          'command' => "ruby -e 'exit 0'",
          'timeout_seconds' => 30
        }
      ],
      allowed_paths: ['Sources/Feature/**']
    )
    File.write(File.join(@repo, 'README.md'), "unexpected\n")

    out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'complete', 'phase-0',
      '--summary', 'Out-of-scope change present.',
      '--next-focus', 'Trim changed files.'
    )

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes err + out, 'outside allowed_paths'
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    assert_equal [], state['completed_phases']
  end

  def test_completion_log_records_check_summary
    create_repo_fixture(
      require_phase_checks: true,
      required_checks: [
        {
          'id' => 'build',
          'command' => "ruby -e 'puts %(line 1); puts %(line 2)'",
          'timeout_seconds' => 30
        }
      ],
      optional_checks: [
        {
          'id' => 'log-smoke',
          'command' => "ruby -e 'warn %(missing optional log); exit 1'",
          'timeout_seconds' => 30
        }
      ]
    )

    _out, err, status = run_planctl(
      { 'PHASE_CONTRACT_SKIP_COMMIT' => '1' },
      'complete', 'phase-0',
      '--summary', 'Record check summary.',
      '--next-focus', 'Review ledger.'
    )

    assert status.success?, err
    state = YAML.load_file(File.join(@repo, 'plan/state.yaml'))
    checks = state.fetch('completion_log').last.fetch('checks')
    contract_lint = checks.find { |entry| entry['id'] == 'contract-lint' }
    build = checks.find { |entry| entry['id'] == 'build' }
    refute_nil contract_lint
    refute_nil build
    assert_equal 'passed', contract_lint.fetch('status')
    assert_includes build.fetch('output_tail'), 'line 2'
    assert build.key?('duration_seconds')
    assert build.key?('exit_code')
  end

  def test_doctor_reports_current_phase_contract_issues
    create_repo_fixture(
      require_phase_checks: true,
      phase_doc: "# Phase 0\n\n## 完成判定\n- 看起来可以。\n",
      execution_doc: "# Execution 0\n\n## 交付检查\n- 基本完成。\n"
    )

    out, err, status = run_planctl('doctor')

    refute status.success?
    assert_equal 2, status.exitstatus
    assert_includes err + out, 'contract lint'
    assert_includes err + out, 'PHASE_CONTRACT:FACT_AUDIT'
  end

  private

  def create_repo_fixture(require_phase_checks: false, required_checks: [], optional_checks: [], allowed_paths: ['Sources/Feature/**'], phase_doc: formal_phase_contract, execution_doc: formal_execution_contract)
    FileUtils.mkdir_p(File.join(@repo, 'plan/phases'))
    FileUtils.mkdir_p(File.join(@repo, 'plan/execution'))
    FileUtils.mkdir_p(File.join(@repo, 'Sources/Feature'))
    File.write(File.join(@repo, 'Sources/Feature', 'feature.txt'), "feature\n")
    File.write(File.join(@repo, 'plan/common.md'), "# Common\n")
    File.write(File.join(@repo, 'plan/handoff.md'), "# Handoff\n")
    File.write(File.join(@repo, 'plan/phases/phase-0.md'), phase_doc)
    File.write(File.join(@repo, 'plan/execution/phase-0.md'), execution_doc)

    manifest = {
      'version' => 1,
      'project' => 'test-project',
      'execution_rule' => {
        'resolver' => 'scripts/planctl',
        'state_file' => 'plan/state.yaml',
        'handoff_file' => 'plan/handoff.md',
        'required_context' => ['plan/common.md'],
        'require_phase_checks' => require_phase_checks,
        'enforce_allowed_paths' => true
      },
      'phases' => [
        {
          'id' => 'phase-0',
          'title' => 'Quality gate phase',
          'plan_file' => 'plan/phases/phase-0.md',
          'execution_file' => 'plan/execution/phase-0.md',
          'required_context' => [
            'plan/common.md',
            'plan/phases/phase-0.md',
            'plan/execution/phase-0.md'
          ],
          'depends_on' => [],
          'allowed_paths' => allowed_paths,
          'checks' => {
            'required' => required_checks,
            'optional' => optional_checks
          }
        }
      ]
    }
    File.write(File.join(@repo, 'plan/manifest.yaml'), YAML.dump(manifest))
    File.write(File.join(@repo, 'plan/state.yaml'), <<~YAML)
      version: 1
      completed_phases: []
      completion_log: []
    YAML

    git('add', '-A')
    git('commit', '-m', 'baseline')
  end

  def formal_phase_contract
    <<~MARKDOWN
      # Phase 0

      ## 阶段定位

      - 收紧质量门。

      ## PHASE_CONTRACT:FACT_AUDIT

      - 用 rg 与 git 确认真实入口和调用方。

      ## PHASE_CONTRACT:PRODUCTION_WIRING

      | artifact | producer | production caller | activation condition | fallback behavior | runtime evidence | owning phase |
      | --- | --- | --- | --- | --- | --- | --- |
      | feature.txt | fixture | feature boot | default enabled | keep prior path | startup log | phase-0 |

      ## PHASE_CONTRACT:RUNTIME_EVIDENCE

      - 运行 required checks 时输出稳定证据。

      ## PHASE_CONTRACT:FAILURE_MODES

      - 覆盖 timeout、late reply、disabled path。

      ## 完成判定

      - 所有 required checks 成功。
      - completion_log 写入 check 摘要。
    MARKDOWN
  end

  def formal_execution_contract
    <<~MARKDOWN
      # Execution 0

      ## 必带上下文

      - plan/common.md
      - plan/phases/phase-0.md

      ## PHASE_CONTRACT:FACT_AUDIT

      - 列出 Sources/Feature 下真实生产调用点。

      ## PHASE_CONTRACT:PRODUCTION_WIRING

      | artifact | producer | production caller | activation condition | fallback behavior | runtime evidence | owning phase |
      | --- | --- | --- | --- | --- | --- | --- |
      | feature.txt | fixture | feature boot | default enabled | keep prior path | startup log | phase-0 |

      ## PHASE_CONTRACT:RUNTIME_EVIDENCE

      - required check stdout 包含稳定输出。

      ## PHASE_CONTRACT:FAILURE_MODES

      - 阻断 timeout、空状态与越界改动。

      ## 本次允许改动

      - Sources/Feature/**

      ## 交付检查

      - required checks 全部通过。
      - optional checks 失败仅 warning。
    MARKDOWN
  end

  def run_planctl(*args)
    env = args.first.is_a?(Hash) ? args.shift : {}
    Open3.capture3(env, 'ruby', 'scripts/planctl', *args, chdir: @repo)
  end

  def git(*args)
    Open3.capture3('git', *args, chdir: @repo).tap do |_out, err, status|
      raise err unless status.success?
    end
  end
end