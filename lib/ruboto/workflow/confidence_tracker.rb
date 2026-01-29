# frozen_string_literal: true

module Ruboto
  module Workflow
    class ConfidenceTracker
      APPROVAL_INCREMENT = 0.2
      CORRECTION_DECREMENT = 0.3
      SKIP_DECREMENT = 0.5
      AUTONOMOUS_THRESHOLD = 0.8
      MIN_RUNS_FOR_GRADUATION = 5
      MAX_RECENT_CORRECTIONS = 0

      attr_reader :workflow_id, :step_order

      def initialize(workflow_id:, step_order:)
        @workflow_id = workflow_id
        @step_order = step_order
      end

      # Called when user approves step without changes
      def on_approval(current_confidence)
        clamp(current_confidence + APPROVAL_INCREMENT)
      end

      # Called when user makes a correction to step output or params
      def on_correction(current_confidence, correction_type:, original:, corrected:)
        record_correction(correction_type, original, corrected)
        clamp(current_confidence - CORRECTION_DECREMENT)
      end

      # Called when user skips a step
      def on_skip(current_confidence)
        clamp(current_confidence - SKIP_DECREMENT)
      end

      # Check if step has enough confidence for autonomous execution
      def autonomous?(confidence)
        confidence >= AUTONOMOUS_THRESHOLD
      end

      # Check if step is ready to graduate from supervised to autonomous
      # Requirements:
      # - Confidence >= threshold (80%)
      # - Minimum number of successful runs (5)
      # - No corrections in last N runs (0 recent corrections allowed)
      def ready_for_graduation?(confidence:, run_count:, recent_corrections:)
        return false if confidence < AUTONOMOUS_THRESHOLD
        return false if run_count < MIN_RUNS_FOR_GRADUATION
        return false if recent_corrections > MAX_RECENT_CORRECTIONS

        true
      end

      # Get graduation status with reasons
      def graduation_status(confidence:, run_count:, recent_corrections:)
        reasons = []

        if confidence < AUTONOMOUS_THRESHOLD
          reasons << "Confidence #{(confidence * 100).round}% below threshold (#{(AUTONOMOUS_THRESHOLD * 100).round}%)"
        end

        if run_count < MIN_RUNS_FOR_GRADUATION
          reasons << "Only #{run_count} runs (need #{MIN_RUNS_FOR_GRADUATION})"
        end

        if recent_corrections > MAX_RECENT_CORRECTIONS
          reasons << "#{recent_corrections} recent corrections (need 0)"
        end

        {
          ready: reasons.empty?,
          reasons: reasons,
          confidence: confidence,
          run_count: run_count,
          recent_corrections: recent_corrections
        }
      end

      # Get all corrections for this step
      def get_corrections
        sql = <<~SQL
          SELECT correction_type, original_value, corrected_value, created_at
          FROM step_corrections
          WHERE workflow_id = #{@workflow_id} AND step_order = #{@step_order}
          ORDER BY created_at DESC;
        SQL
        result = Ruboto.run_sql(sql).strip
        return [] if result.empty?

        result.split("\n").map do |row|
          cols = row.split("|")
          {
            correction_type: cols[0],
            original_value: cols[1],
            corrected_value: cols[2],
            created_at: cols[3]
          }
        end
      end

      # Analyze correction history to infer patterns
      # Returns array of learned patterns that can be applied automatically
      def infer_patterns
        corrections = get_corrections
        return [] if corrections.length < MIN_CORRECTIONS_FOR_PATTERN

        patterns = []

        # Group corrections by type
        by_type = corrections.group_by { |c| c[:correction_type] }

        # Look for filter patterns (user repeatedly removes similar items)
        if by_type["output_filter"]&.length.to_i >= MIN_CORRECTIONS_FOR_PATTERN
          filter_corrections = by_type["output_filter"]
          common_patterns = find_common_patterns(filter_corrections.map { |c| c[:original_value] })

          common_patterns.each do |pattern|
            patterns << {
              type: "auto_filter",
              pattern: pattern,
              action: "filter",
              confidence: calculate_pattern_confidence(filter_corrections.length),
              source: "corrections"
            }
          end
        end

        # Look for param edit patterns (user repeatedly changes same param the same way)
        if by_type["param_edit"]&.length.to_i >= MIN_CORRECTIONS_FOR_PATTERN
          param_corrections = by_type["param_edit"]
          # Check if corrections consistently change to the same value
          corrected_values = param_corrections.map { |c| c[:corrected_value] }
          if corrected_values.uniq.length == 1
            patterns << {
              type: "auto_param",
              pattern: corrected_values.first,
              action: "replace",
              confidence: calculate_pattern_confidence(param_corrections.length),
              source: "corrections"
            }
          end
        end

        patterns
      end

      MIN_CORRECTIONS_FOR_PATTERN = 3

      private

      # Find common substrings/patterns in a list of strings
      def find_common_patterns(strings)
        return [] if strings.empty?

        patterns = []

        # Look for common file extensions
        extensions = strings.map { |s| File.extname(s.to_s) }.compact.reject(&:empty?)
        ext_counts = extensions.tally
        ext_counts.each do |ext, count|
          patterns << "*.#{ext.delete('.')}" if count >= MIN_CORRECTIONS_FOR_PATTERN
        end

        # Look for common prefixes
        prefixes = strings.map { |s| s.to_s.split(/[_\-\/]/).first }.compact
        prefix_counts = prefixes.tally
        prefix_counts.each do |prefix, count|
          patterns << "#{prefix}*" if count >= MIN_CORRECTIONS_FOR_PATTERN && prefix.length > 2
        end

        # Look for common substrings
        if strings.length >= MIN_CORRECTIONS_FOR_PATTERN
          common = find_longest_common_substring(strings.map(&:to_s))
          patterns << "*#{common}*" if common && common.length >= 3
        end

        patterns.uniq
      end

      def find_longest_common_substring(strings)
        return nil if strings.empty?
        return strings.first if strings.length == 1

        shortest = strings.min_by(&:length)
        return nil if shortest.nil? || shortest.empty?

        # Try progressively shorter substrings
        (shortest.length).downto(3) do |len|
          (0..shortest.length - len).each do |start|
            substr = shortest[start, len]
            return substr if strings.all? { |s| s.include?(substr) }
          end
        end

        nil
      end

      def calculate_pattern_confidence(correction_count)
        # More corrections = higher confidence in the pattern
        base = 0.5
        increment = 0.1 * [correction_count - MIN_CORRECTIONS_FOR_PATTERN, 5].min
        [base + increment, 0.9].min
      end

      def clamp(value)
        [[value, 0.0].max, 1.0].min
      end

      def record_correction(correction_type, original, corrected)
        Storage.record_correction(@workflow_id, @step_order, correction_type, original, corrected)
      end
    end
  end
end
