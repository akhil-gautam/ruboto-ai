# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/ruboto/workflow"

class PDFExtractorTest < Minitest::Test
  def test_extract_text_from_pdf
    skip "Create test/fixtures/sample_invoice.pdf to run this test" unless File.exist?("test/fixtures/sample_invoice.pdf")
    result = Ruboto::Workflow::Extractors::PDF.extract_text("test/fixtures/sample_invoice.pdf")
    assert result.is_a?(String)
    assert result.length > 0
  end

  def test_extract_fields_from_text
    text = "Invoice #12345\nVendor: Acme Corp\nAmount: $1,234.56\nDate: 2026-01-15"
    result = Ruboto::Workflow::Extractors::PDF.extract_fields(text, ["vendor", "amount", "date"])
    assert result[:vendor]
    assert result[:amount]
  end

  def test_handles_missing_file
    result = Ruboto::Workflow::Extractors::PDF.extract_text("/nonexistent/file.pdf")
    assert_nil result
  end
end
