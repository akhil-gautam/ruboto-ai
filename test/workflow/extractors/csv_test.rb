# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../../../lib/ruboto/workflow"

class CSVExtractorTest < Minitest::Test
  def test_read_csv
    csv_content = "name,amount,date\nAcme,100.00,2026-01-15\nGlobex,250.50,2026-01-20"
    file = Tempfile.new(["test", ".csv"])
    file.write(csv_content)
    file.close

    result = Ruboto::Workflow::Extractors::CSV.read(file.path)
    assert_equal 2, result.length
    assert_equal "Acme", result[0]["name"]
  ensure
    file.unlink
  end

  def test_append_row
    file = Tempfile.new(["test", ".csv"])
    file.write("name,amount\nExisting,50.00\n")
    file.close

    Ruboto::Workflow::Extractors::CSV.append(file.path, { "name" => "New", "amount" => "100.00" })

    content = File.read(file.path)
    assert_match /New,100.00/, content
  ensure
    file.unlink
  end

  def test_append_creates_file_with_headers
    file = Tempfile.new(["test", ".csv"])
    file.close
    File.delete(file.path)

    Ruboto::Workflow::Extractors::CSV.append(file.path, { "name" => "First", "amount" => "100.00" })

    content = File.read(file.path)
    assert_match /name,amount/, content
    assert_match /First,100.00/, content
  ensure
    File.delete(file.path) if File.exist?(file.path)
  end

  def test_write_rows
    file = Tempfile.new(["test", ".csv"])
    file.close

    rows = [
      { "name" => "A", "value" => "1" },
      { "name" => "B", "value" => "2" }
    ]
    Ruboto::Workflow::Extractors::CSV.write(file.path, rows)

    result = Ruboto::Workflow::Extractors::CSV.read(file.path)
    assert_equal 2, result.length
  ensure
    file.unlink
  end
end
