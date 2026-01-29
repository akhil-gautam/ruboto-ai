# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require_relative "../../lib/ruboto"
require_relative "../../lib/ruboto/workflow"

class WorkflowHistoryTest < Minitest::Test
  def setup
    @test_db = "/tmp/ruboto_history_test_#{$$}.db"
    @test_log_dir = "/tmp/ruboto_test_logs_#{$$}"
    ENV["RUBOTO_DB_PATH"] = @test_db
    ENV["RUBOTO_LOG_DIR"] = @test_log_dir
    FileUtils.mkdir_p(@test_log_dir)
    Ruboto.ensure_db_exists
  end

  def teardown
    FileUtils.rm_f(@test_db)
    FileUtils.rm_rf(@test_log_dir)
    ENV.delete("RUBOTO_DB_PATH")
    ENV.delete("RUBOTO_LOG_DIR")
  end

  # Test 1: Get run history for a workflow
  def test_get_workflow_run_history
    # Create a workflow and simulate some runs
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    # Start and complete a run
    run_id = Ruboto::Workflow::Storage.start_run(workflow_id)
    Ruboto::Workflow::Storage.complete_run(run_id, "completed", { files: ["/tmp/a.txt"] }, [{ event: "done" }])

    history = Ruboto::Workflow::History.get_runs(workflow_id)
    assert_equal 1, history.length
    assert_equal "completed", history.first[:status]
  end

  # Test 2: History includes timing information
  def test_history_includes_timing
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    run_id = Ruboto::Workflow::Storage.start_run(workflow_id)
    sleep 0.1  # Small delay
    Ruboto::Workflow::Storage.complete_run(run_id, "completed", {}, [])

    history = Ruboto::Workflow::History.get_runs(workflow_id)
    assert history.first[:started_at]
    assert history.first[:completed_at]
  end

  # Test 3: History includes step details from log
  def test_history_includes_step_log
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    run_id = Ruboto::Workflow::Storage.start_run(workflow_id)
    log = [
      { step_id: 1, event: "completed", output: "Found 3 files" },
      { step_id: 2, event: "completed", output: "Processed" }
    ]
    Ruboto::Workflow::Storage.complete_run(run_id, "completed", {}, log)

    history = Ruboto::Workflow::History.get_runs(workflow_id, include_log: true)
    assert history.first[:log]
    assert_equal 2, history.first[:log].length
  end

  # Test 4: Get history across all workflows
  def test_get_all_workflow_history
    # Create two workflows with runs
    parsed1 = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps1 = Ruboto::Workflow::PlanGenerator.generate(parsed1)
    wf1_id = Ruboto::Workflow::Storage.save_workflow(parsed1, steps1)

    parsed2 = Ruboto::Workflow::IntentParser.parse("Extract data from PDFs")
    steps2 = Ruboto::Workflow::PlanGenerator.generate(parsed2)
    wf2_id = Ruboto::Workflow::Storage.save_workflow(parsed2, steps2)

    run1 = Ruboto::Workflow::Storage.start_run(wf1_id)
    Ruboto::Workflow::Storage.complete_run(run1, "completed", {}, [])

    run2 = Ruboto::Workflow::Storage.start_run(wf2_id)
    Ruboto::Workflow::Storage.complete_run(run2, "failed", {}, [])

    history = Ruboto::Workflow::History.get_all_runs(limit: 10)
    assert_equal 2, history.length
  end

  # Test 5: History filtered by status
  def test_filter_history_by_status
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    # Create completed and failed runs
    run1 = Ruboto::Workflow::Storage.start_run(workflow_id)
    Ruboto::Workflow::Storage.complete_run(run1, "completed", {}, [])

    run2 = Ruboto::Workflow::Storage.start_run(workflow_id)
    Ruboto::Workflow::Storage.complete_run(run2, "failed", {}, [])

    completed = Ruboto::Workflow::History.get_runs(workflow_id, status: "completed")
    assert_equal 1, completed.length
    assert_equal "completed", completed.first[:status]

    failed = Ruboto::Workflow::History.get_runs(workflow_id, status: "failed")
    assert_equal 1, failed.length
    assert_equal "failed", failed.first[:status]
  end
end

