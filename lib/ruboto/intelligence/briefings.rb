# frozen_string_literal: true

module Ruboto
  module Intelligence
    module Briefings
      def run_briefing(mode)
        ensure_db_exists

        mode = auto_briefing_mode if mode == "auto"

        case mode
        when "morning"
          run_morning_briefing
        when "evening"
          run_evening_briefing
        else
          $stderr.puts "Unknown briefing mode: #{mode}"
          exit 1
        end
      end

      private

      def auto_briefing_mode
        Time.now.hour < 14 ? "morning" : "evening"
      end

      def run_morning_briefing
        sections = []

        # Calendar
        calendar_result = tool_macos_auto({ "action" => "calendar_today" })
        unless calendar_result.include?("error") || calendar_result.strip.empty?
          sections << "CALENDAR:\n#{calendar_result}"
        end

        # Email
        mail_result = tool_macos_auto({ "action" => "mail_read", "limit" => 5 })
        unless mail_result.include?("error") || mail_result.strip.empty?
          sections << "UNREAD EMAIL (latest 5):\n#{mail_result}"
        end

        # Proactive suggestions
        detect_patterns
        suggestions = check_triggers
        unless suggestions.empty?
          lines = suggestions.map.with_index { |s, i| "  #{i + 1}. #{s[:description]}" }
          sections << "SUGGESTIONS:\n#{lines.join("\n")}"
        end

        # Overdue tasks
        overdue = find_overdue_tasks
        unless overdue.empty?
          sections << "NEEDS ATTENTION:\n#{overdue}"
        end

        if sections.empty?
          summary = "Good morning! Nothing urgent on your plate."
        else
          summary = "Good morning! Here's your briefing:\n\n#{sections.join("\n\n")}"
        end

        puts summary
        deliver_notification("Morning Briefing", summary[0, 200])
        create_briefing_note("Morning Briefing", summary)
      end

      def run_evening_briefing
        sections = []

        # Today's completed tasks
        sql = "SELECT request, outcome FROM tasks WHERE date(created_at) = date('now') AND success = 1 ORDER BY id;"
        completed = run_sql(sql)
        unless completed.strip.empty?
          sections << "COMPLETED TODAY:\n#{format_task_list(completed)}"
        end

        # Failed tasks
        sql_failed = "SELECT request, outcome FROM tasks WHERE date(created_at) = date('now') AND success = 0 ORDER BY id;"
        failed = run_sql(sql_failed)
        unless failed.strip.empty?
          sections << "NEEDS RETRY:\n#{format_task_list(failed)}"
        end

        # Suggestions for tomorrow
        suggestions = check_triggers
        unless suggestions.empty?
          lines = suggestions.select { |s| s[:pattern_id] }.map { |s| "  - #{s[:description]}" }
          sections << "FOR TOMORROW:\n#{lines.join("\n")}" unless lines.empty?
        end

        if sections.empty?
          summary = "End of day — no tasks recorded today."
        else
          summary = "End of day summary:\n\n#{sections.join("\n\n")}"
        end

        puts summary
        deliver_notification("Evening Summary", summary[0, 200])
        create_briefing_note("Evening Summary", summary)
      end

      def find_overdue_tasks
        sql = "SELECT request FROM tasks WHERE success = 0 AND created_at > datetime('now', '-3 days') ORDER BY id DESC LIMIT 5;"
        result = run_sql(sql)
        return "" if result.strip.empty?
        result.split("\n").map { |r| "  - #{r.strip[0, 60]}" }.join("\n")
      end

      def format_task_list(data)
        data.split("\n").map do |row|
          cols = row.split("|")
          next if cols.empty?
          "  - #{cols[0].to_s.strip[0, 60]}"
        end.compact.join("\n")
      end

      def deliver_notification(title, body)
        tool_macos_auto({ "action" => "notify", "title" => title, "message" => body })
      rescue => e
        # Notification is non-critical
      end

      def create_briefing_note(title, body)
        date = Time.now.strftime("%Y-%m-%d")
        tool_macos_auto({ "action" => "note_create", "title" => "#{title} — #{date}", "body" => body })
      rescue => e
        # Note creation is non-critical
      end
    end
  end
end
