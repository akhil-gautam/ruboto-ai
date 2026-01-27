# frozen_string_literal: true

module Ruboto
  module Intelligence
    module PatternDetector
      MIN_OCCURRENCES = 3
      SIMILARITY_THRESHOLD = 0.6
      STOP_WORDS = %w[the a an is are was were do does did my me i to for in on what how can could would should will].freeze

      def detect_patterns
        detect_recurring_requests
        detect_time_patterns
        detect_tool_sequences
      rescue => e
        # Pattern detection is non-critical — never crash startup
      end

      private

      def detect_recurring_requests
        sql = "SELECT request FROM tasks ORDER BY id DESC LIMIT 100;"
        rows = run_sql(sql)
        return if rows.empty?

        requests = rows.split("\n").map(&:strip).reject(&:empty?)
        return if requests.length < MIN_OCCURRENCES

        # Group by keyword similarity
        clusters = []
        requests.each do |req|
          words = significant_words(req)
          next if words.empty?

          matched = clusters.find { |c| word_similarity(c[:words], words) >= SIMILARITY_THRESHOLD }
          if matched
            matched[:count] += 1
            matched[:examples] << req unless matched[:examples].length >= 3
          else
            clusters << { words: words, count: 1, examples: [req] }
          end
        end

        clusters.select { |c| c[:count] >= MIN_OCCURRENCES }.each do |cluster|
          desc = "Recurring request (#{cluster[:count]}x): #{cluster[:examples].first}"
          conditions = { keywords: cluster[:words], count: cluster[:count] }.to_json

          existing = find_existing_pattern("recurring_request", cluster[:words].first(3).join(" "))
          if existing
            reinforce_pattern(existing)
          else
            save_pattern("recurring_request", desc, conditions)
          end
        end
      end

      def detect_time_patterns
        sql = "SELECT tools_used, strftime('%H', created_at) as hour, strftime('%w', created_at) as dow FROM tasks WHERE created_at IS NOT NULL ORDER BY id DESC LIMIT 100;"
        rows = run_sql(sql)
        return if rows.empty?

        buckets = Hash.new(0)
        rows.split("\n").each do |row|
          cols = row.split("|")
          next if cols.length < 3
          tools = cols[0].to_s.split(", ")
          hour = cols[1].to_i
          window_start = (hour / 2) * 2
          tools.each do |tool|
            key = "#{tool}|#{window_start}-#{window_start + 2}"
            buckets[key] += 1
          end
        end

        buckets.select { |_, count| count >= MIN_OCCURRENCES }.each do |key, count|
          tool, window = key.split("|")
          hour_start, hour_end = window.split("-").map(&:to_i)
          time_label = "#{hour_start}:00-#{hour_end}:00"
          desc = "You often use #{tool.tr('_', ' ')} between #{time_label} (#{count}x)"
          conditions = { tool: tool, hour_start: hour_start, hour_end: hour_end, count: count }.to_json

          existing = find_existing_pattern("time_pattern", tool)
          if existing
            reinforce_pattern(existing)
          else
            save_pattern("time_pattern", desc, conditions)
          end
        end
      end

      def detect_tool_sequences
        sql = "SELECT session_id, tools_used FROM tasks WHERE session_id IS NOT NULL ORDER BY session_id, id;"
        rows = run_sql(sql)
        return if rows.empty?

        sessions = Hash.new { |h, k| h[k] = [] }
        rows.split("\n").each do |row|
          cols = row.split("|")
          next if cols.length < 2
          session = cols[0]
          tools = cols[1].to_s.split(", ").map(&:strip)
          sessions[session].concat(tools)
        end

        pair_counts = Hash.new(0)
        sessions.each_value do |tools|
          unique_tools = tools.uniq
          unique_tools.combination(2).each do |pair|
            key = pair.sort.join(" + ")
            pair_counts[key] += 1
          end
        end

        pair_counts.select { |_, count| count >= MIN_OCCURRENCES }.each do |pair, count|
          desc = "Tools #{pair} frequently used together (#{count} sessions)"
          conditions = { tools: pair.split(" + "), sessions: count }.to_json

          existing = find_existing_pattern("tool_sequence", pair)
          if existing
            reinforce_pattern(existing)
          else
            save_pattern("tool_sequence", desc, conditions)
          end
        end
      end

      def significant_words(text)
        text.downcase.split(/\W+/).reject { |w| w.length < 3 || STOP_WORDS.include?(w) }
      end

      def word_similarity(words_a, words_b)
        return 0.0 if words_a.empty? || words_b.empty?
        shared = (words_a & words_b).length.to_f
        total = [words_a.length, words_b.length].max
        shared / total
      end

      def find_existing_pattern(pattern_type, keyword)
        escaped_type = pattern_type.gsub("'", "''")
        escaped_kw = keyword.to_s.gsub("'", "''")
        sql = "SELECT id FROM patterns WHERE pattern_type='#{escaped_type}' AND description LIKE '%#{escaped_kw}%' LIMIT 1;"
        result = run_sql(sql)
        result.empty? ? nil : result.strip.to_i
      end
    end
  end
end
