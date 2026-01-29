# frozen_string_literal: true

require "json"
require "fileutils"

module Ruboto
  module Workflow
    class AuditLogger
      DEFAULT_LOG_DIR = File.expand_path("~/.ruboto/logs/workflows")

      attr_reader :workflow_id, :workflow_name, :run_id, :log_file

      def initialize(workflow_id:, workflow_name:, run_id:)
        @workflow_id = workflow_id
        @workflow_name = workflow_name
        @run_id = run_id
        @events = []
        @start_time = Time.now

        # Create log directory and file
        log_dir = ENV["RUBOTO_LOG_DIR"] || DEFAULT_LOG_DIR
        workflow_dir = File.join(log_dir, sanitize_name(workflow_name))
        FileUtils.mkdir_p(workflow_dir)

        @log_file = File.join(workflow_dir, "run_#{run_id}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
      end

      # Log workflow start
      def log_start(trigger_type: nil, trigger_data: nil)
        log_event("workflow_start", {
          workflow_id: @workflow_id,
          workflow_name: @workflow_name,
          run_id: @run_id,
          trigger_type: trigger_type,
          trigger_data: trigger_data,
          started_at: @start_time.iso8601
        })
      end

      # Log step execution start
      def log_step_start(step)
        log_event("step_start", {
          step_id: step.id,
          tool: step.tool,
          description: step.description,
          confidence: step.confidence,
          params: sanitize_params(step.params)
        })
      end

      # Log step execution result
      def log_step_result(step, result, resolved_params)
        log_event("step_result", {
          step_id: step.id,
          tool: step.tool,
          success: result[:success],
          summary: result[:summary],
          error: result[:error],
          output_preview: truncate_output(result[:output]),
          resolved_params: sanitize_params(resolved_params),
          duration_ms: result[:duration_ms]
        })
      end

      # Log user correction
      def log_correction(step, correction_type, original, corrected)
        log_event("user_correction", {
          step_id: step.id,
          tool: step.tool,
          correction_type: correction_type,
          original: truncate_value(original),
          corrected: truncate_value(corrected)
        })
      end

      # Log confidence change
      def log_confidence_change(step, old_confidence, new_confidence, reason)
        log_event("confidence_change", {
          step_id: step.id,
          old_confidence: old_confidence,
          new_confidence: new_confidence,
          change: (new_confidence - old_confidence).round(2),
          reason: reason
        })
      end

      # Log user action (approve, skip, cancel)
      def log_user_action(step, action)
        log_event("user_action", {
          step_id: step.id,
          action: action
        })
      end

      # Log workflow completion
      def log_complete(status, final_state)
        duration = Time.now - @start_time

        log_event("workflow_complete", {
          status: status,
          duration_seconds: duration.round(2),
          steps_executed: count_steps_executed,
          steps_successful: count_steps_successful,
          final_state_keys: final_state.keys
        })

        # Write full log to file
        write_log_file
      end

      # Log error
      def log_error(context, error)
        log_event("error", {
          context: context,
          error_class: error.class.name,
          error_message: error.message,
          backtrace: error.backtrace&.first(5)
        })
      end

      # Get all events for this run
      def events
        @events.dup
      end

      # Get log file path
      def log_path
        @log_file
      end

      # Class method to list audit logs for a workflow
      def self.list_logs(workflow_name, limit: 10)
        log_dir = ENV["RUBOTO_LOG_DIR"] || DEFAULT_LOG_DIR
        workflow_dir = File.join(log_dir, sanitize_name(workflow_name))

        return [] unless Dir.exist?(workflow_dir)

        Dir.glob(File.join(workflow_dir, "run_*.json"))
           .sort_by { |f| File.mtime(f) }
           .reverse
           .first(limit)
      end

      # Class method to read a specific audit log
      def self.read_log(log_path)
        return nil unless File.exist?(log_path)
        JSON.parse(File.read(log_path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      # Class method to get audit summary for a workflow
      def self.get_summary(workflow_name, limit: 10)
        logs = list_logs(workflow_name, limit: limit)

        logs.map do |log_path|
          data = read_log(log_path)
          next nil unless data

          start_event = data[:events]&.find { |e| e[:type] == "workflow_start" }
          end_event = data[:events]&.find { |e| e[:type] == "workflow_complete" }

          {
            log_file: File.basename(log_path),
            run_id: data[:run_id],
            started_at: start_event&.dig(:data, :started_at),
            status: end_event&.dig(:data, :status),
            duration: end_event&.dig(:data, :duration_seconds),
            corrections: data[:events]&.count { |e| e[:type] == "user_correction" } || 0
          }
        end.compact
      end

      private

      def log_event(event_type, data)
        @events << {
          type: event_type,
          timestamp: Time.now.iso8601,
          data: data
        }
      end

      def write_log_file
        log_data = {
          version: "1.0",
          workflow_id: @workflow_id,
          workflow_name: @workflow_name,
          run_id: @run_id,
          events: @events
        }

        File.write(@log_file, JSON.pretty_generate(log_data))
      rescue => e
        # Logging should not fail the workflow
      end

      def sanitize_name(name)
        name.to_s.gsub(/[^a-zA-Z0-9_-]/, '_').downcase
      end

      def self.sanitize_name(name)
        name.to_s.gsub(/[^a-zA-Z0-9_-]/, '_').downcase
      end

      def sanitize_params(params)
        return {} unless params.is_a?(Hash)

        params.transform_values do |v|
          case v
          when String
            v.length > 500 ? "#{v[0, 500]}..." : v
          when Array
            v.length > 20 ? v.first(20) + ["... (#{v.length - 20} more)"] : v
          else
            v
          end
        end
      end

      def truncate_output(output)
        case output
        when String
          output.length > 200 ? "#{output[0, 200]}..." : output
        when Array
          output.length > 5 ? { count: output.length, sample: output.first(3) } : output
        when Hash
          output.keys.length > 10 ? { keys: output.keys.first(10), total_keys: output.keys.length } : output
        else
          output.to_s[0, 200]
        end
      end

      def truncate_value(value)
        str = value.to_s
        str.length > 500 ? "#{str[0, 500]}..." : str
      end

      def count_steps_executed
        @events.count { |e| e[:type] == "step_result" }
      end

      def count_steps_successful
        @events.count { |e| e[:type] == "step_result" && e[:data][:success] }
      end
    end
  end
end
