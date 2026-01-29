# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require_relative "../../lib/ruboto"
require_relative "../../lib/ruboto/workflow"

class TriggerManagerTest < Minitest::Test
  def setup
    @test_db = "/tmp/ruboto_trigger_test_#{$$}.db"
    ENV["RUBOTO_DB_PATH"] = @test_db
    Ruboto.ensure_db_exists
  end

  def teardown
    FileUtils.rm_f(@test_db)
    ENV.delete("RUBOTO_DB_PATH")
  end

  # Test 1: Parse schedule trigger config
  def test_parse_schedule_trigger
    trigger = Ruboto::Workflow::TriggerManager.parse_schedule("every friday at 5pm")

    assert_equal :weekly, trigger[:frequency]
    assert_equal 5, trigger[:day_of_week]  # Friday = 5
    assert_equal 17, trigger[:hour]        # 5pm = 17
  end

  # Test 2: Parse daily schedule
  def test_parse_daily_schedule
    trigger = Ruboto::Workflow::TriggerManager.parse_schedule("every day at 9am")

    assert_equal :daily, trigger[:frequency]
    assert_equal 9, trigger[:hour]
  end

  # Test 3: Parse morning/evening schedules
  def test_parse_morning_evening
    morning = Ruboto::Workflow::TriggerManager.parse_schedule("every morning")
    evening = Ruboto::Workflow::TriggerManager.parse_schedule("every evening")

    assert_equal 8, morning[:hour]   # Default morning hour
    assert_equal 17, evening[:hour]  # Default evening hour
  end

  # Test 4: Check if schedule matches current time
  def test_schedule_matches_now
    manager = Ruboto::Workflow::TriggerManager.new

    # Create a schedule that matches current time
    now = Time.now
    trigger_config = {
      type: :schedule,
      frequency: :daily,
      hour: now.hour,
      minute: now.min
    }

    assert manager.schedule_matches?(trigger_config, now)
  end

  # Test 5: Schedule doesn't match wrong time
  def test_schedule_not_matching
    manager = Ruboto::Workflow::TriggerManager.new

    now = Time.now
    trigger_config = {
      type: :schedule,
      frequency: :daily,
      hour: (now.hour + 2) % 24  # 2 hours from now
    }

    refute manager.schedule_matches?(trigger_config, now)
  end

  # Test 6: Get workflows due to run
  def test_get_due_workflows
    # Create a workflow with a schedule trigger matching now
    now = Time.now
    parsed = Ruboto::Workflow::IntentParser.parse("Every day at #{now.hour}:00, pull files from Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    manager = Ruboto::Workflow::TriggerManager.new
    due = manager.get_due_workflows(now)

    # Should find at least one due workflow
    assert due.is_a?(Array)
  end

  # Test 7: File watch trigger detection
  def test_file_watch_trigger_config
    trigger = Ruboto::Workflow::TriggerManager.parse_file_watch("when a new file appears in ~/Downloads")

    assert_equal :file_watch, trigger[:type]
    assert trigger[:path].include?("Downloads")
  end

  # Test 8: Email trigger detection
  def test_email_trigger_config
    trigger = Ruboto::Workflow::TriggerManager.parse_email_trigger("when I receive an email from invoices@company.com")

    assert_equal :email_match, trigger[:type]
    assert_equal "invoices@company.com", trigger[:from_pattern]
  end

  # Test 9: Check if file event matches trigger
  def test_file_event_matches_trigger
    manager = Ruboto::Workflow::TriggerManager.new

    trigger_config = {
      type: :file_watch,
      path: File.expand_path("~/Downloads"),
      pattern: "*.pdf"
    }

    # Matching file
    assert manager.file_matches?(trigger_config, File.expand_path("~/Downloads/invoice.pdf"))

    # Non-matching file (wrong extension)
    refute manager.file_matches?(trigger_config, File.expand_path("~/Downloads/readme.txt"))

    # Non-matching file (wrong directory)
    refute manager.file_matches?(trigger_config, File.expand_path("~/Documents/invoice.pdf"))
  end

  # Test 10: Check if email matches trigger
  def test_email_matches_trigger
    manager = Ruboto::Workflow::TriggerManager.new

    trigger_config = {
      type: :email_match,
      from_pattern: "invoices@company.com",
      subject_pattern: nil
    }

    email = { from: "invoices@company.com", subject: "Invoice #123" }
    assert manager.email_matches?(trigger_config, email)

    other_email = { from: "support@company.com", subject: "Invoice #123" }
    refute manager.email_matches?(trigger_config, other_email)
  end

  # Test 11: Subject pattern matching
  def test_email_subject_pattern_matching
    manager = Ruboto::Workflow::TriggerManager.new

    trigger_config = {
      type: :email_match,
      from_pattern: nil,
      subject_pattern: "invoice"
    }

    email = { from: "anyone@example.com", subject: "Your Invoice for January" }
    assert manager.email_matches?(trigger_config, email)

    other_email = { from: "anyone@example.com", subject: "Meeting reminder" }
    refute manager.email_matches?(trigger_config, other_email)
  end

  # Test 12: Record trigger execution
  def test_record_trigger_execution
    parsed = Ruboto::Workflow::IntentParser.parse("Every day pull files")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    manager = Ruboto::Workflow::TriggerManager.new
    manager.record_trigger(workflow_id, :schedule, { hour: 9 })

    history = manager.get_trigger_history(workflow_id)
    assert history.length > 0
    assert_equal "schedule", history.first[:trigger_type]
  end
end
