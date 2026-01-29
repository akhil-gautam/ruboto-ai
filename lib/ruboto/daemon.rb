# frozen_string_literal: true

require "time"
require "digest"

module Ruboto
  module Daemon
    POLL_INTERVAL = 60 # 1 minute (increase to 300 for production)
    DAEMON_LOG = File.join(File.expand_path("~/.ruboto"), "daemon.log")
    BRIEFING_HOURS = { morning: 8, evening: 17 }.freeze

    def run_daemon
      ensure_db_exists
      @daemon_running = true
      @last_briefing_check = nil

      Signal.trap("TERM") { @daemon_running = false }
      Signal.trap("INT") { @daemon_running = false }

      daemon_log("daemon_started", { poll_interval: POLL_INTERVAL })

      while @daemon_running
        cycle_start = Time.now

        begin
          # 1. Poll for new emails
          new_emails = poll_mail
          daemon_log("poll_complete", { new_emails: new_emails.length })

          # 2. Extract intents from unseen emails
          if new_emails.any?
            intents = extract_intents(new_emails)
            intents.each { |item| queue_action(item) }
          end

          # 3. Send notifications for pending actions
          notify_pending_actions

          # 4. Execute mature actions (past countdown)
          execute_ready_actions

          # 5. Run scheduled briefings if due
          check_briefing_schedule

          # 6. Check and run scheduled workflows
          check_scheduled_workflows

          # 7. Check email-triggered workflows
          if new_emails.any?
            check_email_triggered_workflows(new_emails)
          end

          # 8. Check file-triggered workflows
          check_file_triggered_workflows

        rescue => e
          daemon_log("cycle_error", { error: e.message, backtrace: e.backtrace.first(3) })
        end

        elapsed = Time.now - cycle_start
        sleep_time = [POLL_INTERVAL - elapsed, 10].max
        sleep(sleep_time) if @daemon_running
      end

      daemon_log("daemon_stopped", {})
    end

    private

    def poll_mail
      # Simple approach: get last 50 messages metadata, filter unread in Ruby
      script = <<~'APPLESCRIPT'
        tell application "Mail"
          set msgList to messages 1 thru 10 of inbox
          set output to ""
          repeat with m in msgList
            try
              set msgId to message id of m
              set msgFrom to sender of m
              set msgSubj to subject of m
              set msgDate to date received of m as string
              set isRead to read status of m
              if isRead then
                set readFlag to "1"
              else
                set readFlag to "0"
              end if
              set output to output & msgId & "	" & msgFrom & "	" & msgSubj & "	" & msgDate & "	" & readFlag & linefeed
            end try
          end repeat
          return output
        end tell
      APPLESCRIPT

      result = run_applescript(script)
      unless result[:success]
        daemon_log("poll_mail_applescript_error", { error: result[:error] })
        return []
      end

      # Parse tab-separated output and filter for unread emails from last 24h
      cutoff = Time.now - (24 * 60 * 60)
      all_emails = result[:output].strip.split("\n").map do |line|
        parts = line.split("\t")
        next nil if parts.length < 5
        is_read = parts[4] == "1"
        next nil if is_read  # Skip read emails
        { id: parts[0], from: parts[1], subject: parts[2], date: parts[3] }
      end.compact

      daemon_log("poll_mail_found", { total: all_emails.length })

      # Filter out already-seen emails and fetch body for new ones
      new_emails = all_emails.reject do |email|
        msg_id = email[:id].to_s.gsub("'", "''")
        existing = run_sql("SELECT id FROM watched_items WHERE source='mail' AND source_id='#{msg_id}' LIMIT 1;")
        if existing.strip.empty?
          run_sql("INSERT OR IGNORE INTO watched_items (source, source_id) VALUES ('mail', '#{msg_id}');")
          false # new email, keep it
        else
          true # already seen, skip
        end
      end

      # Fetch body for new emails
      new_emails.map do |email|
        email[:body] = fetch_email_body(email[:id])
        email
      end
    rescue => e
      daemon_log("poll_mail_error", { error: e.message })
      []
    end

    def fetch_email_body(message_id)
      escaped_id = message_id.gsub('"', '\\"')
      script = <<~APPLESCRIPT
        tell application "Mail"
          set targetMsg to first message of inbox whose message id is "#{escaped_id}"
          return content of targetMsg
        end tell
      APPLESCRIPT
      result = run_applescript(script)
      body = result[:success] ? result[:output] : ""
      body.length > 3000 ? body[0, 3000] : body
    rescue
      ""
    end

    def check_briefing_schedule
      now = Time.now
      today = now.strftime("%Y-%m-%d")

      BRIEFING_HOURS.each do |mode, hour|
        next if now.hour != hour
        next if now.min > 35

        key = "#{today}-#{mode}"
        next if @last_briefing_check == key

        @last_briefing_check = key
        daemon_log("briefing_triggered", { mode: mode.to_s })

        begin
          run_briefing(mode.to_s)
        rescue => e
          daemon_log("briefing_error", { mode: mode.to_s, error: e.message })
        end
      end
    end

    def check_scheduled_workflows
      require_relative "workflow"

      manager = Workflow::TriggerManager.new
      now = Time.now

      due_workflows = manager.get_due_workflows(now)
      return if due_workflows.empty?

      daemon_log("scheduled_workflows_due", { count: due_workflows.length })

      due_workflows.each do |wf|
        begin
          daemon_log("workflow_trigger", { workflow: wf[:name], trigger: "schedule" })

          # Record the trigger
          manager.record_trigger(wf[:id], :schedule, { triggered_at: now.to_s })

          # Run the workflow in headless mode
          run_scheduled_workflow(wf)

          daemon_log("workflow_completed", { workflow: wf[:name] })
        rescue => e
          daemon_log("workflow_error", { workflow: wf[:name], error: e.message })
        end
      end
    end

    def check_email_triggered_workflows(emails)
      require_relative "workflow"

      manager = Workflow::TriggerManager.new

      emails.each do |email|
        triggered = manager.get_email_triggered_workflows(email)
        next if triggered.empty?

        daemon_log("email_triggered_workflows", { email_from: email[:from], count: triggered.length })

        triggered.each do |wf|
          begin
            daemon_log("workflow_trigger", { workflow: wf[:name], trigger: "email", from: email[:from] })

            # Record the trigger with email context
            manager.record_trigger(wf[:id], :email_match, {
              triggered_at: Time.now.to_s,
              email_from: email[:from],
              email_subject: email[:subject]
            })

            # Store email data in workflow context for step execution
            run_scheduled_workflow(wf, email_context: email)

            daemon_log("workflow_completed", { workflow: wf[:name] })
          rescue => e
            daemon_log("workflow_error", { workflow: wf[:name], error: e.message })
          end
        end
      end
    end

    def check_file_triggered_workflows
      require_relative "workflow"

      manager = Workflow::TriggerManager.new
      workflows = Workflow::Storage.list_workflows

      file_workflows = workflows.select { |wf| wf[:enabled] && wf[:trigger_type] == "file_watch" }
      return if file_workflows.empty?

      file_workflows.each do |wf|
        begin
          full_wf = Workflow::Storage.load_workflow(wf[:id])
          next unless full_wf

          trigger_config = full_wf[:trigger_config]
          next unless trigger_config

          config = trigger_config.transform_keys(&:to_sym) rescue trigger_config
          watch_path = config[:path] || config["path"]
          pattern = config[:pattern] || config["pattern"] || "*"

          next unless watch_path && Dir.exist?(watch_path)

          # Find new files since last check
          new_files = find_new_files(wf[:id], watch_path, pattern)

          next if new_files.empty?

          daemon_log("file_trigger_found", { workflow: wf[:name], files: new_files.length })

          new_files.each do |file_path|
            daemon_log("workflow_trigger", { workflow: wf[:name], trigger: "file_watch", file: file_path })

            # Record the trigger
            manager.record_trigger(wf[:id], :file_watch, {
              triggered_at: Time.now.to_s,
              file_path: file_path
            })

            # Mark file as seen
            mark_file_seen(wf[:id], file_path)

            # Run the workflow with file context
            run_scheduled_workflow(full_wf, file_context: file_path)

            daemon_log("workflow_completed", { workflow: wf[:name] })
          end
        rescue => e
          daemon_log("file_watch_error", { workflow: wf[:name], error: e.message })
        end
      end
    end

    def find_new_files(workflow_id, watch_path, pattern)
      full_pattern = File.join(File.expand_path(watch_path), pattern)
      files = Dir.glob(full_pattern).select { |f| File.file?(f) }

      # Filter to files modified in last poll interval + buffer
      cutoff = Time.now - (POLL_INTERVAL * 2)
      recent_files = files.select { |f| File.mtime(f) >= cutoff }

      # Filter out already-seen files
      recent_files.reject do |file_path|
        seen_key = "file_watch_#{workflow_id}_#{Digest::MD5.hexdigest(file_path)}"
        existing = run_sql("SELECT id FROM watched_items WHERE source='file_watch' AND source_id='#{seen_key}' LIMIT 1;")
        !existing.strip.empty?
      end
    end

    def mark_file_seen(workflow_id, file_path)
      seen_key = "file_watch_#{workflow_id}_#{Digest::MD5.hexdigest(file_path)}"
      run_sql("INSERT OR IGNORE INTO watched_items (source, source_id) VALUES ('file_watch', '#{seen_key}');")
    end

    def run_scheduled_workflow(workflow, email_context: nil, file_context: nil)
      require_relative "workflow"

      steps_data = Workflow::Storage.load_steps(workflow[:id])
      steps = steps_data.map do |s|
        Workflow::Step.new(
          id: s[:step_order],
          tool: s[:tool],
          params: s[:params],
          output_key: s[:output_key],
          description: s[:description]
        ).tap { |step| step.confidence = s[:confidence] }
      end

      runtime = Workflow::Runtime.new(steps, mode: :autonomous)
      run_id = Workflow::Storage.start_run(workflow[:id])

      # If triggered by email, store email data in runtime state
      if email_context
        runtime.store_result("trigger_email", email_context)
      end

      # If triggered by file, store file path in runtime state
      if file_context
        runtime.store_result("trigger_file", file_context)
        # Also populate collected_files for file_glob steps that might reference it
        runtime.store_result("collected_files", [file_context])
      end

      success = true
      while !runtime.complete?
        step = runtime.current_step
        resolved_params = runtime.resolve_params(step.params)

        # Execute step
        result = execute_workflow_step(step, resolved_params)

        if result[:success]
          runtime.store_result(step.output_key, result[:output])
          runtime.log_event(:completed, { output: result[:summary] })

          # Increase confidence on autonomous success
          tracker = Workflow::ConfidenceTracker.new(workflow_id: workflow[:id], step_order: step.id)
          new_confidence = tracker.on_approval(step.confidence)
          Workflow::Storage.update_step_confidence(workflow[:id], step.id, new_confidence)
        else
          runtime.log_event(:failed, { error: result[:error] })
          success = false
          # Don't break - try to continue if possible
          daemon_log("workflow_step_failed", {
            workflow: workflow[:name],
            step: step.id,
            error: result[:error]
          })
        end

        runtime.advance
      end

      # Complete the run
      status = success ? "completed" : "partial"
      Workflow::Storage.complete_run(run_id, status, runtime.state, runtime.run_log)
      Workflow::Storage.increment_run_count(workflow[:id], success)
      Workflow::Storage.update_overall_confidence(workflow[:id])

      # Send notification on completion
      send_workflow_notification(workflow[:name], success, runtime.run_log)
    end

    def send_workflow_notification(workflow_name, success, log)
      status = success ? "completed" : "had errors"
      title = "Workflow #{status}"
      message = "\"#{workflow_name}\" #{status}"

      # Use macOS notification
      script = <<~APPLESCRIPT
        display notification "#{message}" with title "#{title}"
      APPLESCRIPT
      run_applescript(script)
    rescue
      # Notifications are best-effort
    end

    def daemon_log(event, data = {})
      entry = { ts: Time.now.iso8601, event: event }.merge(data)
      File.open(DAEMON_LOG, "a") { |f| f.puts(entry.to_json) }
    rescue => e
      # Logging should never crash the daemon
    end
  end
end
