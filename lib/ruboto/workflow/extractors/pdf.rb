# frozen_string_literal: true

require "open3"

module Ruboto
  module Workflow
    module Extractors
      module PDF
        extend self

        def extract_text(file_path)
          return nil unless File.exist?(file_path)

          # Try mdimport first
          text = extract_via_mdimport(file_path)
          return text if text && !text.empty?

          # Fallback to textutil
          text = extract_via_textutil(file_path)
          return text if text && !text.empty?

          # Last resort: AppleScript with PDFKit
          extract_via_applescript(file_path)
        rescue => e
          nil
        end

        def extract_fields(text, fields)
          result = {}
          fields.each do |field|
            case field.downcase
            when "vendor", "company", "from"
              result[:vendor] = extract_vendor(text)
            when "amount", "total", "price"
              result[:amount] = extract_amount(text)
            when "date", "invoice_date"
              result[:date] = extract_date(text)
            when "invoice_number", "invoice", "number"
              result[:invoice_number] = extract_invoice_number(text)
            end
          end
          result
        end

        def batch_extract(file_paths, fields)
          file_paths.map do |path|
            text = extract_text(path)
            next { file: path, error: "Could not extract text" } unless text
            extracted = extract_fields(text, fields)
            { file: path, text: text[0, 500], data: extracted }
          end
        end

        private

        def extract_via_mdimport(file_path)
          output, status = Open3.capture2("mdimport", "-d1", file_path)
          return nil unless status.success?
          output
        rescue
          nil
        end

        def extract_via_textutil(file_path)
          tmp_file = "/tmp/ruboto_pdf_#{Process.pid}.txt"
          _, status = Open3.capture2("textutil", "-convert", "txt", "-output", tmp_file, file_path)
          return nil unless status.success? && File.exist?(tmp_file)
          text = File.read(tmp_file)
          File.delete(tmp_file) rescue nil
          text
        rescue
          nil
        end

        def extract_via_applescript(file_path)
          script = <<~APPLESCRIPT
            use framework "Quartz"
            use scripting additions

            set pdfPath to POSIX path of "#{file_path}"
            set pdfURL to current application's NSURL's fileURLWithPath:pdfPath
            set pdfDoc to current application's PDFDocument's alloc()'s initWithURL:pdfURL

            if pdfDoc is missing value then
              return ""
            end if

            set pageCount to pdfDoc's pageCount()
            set allText to ""

            repeat with i from 0 to (pageCount - 1)
              set pdfPage to (pdfDoc's pageAtIndex:i)
              set pageText to (pdfPage's |string|())
              if pageText is not missing value then
                set allText to allText & (pageText as text) & "\n"
              end if
            end repeat

            return allText
          APPLESCRIPT

          output, status = Open3.capture2("osascript", "-l", "AppleScript", "-e", script)
          status.success? ? output : nil
        rescue
          nil
        end

        def extract_vendor(text)
          patterns = [
            /(?:from|vendor|company|billed\s+by)[:\s]+([A-Z][A-Za-z\s&.,]+?)(?:\n|$)/i,
            /^([A-Z][A-Za-z\s&.,]+(?:Inc|LLC|Corp|Ltd|Co)\.?)/m
          ]
          patterns.each do |pattern|
            match = text.match(pattern)
            return match[1].strip if match
          end
          nil
        end

        def extract_amount(text)
          patterns = [
            /(?:total|amount|due|balance)[:\s]*\$?([\d,]+\.?\d*)/i,
            /\$\s*([\d,]+\.?\d*)/
          ]
          amounts = []
          patterns.each do |pattern|
            text.scan(pattern) { |m| amounts << m[0].gsub(",", "").to_f }
          end
          amounts.max
        end

        def extract_date(text)
          patterns = [
            /(?:date|dated|invoice\s+date)[:\s]*(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})/i,
            /(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})/,
            /(\w+\s+\d{1,2},?\s+\d{4})/i
          ]
          patterns.each do |pattern|
            match = text.match(pattern)
            return match[1] if match
          end
          nil
        end

        def extract_invoice_number(text)
          patterns = [
            /(?:invoice|inv|invoice\s*#|inv\s*#)[:\s]*([A-Z0-9\-]+)/i,
            /#\s*([A-Z0-9\-]+)/i
          ]
          patterns.each do |pattern|
            match = text.match(pattern)
            return match[1] if match
          end
          nil
        end
      end
    end
  end
end
