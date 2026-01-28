# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/ruboto/workflow"

class PlanGeneratorTest < Minitest::Test
  def setup
    @parsed = Ruboto::Workflow::IntentParser.parse(
      "Every Friday pull PDFs from ~/Downloads, extract vendor and amount, add to ~/expenses.csv"
    )
  end

  def test_generates_steps
    steps = Ruboto::Workflow::PlanGenerator.generate(@parsed)
    assert steps.is_a?(Array)
    assert steps.length > 0
  end

  def test_first_step_is_file_glob
    steps = Ruboto::Workflow::PlanGenerator.generate(@parsed)
    assert_equal "file_glob", steps.first.tool
  end

  def test_steps_have_output_keys
    steps = Ruboto::Workflow::PlanGenerator.generate(@parsed)
    collect_step = steps.find { |s| s.tool == "file_glob" }
    assert collect_step.output_key
  end

  def test_steps_reference_previous_outputs
    steps = Ruboto::Workflow::PlanGenerator.generate(@parsed)
    extract_step = steps.find { |s| s.tool == "pdf_extract" }
    assert extract_step.params[:files]&.start_with?("$") if extract_step
  end
end