class WorkflowExportImportTest < Minitest::Test
  def setup
    @test_db = "/tmp/ruboto_export_test_#{$$}.db"
    @export_file = "/tmp/ruboto_workflow_export_#{$$}.json"
    ENV["RUBOTO_DB_PATH"] = @test_db
    Ruboto.ensure_db_exists
  end

  def teardown
    FileUtils.rm_f(@test_db)
    FileUtils.rm_f(@export_file)
    ENV.delete("RUBOTO_DB_PATH")
  end

  # Test 6: Export workflow to JSON
  def test_export_workflow_to_json
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    exported = Ruboto::Workflow::ExportImport.export_workflow(workflow_id)

    assert exported[:name]
    assert exported[:description]
    assert exported[:trigger_type]
    assert exported[:steps]
    assert exported[:steps].length > 0
  end

  # Test 7: Export to file
  def test_export_to_file
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull files")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    Ruboto::Workflow::ExportImport.export_to_file(workflow_id, @export_file)

    assert File.exist?(@export_file)
    content = JSON.parse(File.read(@export_file))
    assert content["name"]
  end

  # Test 8: Import workflow from JSON
  def test_import_workflow_from_json
    # Create and export
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull files")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    original_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)
    exported = Ruboto::Workflow::ExportImport.export_workflow(original_id)

    # Delete original
    Ruboto.run_sql("DELETE FROM user_workflows WHERE id = #{original_id};")

    # Import
    new_id = Ruboto::Workflow::ExportImport.import_workflow(exported)
    assert new_id > 0

    # Verify
    imported = Ruboto::Workflow::Storage.load_workflow(new_id)
    assert_equal exported[:name], imported[:name]
  end

  # Test 9: Import from file
  def test_import_from_file
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull files")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    original_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    Ruboto::Workflow::ExportImport.export_to_file(original_id, @export_file)
    Ruboto.run_sql("DELETE FROM user_workflows WHERE id = #{original_id};")

    new_id = Ruboto::Workflow::ExportImport.import_from_file(@export_file)
    assert new_id > 0
  end

  # Test 10: Import handles name conflicts
  def test_import_handles_name_conflict
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull files")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    original_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)
    exported = Ruboto::Workflow::ExportImport.export_workflow(original_id)

    # Import without deleting - should create with modified name
    new_id = Ruboto::Workflow::ExportImport.import_workflow(exported, rename_on_conflict: true)

    assert new_id > 0
    assert new_id != original_id

    imported = Ruboto::Workflow::Storage.load_workflow(new_id)
    assert imported[:name].include?("copy") || imported[:name] != exported[:name]
  end
end

class WorkflowErrorRecoveryTest < Minitest::Test
  def setup
    @test_db = "/tmp/ruboto_recovery_test_#{$$}.db"
    ENV["RUBOTO_DB_PATH"] = @test_db
    Ruboto.ensure_db_exists
  end

  def teardown
    FileUtils.rm_f(@test_db)
    ENV.delete("RUBOTO_DB_PATH")
  end

  # Test 11: Retry failed step with backoff
  def test_retry_with_backoff
    retry_handler = Ruboto::Workflow::ErrorRecovery.new(max_retries: 3, backoff: :constant, base_delay: 0.01)

    attempts = 0
    result = retry_handler.with_retry do
      attempts += 1
      raise Errno::ECONNREFUSED.new("Connection refused") if attempts < 3
      "success"
    end

    assert_equal "success", result
    assert_equal 3, attempts
  end

  # Test 12: Max retries exceeded
  def test_max_retries_exceeded
    retry_handler = Ruboto::Workflow::ErrorRecovery.new(max_retries: 2, backoff: :constant, base_delay: 0.01)

    attempts = 0
    result = retry_handler.with_retry do
      attempts += 1
      raise Errno::ETIMEDOUT.new("Timeout")
    end

    assert_nil result
    assert_equal 2, attempts
    assert retry_handler.last_error
  end

  # Test 13: Classify error severity
  def test_classify_error_severity
    recovery = Ruboto::Workflow::ErrorRecovery.new

    # Network errors are retryable
    assert_equal :retryable, recovery.classify_error(Errno::ECONNREFUSED.new)
    assert_equal :retryable, recovery.classify_error(Timeout::Error.new)

    # File not found is non-critical
    assert_equal :non_critical, recovery.classify_error(Errno::ENOENT.new("file"))

    # Generic errors are critical
    assert_equal :critical, recovery.classify_error(RuntimeError.new("unknown"))
  end
end
