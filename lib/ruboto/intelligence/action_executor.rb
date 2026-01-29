# frozen_string_literal: true

module Ruboto
  module Intelligence
    module ActionExecutor
      COUNTDOWN_SECONDS = 60 # 1 minute (increase to 300 for production)

      def queue_action(intent_item)
        email_id = intent_item["email_id"]
        intent = intent_item["intent"]
        confidence = intent_item["confidence"].to_f
        data = intent_item["data"].to_json
        action = intent_item["action"]
        description = build_description(intent, intent_item["data"])

        sql = <<~SQL
          INSERT INTO action_queue (intent, description, source_email_id, extracted_data, action_plan, status, confidence)
          VALUES ('#{esc(intent)}', '#{esc(description)}', '#{esc(email_id)}', '#{esc(data)}', '#{esc(action)}', 'pending', #{confidence});
        SQL
        run_sql(sql)

        daemon_log("action_queued", { intent: intent, description: description, confidence: confidence })
      end

      def notify_pending_actions
        sql = "SELECT id, intent, description, confidence FROM action_queue WHERE status='pending';"
        rows = run_sql(sql)
        return if rows.strip.empty?

        rows.split("\n").each do |row|
          cols = row.split("|")
          next if cols.length < 4
          action_id = cols[0].to_i
          description = cols[2]

          not_before = (Time.now + COUNTDOWN_SECONDS).strftime("%Y-%m-%d %H:%M:%S")
          run_sql("UPDATE action_queue SET status='notified', not_before='#{not_before}' WHERE id=#{action_id};")

          tool_macos_auto({
            "action" => "notify",
            "title" => "Ruboto: #{description}",
            "message" => "Auto-acting in #{COUNTDOWN_SECONDS / 60} minute(s). Run: ruboto-ai --cancel-action #{action_id} to cancel."
          })

          daemon_log("action_notified", { action_id: action_id, not_before: not_before })
        end
      rescue => e
        daemon_log("notify_error", { error: e.message })
      end

      def execute_ready_actions
        now = Time.now.strftime("%Y-%m-%d %H:%M:%S")
        sql = "SELECT id, intent, description, extracted_data, action_plan FROM action_queue WHERE status='notified' AND not_before <= '#{now}';"
        rows = run_sql(sql)
        return if rows.strip.empty?

        rows.split("\n").each do |row|
          cols = row.split("|")
          next if cols.length < 5
          action = {
            id: cols[0].to_i,
            intent: cols[1],
            description: cols[2],
            extracted_data: cols[3],
            action_plan: cols[4]
          }
          execute_single_action(action)
        end
      rescue => e
        daemon_log("execute_error", { error: e.message })
      end

      def execute_single_action(action)
        run_sql("UPDATE action_queue SET status='executing' WHERE id=#{action[:id]};")
        daemon_log("action_executing", { action_id: action[:id], intent: action[:intent] })

        safety = safety_prompt_for_intent(action[:intent])
        prompt = "#{safety}\n\n#{action[:action_plan]}\n\nExtracted data: #{action[:extracted_data]}"
        result = run_headless(prompt)

        status = result[:success] ? "completed" : "failed"
        result_text = esc((result[:text] || "")[0, 500])
        executed_at = Time.now.strftime("%Y-%m-%d %H:%M:%S")

        run_sql("UPDATE action_queue SET status='#{status}', result='#{result_text}', executed_at='#{executed_at}' WHERE id=#{action[:id]};")

        label = status == "completed" ? "Done" : "Failed"
        tool_macos_auto({
          "action" => "notify",
          "title" => "#{label}: #{action[:description]}",
          "message" => (result[:text] || "No details")[0, 200]
        })

        daemon_log("action_#{status}", { action_id: action[:id], tools_used: result[:tools_used]&.join(", ") })
      rescue => e
        run_sql("UPDATE action_queue SET status='failed', result='#{esc(e.message)}' WHERE id=#{action[:id]};")
        daemon_log("action_error", { action_id: action[:id], error: e.message })
      end

      def cancel_action(action_id)
        result = run_sql("SELECT status FROM action_queue WHERE id=#{action_id.to_i};")
        if result.strip.empty?
          puts "Action ##{action_id} not found."
          return
        end
        status = result.strip
        if %w[pending notified].include?(status)
          run_sql("UPDATE action_queue SET status='cancelled' WHERE id=#{action_id.to_i};")
          puts "Action ##{action_id} cancelled."
        else
          puts "Action ##{action_id} is already #{status} — cannot cancel."
        end
      end

      def show_action_queue
        sql = "SELECT id, intent, description, status, confidence, not_before FROM action_queue WHERE status IN ('pending','notified','executing') ORDER BY id;"
        rows = run_sql(sql)
        if rows.strip.empty?
          puts "No pending actions."
          return
        end
        puts "Action Queue:"
        rows.split("\n").each do |row|
          cols = row.split("|")
          next if cols.length < 6
          id = cols[0]
          desc = cols[2]
          status = cols[3]
          conf = cols[4]
          not_before = cols[5]
          status_indicator = case status
                             when "pending" then "[PENDING]"
                             when "notified" then "[NOTIFIED until #{not_before}]"
                             when "executing" then "[RUNNING]"
                             end
          puts "  ##{id} #{status_indicator} #{desc} (#{cols[1]}, #{(conf.to_f * 100).round}%)"
        end
      end

      private

      def safety_prompt_for_intent(intent)
        case intent
        when "flight_checkin"
          # Flight check-in is time-sensitive and not destructive - allow full automation
          "AUTONOMOUS MODE: You are completing a flight web check-in automatically. " \
          "This is a time-sensitive action that benefits from early completion. " \
          "ALLOWED: Open the check-in URL, fill in passenger details (PNR, name, etc.), " \
          "select seats if prompted (prefer window or aisle), and SUBMIT the check-in form. " \
          "AFTER SUCCESS: Download or screenshot the boarding pass if possible. " \
          "NOT ALLOWED: Making purchases, paying for upgrades, changing flight details, or canceling bookings. " \
          "If the check-in requires payment or shows errors, STOP and report the issue."
        when "package_tracking"
          # Package tracking is read-only
          "AUTONOMOUS MODE: You are checking package tracking status. " \
          "ALLOWED: Open tracking URLs, read delivery status, extract estimated delivery dates. " \
          "NOT ALLOWED: Modifying delivery instructions, rescheduling, or any actions that change the delivery."
        else
          # Default conservative safety for other intents
          "SAFETY: You are running autonomously without a user present. " \
          "NEVER take destructive actions — do NOT delete anything, do NOT send emails, " \
          "do NOT submit payment forms, do NOT cancel or modify existing bookings. " \
          "Only perform safe, read-oriented or clearly constructive actions. " \
          "If the task requires a destructive or irreversible action, STOP and report what you would do instead."
        end
      end

      def build_description(intent, data)
        case intent
        when "flight_checkin"
          airline = data["airline"] || "flight"
          flight = data["flight_number"] || ""
          "Check in for #{airline} #{flight}".strip
        when "hotel_booking"
          hotel = data["hotel_name"] || "hotel"
          "Hotel booking at #{hotel}"
        when "package_tracking"
          carrier = data["carrier"] || "package"
          "Track #{carrier} delivery"
        when "bill_due"
          vendor = data["vendor"] || "bill"
          amount = data["amount"] || ""
          "Pay #{vendor} #{amount}".strip
        when "meeting_prep"
          title = data["title"] || "meeting"
          "Prepare for #{title}"
        else
          intent.tr("_", " ").capitalize
        end
      end

      def esc(str)
        str.to_s.gsub("'", "''")
      end
    end
  end
end
