# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require_relative "../../lib/ruboto"
require_relative "../../lib/ruboto/workflow"

class WorkflowStorageOperationsTest < Minitest::Test
  def setup
    @test_db = "/tmp/ruboto_test_#{$$}.db"
    ENV["RUBOTO_DB_PATH"] = @test_db
    Ruboto.ensure_db_exists
  end

  def teardown
    FileUtils.rm_f(@test_db)
    ENV.delete("RUBOTO_DB_PATH")
  end

  def test_save_workflow
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull PDFs from Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)

    id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)
    assert id > 0
  end

  def test_load_workflow
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull PDFs from Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    loaded = Ruboto::Workflow::Storage.load_workflow(id)
    assert_equal parsed.name, loaded[:name]
  end

  def test_list_workflows
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull PDFs from Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    list = Ruboto::Workflow::Storage.list_workflows
    assert list.length > 0
  end

  def test_save_run
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull PDFs from Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    run_id = Ruboto::Workflow::Storage.start_run(workflow_id)
    assert run_id > 0
  end

  def test_update_step_confidence
    parsed = Ruboto::Workflow::IntentParser.parse("Every Friday pull PDFs from Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    Ruboto::Workflow::Storage.update_step_confidence(workflow_id, 1, 0.8)
    loaded_steps = Ruboto::Workflow::Storage.load_steps(workflow_id)
    assert_equal 0.8, loaded_steps.first[:confidence]
  end
end
