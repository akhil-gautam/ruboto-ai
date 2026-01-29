# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require_relative "../../lib/ruboto"
require_relative "../../lib/ruboto/workflow"

class ConfidenceTrackerTest < Minitest::Test
  DELTA = 0.001
  def setup
    @test_db = "/tmp/ruboto_confidence_test_#{$$}.db"
    ENV["RUBOTO_DB_PATH"] = @test_db
    Ruboto.ensure_db_exists
  end

  def teardown
    FileUtils.rm_f(@test_db)
    ENV.delete("RUBOTO_DB_PATH")
  end

  # Test 1: Approval without changes increases confidence
  def test_approval_increases_confidence
    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: 1, step_order: 1)
    initial = 0.0

    new_confidence = tracker.on_approval(initial)

    assert_equal 0.2, new_confidence
  end

  # Test 2: Confidence caps at 1.0
  def test_confidence_caps_at_one
    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: 1, step_order: 1)

    new_confidence = tracker.on_approval(0.95)

    assert_equal 1.0, new_confidence
  end

  # Test 3: Correction decreases confidence
  def test_correction_decreases_confidence
    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: 1, step_order: 1)

    new_confidence = tracker.on_correction(0.8, correction_type: "output_edit", original: "old", corrected: "new")

    assert_equal 0.5, new_confidence  # -0.3 on correction
  end

  # Test 4: Skip decreases confidence more
  def test_skip_decreases_confidence
    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: 1, step_order: 1)

    new_confidence = tracker.on_skip(0.8)

    assert_in_delta 0.3, new_confidence, 0.001  # -0.5 on skip
  end

  # Test 5: Confidence doesn't go below 0
  def test_confidence_floors_at_zero
    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: 1, step_order: 1)

    new_confidence = tracker.on_skip(0.2)

    assert_equal 0.0, new_confidence
  end

  # Test 6: Check if step is ready for autonomous execution
  def test_ready_for_autonomous_at_threshold
    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: 1, step_order: 1)

    refute tracker.autonomous?(0.79)
    assert tracker.autonomous?(0.80)
    assert tracker.autonomous?(1.0)
  end

  # Test 7: Correction is recorded to database
  def test_correction_recorded_to_database
    # Create a workflow first
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: workflow_id, step_order: 1)
    tracker.on_correction(0.5, correction_type: "param_edit", original: "*.pdf", corrected: "*.txt")

    # Verify correction was recorded
    corrections = tracker.get_corrections
    assert_equal 1, corrections.length
    assert_equal "param_edit", corrections.first[:correction_type]
    assert_equal "*.pdf", corrections.first[:original_value]
    assert_equal "*.txt", corrections.first[:corrected_value]
  end

  # Test 8: Multiple corrections tracked
  def test_multiple_corrections_affect_confidence
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: workflow_id, step_order: 1)

    # Start at 0.8, make two corrections
    conf = tracker.on_correction(0.8, correction_type: "output_edit", original: "a", corrected: "b")
    assert_equal 0.5, conf

    conf = tracker.on_correction(conf, correction_type: "output_edit", original: "b", corrected: "c")
    assert_equal 0.2, conf

    corrections = tracker.get_corrections
    assert_equal 2, corrections.length
  end

  # Test 9: Pattern inference - detect repeated corrections
  def test_infer_patterns_from_corrections
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: workflow_id, step_order: 1)

    # Simulate repeated corrections: user keeps removing .tmp files
    tracker.on_correction(0.5, correction_type: "output_filter", original: "file1.tmp", corrected: "removed")
    tracker.on_correction(0.5, correction_type: "output_filter", original: "file2.tmp", corrected: "removed")
    tracker.on_correction(0.5, correction_type: "output_filter", original: "file3.tmp", corrected: "removed")

    patterns = tracker.infer_patterns
    assert patterns.length > 0
    assert patterns.any? { |p| p[:pattern].include?("tmp") || p[:action] == "filter" }
  end

  # Test 10: Pattern inference - no patterns with insufficient data
  def test_no_patterns_with_single_correction
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: workflow_id, step_order: 1)
    tracker.on_correction(0.5, correction_type: "param_edit", original: "*.pdf", corrected: "*.txt")

    patterns = tracker.infer_patterns
    assert_equal 0, patterns.length  # Need multiple similar corrections
  end

  # Test 11: Graduation eligibility - requires min runs without corrections
  def test_graduation_requires_minimum_runs
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: workflow_id, step_order: 1)

    # With 0 runs, not ready for graduation
    refute tracker.ready_for_graduation?(confidence: 0.85, run_count: 0, recent_corrections: 0)

    # With enough runs and no recent corrections, ready
    assert tracker.ready_for_graduation?(confidence: 0.85, run_count: 5, recent_corrections: 0)
  end

  # Test 12: Graduation blocked by recent corrections
  def test_graduation_blocked_by_recent_corrections
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: workflow_id, step_order: 1)

    # High confidence, many runs, but recent correction - not ready
    refute tracker.ready_for_graduation?(confidence: 0.9, run_count: 10, recent_corrections: 1)
  end

  # Test 13: Graduation requires minimum confidence
  def test_graduation_requires_minimum_confidence
    parsed = Ruboto::Workflow::IntentParser.parse("Pull files from ~/Downloads")
    steps = Ruboto::Workflow::PlanGenerator.generate(parsed)
    workflow_id = Ruboto::Workflow::Storage.save_workflow(parsed, steps)

    tracker = Ruboto::Workflow::ConfidenceTracker.new(workflow_id: workflow_id, step_order: 1)

    # Many runs, no corrections, but low confidence - not ready
    refute tracker.ready_for_graduation?(confidence: 0.5, run_count: 10, recent_corrections: 0)
  end
end
