# frozen_string_literal: true

require "csv"

module Ruboto
  module Workflow
    module Extractors
      module CSV
        extend self

        def read(file_path)
          return [] unless File.exist?(file_path)
          rows = []
          ::CSV.foreach(file_path, headers: true) do |row|
            rows << row.to_h
          end
          rows
        rescue => e
          []
        end

        def write(file_path, rows, headers: nil)
          return if rows.empty?
          headers ||= rows.first.keys
          ::CSV.open(file_path, "w") do |csv|
            csv << headers
            rows.each do |row|
              csv << headers.map { |h| row[h] || row[h.to_sym] }
            end
          end
          true
        rescue => e
          false
        end

        def append(file_path, row)
          file_exists = File.exist?(file_path) && File.size(file_path) > 0
          headers = row.keys

          if file_exists
            existing_headers = ::CSV.read(file_path, headers: true).headers
            headers = existing_headers if existing_headers && !existing_headers.empty?
          end

          ::CSV.open(file_path, "a") do |csv|
            csv << headers unless file_exists
            csv << headers.map { |h| row[h] || row[h.to_s] || row[h.to_sym] }
          end
          true
        rescue => e
          false
        end

        def append_rows(file_path, rows)
          rows.each { |row| append(file_path, row) }
          true
        end

        def filter(rows, condition)
          case condition
          when Hash
            rows.select do |row|
              condition.all? { |k, v| row[k.to_s] == v || row[k.to_sym] == v }
            end
          when Proc
            rows.select(&condition)
          when String
            rows.select { |row| evaluate_condition(row, condition) }
          else
            rows
          end
        end

        private

        def evaluate_condition(row, condition)
          if condition =~ /(\w+)\s*(>|<|>=|<=|==|!=)\s*(.+)/
            field, op, value = $1, $2, $3.strip
            row_value = row[field] || row[field.to_sym]
            return false unless row_value

            begin
              row_num = row_value.to_s.gsub(/[$,]/, "").to_f
              cmp_num = value.gsub(/[$,]/, "").to_f
              case op
              when ">" then row_num > cmp_num
              when "<" then row_num < cmp_num
              when ">=" then row_num >= cmp_num
              when "<=" then row_num <= cmp_num
              when "==" then row_num == cmp_num
              when "!=" then row_num != cmp_num
              end
            rescue
              row_value.to_s.send(op == "==" ? "==" : "!=", value)
            end
          else
            true
          end
        end
      end
    end
  end
end
