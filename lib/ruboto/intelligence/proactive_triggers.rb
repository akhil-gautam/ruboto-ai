# frozen_string_literal: true

module Ruboto
  module Intelligence
    module ProactiveTriggers
      OVERDUE_DEFAULT_DAYS = 7

      def check_triggers
        suggestions = []
        suggestions += time_based_triggers
        suggestions += overdue_workflow_triggers
        suggestions += high_confidence_triggers
        suggestions.uniq { |s| s[:description] }.first(5)
      rescue => e
        []
      end

      def print_suggestions(suggestions)
        return if suggestions.empty?

        puts
        puts "  #{CYAN}Suggestions based on your patterns:#{RESET}"
        suggestions.each_with_index do |s, i|
          puts "    #{BOLD}#{i + 1}.#{RESET} #{s[:description]}"
        end
        puts
        puts "  #{DIM}Type a number to act on it, or just start typing.#{RESET}"
        puts
      end

      def handle_suggestion_input(input, suggestions)
        return nil if suggestions.empty?

        num = input.strip
        return nil unless num.match?(/\A\d+\z/)

        index = num.to_i - 1
        return nil if index < 0 || index >= suggestions.length

        suggestion = suggestions[index]
        reinforce_pattern(suggestion[:pattern_id]) if suggestion[:pattern_id]
        suggestion[:action_text]
      end

      def weaken_all_suggestions(suggestions)
        suggestions.each do |s|
          weaken_pattern(s[:pattern_id]) if s[:pattern_id]
        end
      end

      private

      def time_based_triggers
        sql = "SELECT id, description, conditions FROM patterns WHERE pattern_type='time_pattern' AND confidence >= 0.5;"
        rows = run_sql(sql)
        return [] if rows.empty?

        now_hour = Time.now.hour
        suggestions = []

        rows.split("\n").each do |row|
          cols = row.split("|")
          next if cols.length < 3

          pattern_id = cols[0].to_i
          description = cols[1]
          conditions = parse_json_safe(cols[2])
          next unless conditions

          hour_start = conditions["hour_start"].to_i
          hour_end = conditions["hour_end"].to_i
          tool = conditions["tool"]

          if now_hour >= hour_start && now_hour < hour_end
            suggestions << {
              description: description,
              pattern_id: pattern_id,
              action_text: action_for_tool(tool)
            }
          end
        end

        suggestions
      end

      def overdue_workflow_triggers
        sql = "SELECT name, trigger, last_run FROM workflows;"
        rows = run_sql(sql)
        return [] if rows.empty?

        suggestions = []

        rows.split("\n").each do |row|
          cols = row.split("|")
          next if cols.length < 3

          name = cols[0]
          trigger = cols[1]
          last_run = cols[2]

          next if last_run.nil? || last_run.strip.empty?

          days_since = ((Time.now - Time.parse(last_run)) / 86400).to_i rescue next
          threshold = estimate_frequency(name)

          if days_since > threshold
            suggestions << {
              description: "\"#{name}\" workflow hasn't run in #{days_since} days",
              pattern_id: nil,
              action_text: trigger
            }
          end
        end

        suggestions
      end

      def high_confidence_triggers
        sql = "SELECT id, pattern_type, description, conditions FROM patterns WHERE confidence >= 0.8 AND pattern_type IN ('recurring_request', 'tool_sequence');"
        rows = run_sql(sql)
        return [] if rows.empty?

        suggestions = []

        rows.split("\n").each do |row|
          cols = row.split("|")
          next if cols.length < 4

          pattern_id = cols[0].to_i
          pattern_type = cols[1]
          description = cols[2]
          conditions = parse_json_safe(cols[3])

          action = if pattern_type == "recurring_request" && conditions
                     conditions["keywords"]&.join(" ") || description
                   else
                     description
                   end

          suggestions << {
            description: description,
            pattern_id: pattern_id,
            action_text: action
          }
        end

        suggestions
      end

      def action_for_tool(tool)
        case tool
        when "calendar_today" then "check my calendar"
        when "mail_read" then "check my email"
        when "mail_send" then "send an email"
        when "reminder_add" then "create a reminder"
        when "clipboard_read" then "check my clipboard"
        else tool.tr("_", " ")
        end
      end

      def estimate_frequency(workflow_name)
        name = workflow_name.downcase
        return 1 if name.include?("daily")
        return 7 if name.include?("weekly")
        return 14 if name.include?("biweekly")
        return 30 if name.include?("monthly")
        OVERDUE_DEFAULT_DAYS
      end

      def parse_json_safe(str)
        return nil if str.nil? || str.strip.empty?
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
