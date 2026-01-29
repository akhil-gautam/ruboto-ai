# frozen_string_literal: true

module Ruboto
  module Workflow
    class TriggerManager
      DAY_NAMES = %w[sunday monday tuesday wednesday thursday friday saturday].freeze
      DEFAULT_MORNING_HOUR = 8
      DEFAULT_EVENING_HOUR = 17

      def initialize
        @last_check = {}
      end

      # Parse a schedule description into trigger config
      def self.parse_schedule(description)
        desc = description.to_s.downcase

        config = {
          type: :schedule,
          frequency: :manual,
          hour: nil,
          minute: 0,
          day_of_week: nil,
          day_of_month: nil
        }

        # Check for morning/evening
        if desc.include?("morning")
          config[:frequency] = :daily
          config[:hour] = DEFAULT_MORNING_HOUR
          return config
        end

        if desc.include?("evening")
          config[:frequency] = :daily
          config[:hour] = DEFAULT_EVENING_HOUR
          return config
        end

        # Check for day of week
        DAY_NAMES.each_with_index do |day, idx|
          if desc.include?(day)
            config[:frequency] = :weekly
            config[:day_of_week] = idx
            break
          end
        end

        # Check for "every day"
        if desc =~ /every\s+day/i
          config[:frequency] = :daily
        end

        # Check for "every month" or specific day of month
        if desc =~ /every\s+month/i || desc =~ /(\d+)(st|nd|rd|th)\s+of/
          config[:frequency] = :monthly
          config[:day_of_month] = $1.to_i if $1
        end

        # Parse time (e.g., "5pm", "9am", "17:00", "9:30am")
        if desc =~ /(\d{1,2}):?(\d{2})?\s*(am|pm)?/i
          hour = $1.to_i
          minute = $2.to_i rescue 0
          period = $3&.downcase

          if period == "pm" && hour < 12
            hour += 12
          elsif period == "am" && hour == 12
            hour = 0
          end

          config[:hour] = hour
          config[:minute] = minute
        end

        # Default to daily if we have a time but no explicit frequency
        if config[:hour] && config[:frequency] == :manual
          config[:frequency] = :daily
        end

        config
      end

      # Parse a file watch trigger description
      def self.parse_file_watch(description)
        desc = description.to_s

        path = nil
        pattern = "*"

        # Extract path
        if desc =~ /(?:in|from)\s+([~\/][\w\/.-]+)/
          path = File.expand_path($1)
        elsif desc =~ /(downloads?|documents?|desktop)\s+(?:folder)?/i
          folder = $1.downcase
          folder = "Downloads" if folder.start_with?("download")
          folder = "Documents" if folder.start_with?("document")
          folder = "Desktop" if folder == "desktop"
          path = File.expand_path("~/#{folder}")
        end

        # Extract pattern
        if desc =~ /\*\.(\w+)/
          pattern = "*.#{$1}"
        elsif desc =~ /(pdf|csv|txt|xlsx?|doc|docx)\s+files?/i
          pattern = "*.#{$1.downcase}"
        end

        {
          type: :file_watch,
          path: path || File.expand_path("~/Downloads"),
          pattern: pattern,
          events: [:create, :modify]  # Watch for new and modified files
        }
      end

      # Parse an email trigger description
      def self.parse_email_trigger(description)
        desc = description.to_s

        from_pattern = nil
        subject_pattern = nil

        # Extract sender pattern
        if desc =~ /from\s+([^\s,]+@[^\s,]+)/i
          from_pattern = $1
        elsif desc =~ /from\s+([^\s,]+)/i
          from_pattern = $1
        end

        # Extract subject pattern
        if desc =~ /subject\s+(?:contains?\s+)?["']?([^"']+)["']?/i
          subject_pattern = $1.strip
        elsif desc =~ /about\s+["']?([^"']+)["']?/i
          subject_pattern = $1.strip
        end

        {
          type: :email_match,
          from_pattern: from_pattern,
          subject_pattern: subject_pattern
        }
      end

      # Check if a schedule trigger matches a given time
      def schedule_matches?(trigger_config, time = Time.now)
        config = symbolize_keys(trigger_config)
        return false unless config[:type] == :schedule || config["type"] == "schedule"

        frequency = (config[:frequency] || config["frequency"])&.to_sym
        hour = config[:hour] || config["hour"]
        minute = config[:minute] || config["minute"] || 0
        day_of_week = config[:day_of_week] || config["day_of_week"]
        day_of_month = config[:day_of_month] || config["day_of_month"]

        # Hour must match (within the same hour)
        return false if hour && time.hour != hour.to_i

        # Minute check - allow a 5-minute window
        if minute
          return false unless (time.min - minute.to_i).abs <= 5
        end

        case frequency
        when :daily
          true
        when :weekly
          return false unless day_of_week
          time.wday == day_of_week.to_i
        when :monthly
          return false unless day_of_month
          time.day == day_of_month.to_i
        else
          false
        end
      end

      # Check if a file matches a file watch trigger
      def file_matches?(trigger_config, file_path)
        config = symbolize_keys(trigger_config)
        watch_path = config[:path] || config["path"]
        pattern = config[:pattern] || config["pattern"] || "*"

        return false unless watch_path

        # Check if file is in the watched directory
        file_dir = File.dirname(file_path)
        watch_dir = File.expand_path(watch_path)
        return false unless file_dir == watch_dir

        # Check if file matches pattern
        File.fnmatch(pattern, File.basename(file_path), File::FNM_CASEFOLD)
      end

      # Check if an email matches an email trigger
      def email_matches?(trigger_config, email)
        config = symbolize_keys(trigger_config)
        from_pattern = config[:from_pattern] || config["from_pattern"]
        subject_pattern = config[:subject_pattern] || config["subject_pattern"]

        email_from = email[:from] || email["from"]
        email_subject = email[:subject] || email["subject"]

        # If from pattern specified, must match
        if from_pattern && !from_pattern.empty?
          return false unless email_from&.downcase&.include?(from_pattern.downcase)
        end

        # If subject pattern specified, must match
        if subject_pattern && !subject_pattern.empty?
          return false unless email_subject&.downcase&.include?(subject_pattern.downcase)
        end

        # At least one pattern must be specified
        return false if (from_pattern.nil? || from_pattern.empty?) &&
                        (subject_pattern.nil? || subject_pattern.empty?)

        true
      end

      # Get all workflows that are due to run based on schedule
      def get_due_workflows(time = Time.now)
        workflows = Storage.list_workflows
        due = []

        workflows.each do |wf|
          next unless wf[:enabled]
          next unless wf[:trigger_type] == "schedule"

          # Load full workflow to get trigger_config
          full_wf = Storage.load_workflow(wf[:id])
          next unless full_wf

          trigger_config = full_wf[:trigger_config]
          next unless trigger_config

          # Check if already run this period
          next if already_run_this_period?(wf[:id], trigger_config, time)

          if schedule_matches?(trigger_config, time)
            due << full_wf
          end
        end

        due
      end

      # Get workflows triggered by a file event
      def get_file_triggered_workflows(file_path)
        workflows = Storage.list_workflows
        triggered = []

        workflows.each do |wf|
          next unless wf[:enabled]
          next unless wf[:trigger_type] == "file_watch"

          full_wf = Storage.load_workflow(wf[:id])
          next unless full_wf

          trigger_config = full_wf[:trigger_config]
          next unless trigger_config

          if file_matches?(trigger_config, file_path)
            triggered << full_wf
          end
        end

        triggered
      end

      # Get workflows triggered by an email
      def get_email_triggered_workflows(email)
        workflows = Storage.list_workflows
        triggered = []

        workflows.each do |wf|
          next unless wf[:enabled]
          next unless wf[:trigger_type] == "email_match"

          full_wf = Storage.load_workflow(wf[:id])
          next unless full_wf

          trigger_config = full_wf[:trigger_config]
          next unless trigger_config

          if email_matches?(trigger_config, email)
            triggered << full_wf
          end
        end

        triggered
      end

      # Record a trigger execution
      def record_trigger(workflow_id, trigger_type, trigger_data = {})
        sql = <<~SQL
          INSERT INTO trigger_history (workflow_id, trigger_type, trigger_data, triggered_at)
          VALUES (#{workflow_id.to_i}, '#{esc(trigger_type.to_s)}', '#{esc(trigger_data.to_json)}', datetime('now'));
        SQL
        Ruboto.run_sql(sql)
      end

      # Get trigger history for a workflow
      def get_trigger_history(workflow_id, limit = 10)
        sql = <<~SQL
          SELECT id, trigger_type, trigger_data, triggered_at
          FROM trigger_history
          WHERE workflow_id = #{workflow_id.to_i}
          ORDER BY triggered_at DESC
          LIMIT #{limit.to_i};
        SQL
        result = Ruboto.run_sql(sql).strip
        return [] if result.empty?

        result.split("\n").map do |row|
          cols = row.split("|")
          {
            id: cols[0].to_i,
            trigger_type: cols[1],
            trigger_data: JSON.parse(cols[2] || "{}"),
            triggered_at: cols[3]
          }
        end
      rescue JSON::ParserError
        []
      end

      private

      def already_run_this_period?(workflow_id, trigger_config, time)
        config = symbolize_keys(trigger_config)
        frequency = (config[:frequency] || config["frequency"])&.to_sym

        # Check last trigger time
        history = get_trigger_history(workflow_id, 1)
        return false if history.empty?

        last_trigger = Time.parse(history.first[:triggered_at]) rescue nil
        return false unless last_trigger

        case frequency
        when :daily
          last_trigger.to_date == time.to_date
        when :weekly
          # Same week check
          last_trigger.strftime("%Y-%W") == time.strftime("%Y-%W")
        when :monthly
          last_trigger.strftime("%Y-%m") == time.strftime("%Y-%m")
        else
          false
        end
      end

      def symbolize_keys(hash)
        return {} unless hash.is_a?(Hash)
        hash.transform_keys { |k| k.to_sym rescue k }
      end

      def esc(str)
        str.to_s.gsub("'", "''")
      end
    end
  end
end
