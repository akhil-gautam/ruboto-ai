# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "fileutils"
require_relative "../../lib/ruboto"
require_relative "../../lib/ruboto/workflow"

class WorkflowIntegrationTest < Minitest::Test
  def setup
    @test_db = "/tmp/ruboto_integration_test_#{$$}.db"
    @test_dir = "/tmp/ruboto_test_files_#{$$}"
    ENV["RUBOTO_DB_PATH"] = @test_db

    FileUtils.mkdir_p(@test_dir)
    Ruboto.ensure_db_exists

    # Create test files
    File.write("#{@test_dir}/invoice1.txt", "Invoice #001\nVendor: Acme Corp\nAmount: $500.00\nDate: 2026-01-15")
    File.write("#{@test_dir}/invoice2.txt", "Invoice #002\nVendor: Globex Inc\nAmount: $750.00\nDate: 2026-01-20")
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
    FileUtils.rm_f(@test_db)
    ENV.delete("RUBOTO_DB_PATH")
  end

  def test_parse_generate_save_workflow
    description = "Pull files from #{@test_dir} and extract vendor and amount"

    parsed = Ruboto::Workflow::IntentParser.parse(description)
    assert parsed.name

    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    assert steps.length > 0

    id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)
    assert id > 0

    loaded = Ruboto::Workflow::Storage.load_workflow(id)
    assert_equal parsed.name, loaded[:name]
  end

  def test_runtime_execution_with_real_files
    steps = [
      Ruboto::Workflow::Step.new(
        id: 1,
        tool: "file_glob",
        params: { path: @test_dir, pattern: "*.txt" },
        output_key: "files",
        description: "Find text files"
      )
    ]

    runtime = Ruboto::Workflow::Runtime.new(steps)
    step = runtime.current_step
    resolved = runtime.resolve_params(step.params)

    result = Ruboto.execute_workflow_step(step, resolved)

    assert result[:success]
    assert_equal 2, result[:output].length
  end

  def test_csv_append_workflow
    csv_path = "#{@test_dir}/output.csv"

    steps = [
      Ruboto::Workflow::Step.new(
        id: 1,
        tool: "csv_append",
        params: { path: csv_path, data: { "vendor" => "Test", "amount" => "100" } },
        output_key: nil,
        description: "Append to CSV"
      )
    ]

    runtime = Ruboto::Workflow::Runtime.new(steps)
    result = Ruboto.execute_workflow_step(runtime.current_step, runtime.resolve_params(runtime.current_step.params))

    assert result[:success]
    assert File.exist?(csv_path)

    content = File.read(csv_path)
    assert_match /Test/, content
  end

  def test_full_workflow_chain
    # Test: file_glob -> data processing -> csv_append
    csv_path = "#{@test_dir}/results.csv"

    # Step 1: Find files
    step1 = Ruboto::Workflow::Step.new(
      id: 1,
      tool: "file_glob",
      params: { path: @test_dir, pattern: "*.txt" },
      output_key: "files",
      description: "Find files"
    )

    runtime = Ruboto::Workflow::Runtime.new([step1])
    result1 = Ruboto.execute_workflow_step(step1, runtime.resolve_params(step1.params))
    assert result1[:success]
    runtime.store_result("files", result1[:output])

    # Step 2: Append file count to CSV
    step2 = Ruboto::Workflow::Step.new(
      id: 2,
      tool: "csv_append",
      params: { path: csv_path, data: { "file_count" => result1[:output].length.to_s, "status" => "processed" } },
      output_key: nil,
      description: "Save results"
    )

    result2 = Ruboto.execute_workflow_step(step2, runtime.resolve_params(step2.params))
    assert result2[:success]

    # Verify CSV was created with correct data
    csv_content = Ruboto::Workflow::Extractors::CSV.read(csv_path)
    assert_equal 1, csv_content.length
    assert_equal "2", csv_content[0]["file_count"]
  end

  def test_workflow_storage_roundtrip
    description = "Every Friday pull files from #{@test_dir}"
    parsed = Ruboto::Workflow::IntentParser.parse(description)
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)

    # Save
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    # Start a run
    run_id = Ruboto::Workflow::Storage.start_run(workflow_id)
    assert run_id > 0

    # Complete the run
    Ruboto::Workflow::Storage.complete_run(run_id, "completed", { files: ["a.txt"] }, [{ event: "done" }])

    # Update confidence
    Ruboto::Workflow::Storage.update_step_confidence(workflow_id, 1, 0.8)
    Ruboto::Workflow::Storage.increment_run_count(workflow_id, true)
    Ruboto::Workflow::Storage.update_overall_confidence(workflow_id)

    # Verify
    loaded = Ruboto::Workflow::Storage.load_workflow(workflow_id)
    assert_equal 1, loaded[:run_count]
    assert_equal 1, loaded[:success_count]
  end
end
