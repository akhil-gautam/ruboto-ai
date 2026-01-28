# frozen_string_literal: true

module Ruboto
  module Daemon
    POLL_INTERVAL = 300 # 5 minutes
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
      jxa = <<~JS
        const mail = Application("Mail");
        const inbox = mail.inbox();
        const messages = inbox.messages.whose({dateReceived: {_greaterThan: new Date(Date.now() - 600000)}})();
        const results = [];
        const count = Math.min(messages.length, 20);
        for (let i = 0; i < count; i++) {
          const m = messages[i];
          try {
            results.push({
              id: m.messageId(),
              from: m.sender(),
              subject: m.subject(),
              date: m.dateReceived().toISOString(),
              body: m.content().substring(0, 3000)
            });
          } catch(e) {}
        }
        JSON.stringify(results);
      JS

      result = run_jxa(jxa)
      return [] unless result[:success]

      all_emails = JSON.parse(result[:output]) rescue []

      # Filter out already-seen emails
      all_emails.reject do |email|
        msg_id = email["id"].to_s.gsub("'", "''")
        existing = run_sql("SELECT id FROM watched_items WHERE source='mail' AND source_id='#{msg_id}' LIMIT 1;")
        if existing.strip.empty?
          run_sql("INSERT OR IGNORE INTO watched_items (source, source_id) VALUES ('mail', '#{msg_id}');")
          false # new email, keep it
        else
          true # already seen, skip
        end
      end.map do |email|
        { id: email["id"], from: email["from"], subject: email["subject"], date: email["date"], body: email["body"] }
      end
    rescue => e
      daemon_log("poll_mail_error", { error: e.message })
      []
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

    def daemon_log(event, data = {})
      entry = { ts: Time.now.iso8601, event: event }.merge(data)
      File.open(DAEMON_LOG, "a") { |f| f.puts(entry.to_json) }
    rescue => e
      # Logging should never crash the daemon
    end
  end
end
