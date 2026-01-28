# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/ruboto/workflow"

class IntentParserTest < Minitest::Test
  def test_parse_schedule_trigger
    result = Ruboto::Workflow::IntentParser.parse("Every Friday at 5pm, pull invoices")
    assert_equal :schedule, result.trigger[:type]
  end

  def test_parse_file_source
    result = Ruboto::Workflow::IntentParser.parse("pull invoices from the Downloads folder")
    assert_equal :local_files, result.sources.first[:type]
  end

  def test_parse_pdf_source
    result = Ruboto::Workflow::IntentParser.parse("extract data from PDF invoices")
    sources = result.sources.find { |s| s[:hint] == "pdf" }
    assert sources
  end

  def test_parse_file_destination
    result = Ruboto::Workflow::IntentParser.parse("add them to my expenses.csv")
    dest = result.destinations.find { |d| d[:type] == :file }
    assert dest
    assert_match /expenses\.csv/, dest[:path]
  end

  def test_parse_web_form_destination
    result = Ruboto::Workflow::IntentParser.parse("fill out the Workday form")
    dest = result.destinations.find { |d| d[:type] == :web_form }
    assert dest
  end

  def test_generate_name
    result = Ruboto::Workflow::IntentParser.parse("Every Friday pull invoices and add to expenses")
    assert_match /friday|invoices|expenses/, result.name
  end
end
