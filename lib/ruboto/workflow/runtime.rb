# frozen_string_literal: true

module Ruboto
  module Workflow
    class Runtime
      attr_reader :steps, :state, :current_step_index, :mode

      MODES = [:supervised, :autonomous].freeze

      def initialize(steps, mode: :supervised)
        @steps = steps
        @state = {}
        @current_step_index = 0
        @mode = mode
        @log = []
      end

      def resolve_params(params)
        resolved = {}
        params.each do |key, value|
          resolved[key] = resolve_value(value)
        end
        resolved
      end

      def resolve_value(value)
        case value
        when String
          if value.start_with?("$")
            var_name = value[1..]
            @state[var_name]
          else
            value
          end
        when Array
          value.map { |v| resolve_value(v) }
        when Hash
          value.transform_values { |v| resolve_value(v) }
        else
          value
        end
      end

      def preview_step(step)
        resolved = resolve_params(step.params)
        lines = []
        lines << "Step #{step.id}: #{step.description}"
        lines << "  Tool: #{step.tool}"
        lines << "  Params: #{resolved.inspect}"
        lines << "  Output: $#{step.output_key}" if step.output_key
        lines.join("\n")
      end

      def current_step
        @steps[@current_step_index]
      end

      def advance
        @current_step_index += 1
      end

      def complete?
        @current_step_index >= @steps.length
      end

      def store_result(key, value)
        @state[key] = value if key
      end

      def log_event(event_type, data = {})
        @log << {
          timestamp: Time.now,
          step_id: current_step&.id,
          event: event_type,
          data: data
        }
      end

      def run_log
        @log
      end

      def to_h
        {
          steps: @steps.map(&:to_h),
          state: @state,
          current_step_index: @current_step_index,
          mode: @mode,
          log: @log
        }
      end
    end
  end
end
