# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require_relative "../../lib/ruboto"

class WorkflowStorageTest < Minitest::Test
  def setup
    @test_db = "/tmp/ruboto_test_#{$$}.db"
    ENV["RUBOTO_DB_PATH"] = @test_db
  end

  def teardown
    FileUtils.rm_f(@test_db)
    ENV.delete("RUBOTO_DB_PATH")
  end

  def test_workflow_table_exists
    Ruboto.ensure_db_exists
    result = Ruboto.run_sql("SELECT name FROM sqlite_master WHERE type='table' AND name='user_workflows';")
    assert_match /user_workflows/, result
  end

  def test_workflow_steps_table_exists
    Ruboto.ensure_db_exists
    result = Ruboto.run_sql("SELECT name FROM sqlite_master WHERE type='table' AND name='workflow_steps';")
    assert_match /workflow_steps/, result
  end

  def test_workflow_runs_table_exists
    Ruboto.ensure_db_exists
    result = Ruboto.run_sql("SELECT name FROM sqlite_master WHERE type='table' AND name='workflow_runs';")
    assert_match /workflow_runs/, result
  end
end
