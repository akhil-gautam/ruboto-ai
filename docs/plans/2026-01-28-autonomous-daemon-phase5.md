# Phase 5: Autonomous Background Daemon Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a background daemon that continuously monitors email, extracts actionable intents via LLM, and autonomously executes actions (like flight check-in) after a 5-minute notification countdown.

**Architecture:** A single Ruby daemon process (`lib/ruboto/daemon.rb`) managed by launchd polls Mail.app every 5 minutes, classifies new emails via LLM, queues actions in SQLite, sends macOS notifications with a countdown, and executes mature actions through the existing tool pipeline. A new `run_headless` method provides the agentic loop without calling `exit()`.

**Tech Stack:** Ruby (daemon + intent extraction + action execution), SQLite (action queue + dedup), launchd (KeepAlive daemon), JXA (Mail.app polling), macOS notifications (countdown alerts)

---

### Task 1: Database Schema for Daemon Tables

Add `action_queue` and `watched_items` tables to the existing `ensure_db_exists` method.

**Files:**
- Modify: `lib/ruboto.rb` (lines 860-912, inside `ensure_db_exists`)

**Step 1: Add daemon tables to schema**

In `lib/ruboto.rb`, find the `ensure_db_exists` method. The SQL schema string ends before `run_sql(schema)` at line 914. Add two new CREATE TABLE statements inside the existing heredoc, right before the closing `SQL` delimiter (line 912):

```ruby
        CREATE TABLE IF NOT EXISTS action_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          intent TEXT NOT NULL,
          description TEXT,
          source_email_id TEXT,
          extracted_data TEXT,
          action_plan TEXT,
          status TEXT DEFAULT 'pending',
          confidence REAL,
          not_before TEXT,
          result TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          executed_at TEXT
        );

        CREATE TABLE IF NOT EXISTS watched_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source TEXT NOT NULL,
          source_id TEXT NOT NULL,
          seen_at TEXT DEFAULT (datetime('now')),
          UNIQUE(source, source_id)
        );
```

Insert these two CREATE TABLE blocks after the `patterns` table and before the `SQL` heredoc delimiter.

**Step 2: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax OK`

**Step 3: Verify tables are created**

Run: `ruby -e 'require_relative "lib/ruboto"; Ruboto.send(:ensure_db_exists); puts Ruboto.send(:run_sql, ".tables")'`
Expected: Output includes `action_queue` and `watched_items` alongside existing tables.

**Step 4: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add action_queue and watched_items tables for daemon"
```

---

### Task 2: run_headless Method

Extract the agentic loop from `run_quick` into a reusable `run_headless` that returns a result hash instead of calling `exit()`. Then refactor `run_quick` to use it.

**Files:**
- Modify: `lib/ruboto.rb` (lines 1513-1628, `run_quick` method area)

**Step 1: Add `run_headless` method**

Add this method after `run_tasks_cli` (after line 1644), before the closing `end end`:

```ruby
    def run_headless(request, model: nil, context: nil)
      ensure_db_exists
      model ||= MODELS.first[:id]
      session_id = Time.now.strftime("%Y%m%d_%H%M%S")

      profile_data = get_profile
      workflow_data = get_workflows
      recent = recent_tasks(5)

      memory_summary = ""
      memory_summary += "USER PROFILE:\n#{profile_data}\n\n" unless profile_data.empty?
      memory_summary += "KNOWN WORKFLOWS:\n#{workflow_data}\n\n" unless workflow_data.empty?
      memory_summary += "RECENT TASKS:\n#{recent}\n\n" unless recent.empty?

      context_line = context ? "\nCONTEXT: User is currently in #{context.sub('app:', '')}\n" : ""

      system_prompt = <<~PROMPT
        You are a fast, autonomous assistant with coding AND system automation powers. Working directory: #{Dir.pwd}
        #{context_line}
        #{memory_summary.empty? ? "" : "MEMORY (what you know about this user):\n#{memory_summary}"}

        TOOL HIERARCHY - Use highest-level tool that fits:

        1. META-TOOLS (prefer these):
           - macos_auto: Control macOS apps (calendar, reminders, mail, notes, clipboard, notifications)
           - browser: Interact with Safari (open URLs, read pages, fill forms, click, run JS)
           - explore: Answer "where is X?" / "how does Y work?" questions
           - patch: Multi-line edits using unified diff format
           - verify: Check if command succeeds (use after code changes)
           - memory: Read/write persistent user memory (profile, workflows, task history)
           - plan: Break complex requests into step-by-step plans using available tools

        2. PRIMITIVES (when meta-tools don't fit):
           - read/write/edit: Single, targeted file operations
           - grep/glob/find: When you know exactly what to search for
           - tree: See directory structure
           - bash: Run shell commands (only real commands, not prose)

        AUTONOMY RULES:
        - ACT FIRST. Just do it.
        - After ANY code change → immediately use verify to check it works
        - Keep using tools until you have a complete answer

        ACTION RULES:
        - Use macos_auto for macOS apps. Use browser for Safari.
        - Chain actions naturally.

        CRITICAL - BASH TOOL RULES:
        - ONLY use bash for executable commands
        - NEVER put prose or markdown in bash

        Be concise. Act, don't narrate. Output plain text only — no markdown formatting.
      PROMPT

      messages = [
        { role: "system", content: system_prompt },
        { role: "user", content: request }
      ]

      interaction_tools = []
      task_success = true
      final_text = nil

      loop do
        response = call_api(messages, model)

        if response["error"]
          return { success: false, text: "API Error: #{response.dig("error", "message")}", tools_used: interaction_tools }
        end

        choice = response.dig("choices", 0)
        unless choice
          return { success: false, text: "No response from model", tools_used: interaction_tools }
        end

        message = choice["message"]
        text_content = message["content"]
        tool_calls = message["tool_calls"] || []

        messages << message

        final_text = text_content if text_content && !text_content.empty?

        break if tool_calls.empty?

        tool_calls.each do |tc|
          tool_name = tc.dig("function", "name")
          tool_args = JSON.parse(tc.dig("function", "arguments") || "{}")
          call_id = tc["id"]

          interaction_tools << tool_name
          result = run_tool(tool_name, tool_args)

          messages << {
            role: "tool",
            tool_call_id: call_id,
            content: result
          }
        end
      end

      unless interaction_tools.empty?
        save_task(request, (final_text || "")[0, 200], interaction_tools.uniq.join(", "), task_success, session_id)
      end

      { success: task_success, text: final_text, tools_used: interaction_tools }
    rescue => e
      { success: false, text: "Error: #{e.message}", tools_used: [] }
    end
```

**Step 2: Refactor `run_quick` to use `run_headless`**

Replace the entire `run_quick` method (lines 1513-1628) with:

```ruby
    def run_quick(request, context: nil)
      result = run_headless(request, context: context)
      puts result[:text] if result[:text]
      exit(result[:success] ? 0 : 1)
    end
```

**Step 3: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax OK`

**Step 4: Verify --quick still works**

Run: `ruby bin/ruboto-ai --help`
Expected: Prints usage text (confirms no crash on require).

**Step 5: Commit**

```bash
git add lib/ruboto.rb
git commit -m "refactor: extract run_headless from run_quick for daemon reuse"
```

---

### Task 3: Intent Extractor Module

Create the LLM-based email classification module that takes raw email data and returns structured intents.

**Files:**
- Create: `lib/ruboto/intelligence/intent_extractor.rb`

**Step 1: Create the intent extractor**

```ruby
# frozen_string_literal: true

module Ruboto
  module Intelligence
    module IntentExtractor
      CLASSIFICATION_PROMPT = <<~PROMPT
        You are an email classifier. For each email, determine if it's actionable.
        Return ONLY valid JSON, no other text.

        Supported intents:
        - flight_checkin: airline confirmation emails with flight details
        - hotel_booking: hotel reservation confirmations
        - package_tracking: shipping/delivery notifications with tracking info
        - bill_due: invoices, bills, payment reminders
        - meeting_prep: meeting invitations or agendas needing preparation
        - none: not actionable

        For each actionable email, extract relevant structured data.

        Return format:
        {
          "items": [
            {
              "email_id": "the message id",
              "intent": "one of the intents above",
              "confidence": 0.0 to 1.0,
              "data": { ... extracted fields relevant to the intent ... },
              "action": "human-readable description of what to do",
              "urgency": "immediate|today|upcoming|none"
            }
          ]
        }

        For flight_checkin, extract: airline, confirmation_number, flight_number, date, checkin_url
        For hotel_booking, extract: hotel_name, checkin_date, checkout_date, confirmation_number
        For package_tracking, extract: carrier, tracking_number, tracking_url, delivery_date
        For bill_due, extract: vendor, amount, due_date
        For meeting_prep, extract: title, time, attendees, agenda
      PROMPT

      CONFIDENCE_THRESHOLD = 0.8
      MAX_BATCH_SIZE = 10

      def extract_intents(emails)
        return [] if emails.empty?

        batches = emails.each_slice(MAX_BATCH_SIZE).to_a
        all_intents = []

        batches.each do |batch|
          email_text = batch.map.with_index do |email, i|
            "--- Email #{i + 1} (id: #{email[:id]}) ---\nFrom: #{email[:from]}\nSubject: #{email[:subject]}\nDate: #{email[:date]}\n\n#{email[:body][0, 2000]}"
          end.join("\n\n")

          messages = [
            { role: "system", content: CLASSIFICATION_PROMPT },
            { role: "user", content: "Classify these emails:\n\n#{email_text}" }
          ]

          # Use cheapest model for classification
          model = classification_model
          response = call_api(messages, model)

          parsed = parse_classification_response(response)
          all_intents.concat(parsed) if parsed
        end

        all_intents.select { |item| item["intent"] != "none" && item["confidence"].to_f >= CONFIDENCE_THRESHOLD }
      rescue => e
        daemon_log("intent_extraction_error", { error: e.message })
        []
      end

      private

      def classification_model
        # Prefer cheapest model: look for free/cheap options in MODELS
        cheap = MODELS.find { |m| m[:id].include?("flash") || m[:id].include?("deepseek") }
        (cheap || MODELS.first)[:id]
      end

      def parse_classification_response(response)
        return nil if response["error"]

        content = response.dig("choices", 0, "message", "content")
        return nil unless content

        # Extract JSON from response (may be wrapped in markdown code blocks)
        json_str = content.match(/\{[\s\S]*\}/)&.to_s
        return nil unless json_str

        parsed = JSON.parse(json_str)
        parsed["items"]
      rescue JSON::ParserError
        nil
      end
    end
  end
end
```

**Step 2: Verify syntax**

Run: `ruby -c lib/ruboto/intelligence/intent_extractor.rb`
Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add lib/ruboto/intelligence/intent_extractor.rb
git commit -m "feat: add intent extractor for LLM-based email classification"
```

---

### Task 4: Action Executor Module

Create the module that manages the action queue: queueing, notifying, executing, and cancelling actions.

**Files:**
- Create: `lib/ruboto/intelligence/action_executor.rb`

**Step 1: Create the action executor**

```ruby
# frozen_string_literal: true

module Ruboto
  module Intelligence
    module ActionExecutor
      COUNTDOWN_SECONDS = 300 # 5 minutes

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
            "message" => "Auto-acting in 5 minutes. Run: ruboto-ai --cancel-action #{action_id} to cancel."
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

        prompt = "#{action[:action_plan]}\n\nExtracted data: #{action[:extracted_data]}"
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
          intent = cols[1]
          desc = cols[2]
          status = cols[3]
          conf = cols[4]
          not_before = cols[5]
          status_indicator = case status
                             when "pending" then "[PENDING]"
                             when "notified" then "[NOTIFIED until #{not_before}]"
                             when "executing" then "[RUNNING]"
                             end
          puts "  ##{id} #{status_indicator} #{desc} (#{intent}, #{(conf.to_f * 100).round}%)"
        end
      end

      private

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
```

**Step 2: Verify syntax**

Run: `ruby -c lib/ruboto/intelligence/action_executor.rb`
Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add lib/ruboto/intelligence/action_executor.rb
git commit -m "feat: add action executor with queue, notify, execute, cancel"
```

---

### Task 5: Daemon Main Loop

Create the daemon module with the main poll loop, email polling via JXA, structured logging, and graceful shutdown.

**Files:**
- Create: `lib/ruboto/daemon.rb`

**Step 1: Create the daemon**

```ruby
# frozen_string_literal: true

require_relative "../ruboto"

module Ruboto
  module Daemon
    POLL_INTERVAL = 300 # 5 minutes
    DAEMON_LOG = File.join(RUBOTO_DIR, "daemon.log")
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
      # Read recent emails via JXA
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
        next if now.min > 35 # Only trigger in the first 35 minutes of the hour

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
```

**Step 2: Verify syntax**

Run: `ruby -c lib/ruboto/daemon.rb`
Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add lib/ruboto/daemon.rb
git commit -m "feat: add daemon main loop with mail polling and briefing schedule"
```

---

### Task 6: Wire Daemon Into Ruboto Core

Add requires, includes, and the `daemon_log` helper to `lib/ruboto.rb`.

**Files:**
- Modify: `lib/ruboto.rb` (lines 1-19 for requires, lines 75-85 for includes)

**Step 1: Add requires**

After line 19 (`require_relative "ruboto/scheduler"`), add:

```ruby
require_relative "ruboto/intelligence/intent_extractor"
require_relative "ruboto/intelligence/action_executor"
```

**Step 2: Add includes**

Inside the `class << self` block, after the existing `include Scheduler` line, add:

```ruby
      include Intelligence::IntentExtractor
      include Intelligence::ActionExecutor
      include Daemon
```

Note: The `Daemon` module is required via `lib/ruboto/daemon.rb` which itself does `require_relative "../ruboto"`. To avoid circular requires, add `require_relative "ruboto/daemon"` only in `lib/ruboto/cli.rb` instead. So do NOT add a require for daemon.rb in ruboto.rb. Instead, edit `lib/ruboto/cli.rb` to require it.

Actually, simpler approach: Since `daemon.rb` does `require_relative "../ruboto"`, and `ruboto.rb` needs the Daemon module included, we need to handle this. The cleanest way:

- Remove `require_relative "../ruboto"` from `lib/ruboto/daemon.rb` (it's just a module definition)
- Add `require_relative "ruboto/daemon"` in `lib/ruboto.rb` after the scheduler require

**Step 2a: Update `lib/ruboto/daemon.rb`**

Remove the `require_relative "../ruboto"` line (line 3). The file should start with:

```ruby
# frozen_string_literal: true

module Ruboto
  module Daemon
```

**Step 2b: Add requires in `lib/ruboto.rb`**

After line 19 (`require_relative "ruboto/scheduler"`), add:

```ruby
require_relative "ruboto/intelligence/intent_extractor"
require_relative "ruboto/intelligence/action_executor"
require_relative "ruboto/daemon"
```

**Step 2c: Add includes in `lib/ruboto.rb`**

Inside the `class << self` block, after `include Scheduler`, add:

```ruby
      include Intelligence::IntentExtractor
      include Intelligence::ActionExecutor
      include Daemon
```

**Step 2d: Add `daemon_log` helper**

The `daemon_log` method is defined in the Daemon module, but IntentExtractor and ActionExecutor also call it. Since all modules are mixed into the same `class << self`, the method is available to all. No extra wiring needed.

**Step 3: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax OK`

**Step 4: Commit**

```bash
git add lib/ruboto.rb lib/ruboto/daemon.rb
git commit -m "feat: wire daemon, intent extractor, and action executor into core"
```

---

### Task 7: CLI and Scheduler Integration

Add new CLI flags (`--daemon`, `--install-daemon`, `--uninstall-daemon`, `--cancel-action`, `--queue`) and daemon launchd plist management.

**Files:**
- Modify: `lib/ruboto/cli.rb` (lines 7-55)
- Modify: `lib/ruboto/scheduler.rb` (add daemon plist methods)

**Step 1: Update CLI USAGE and dispatch**

Replace the entire content of `lib/ruboto/cli.rb` with:

```ruby
# frozen_string_literal: true

require_relative "../ruboto"

module Ruboto
  module CLI
    USAGE = <<~TEXT
      Usage: ruboto-ai [options]

        (no args)                  Interactive REPL (default)
        --quick "request"          Single-shot: one request, print result, exit
        --context "app:Name"       App context for quick mode (optional)
        --briefing morning|evening|auto  Run scheduled briefing
        --tasks [N]                Print recent N tasks (default 10), exit
        --install-schedule         Install launchd plist for scheduled briefings
        --uninstall-schedule       Remove launchd plist
        --daemon                   Start background daemon (foreground, for launchd)
        --install-daemon           Install launchd plist for background daemon
        --uninstall-daemon         Remove daemon plist
        --queue                    Show pending action queue
        --cancel-action ID         Cancel a pending/notified action
        --help                     Show this help
    TEXT

    def self.run(argv)
      return Ruboto.run if argv.empty?

      case argv.first
      when "--help"
        puts USAGE
      when "--quick"
        request = argv[1]
        unless request && !request.start_with?("--")
          $stderr.puts "Error: --quick requires a request string"
          exit 1
        end
        context = nil
        if (ci = argv.index("--context"))
          context = argv[ci + 1]
        end
        Ruboto.run_quick(request, context: context)
      when "--briefing"
        mode = argv[1] || "auto"
        unless %w[morning evening auto].include?(mode)
          $stderr.puts "Error: --briefing accepts morning, evening, or auto"
          exit 1
        end
        Ruboto.run_briefing(mode)
      when "--tasks"
        limit = (argv[1] || "10").to_i
        Ruboto.run_tasks_cli(limit)
      when "--install-schedule"
        Ruboto.install_schedule
      when "--uninstall-schedule"
        Ruboto.uninstall_schedule
      when "--daemon"
        Ruboto.run_daemon
      when "--install-daemon"
        Ruboto.install_daemon
      when "--uninstall-daemon"
        Ruboto.uninstall_daemon
      when "--queue"
        Ruboto.ensure_db_exists
        Ruboto.show_action_queue
      when "--cancel-action"
        action_id = argv[1]
        unless action_id && action_id.match?(/\A\d+\z/)
          $stderr.puts "Error: --cancel-action requires a numeric action ID"
          exit 1
        end
        Ruboto.ensure_db_exists
        Ruboto.cancel_action(action_id.to_i)
      else
        $stderr.puts "Unknown option: #{argv.first}"
        $stderr.puts USAGE
        exit 1
      end
    end
  end
end
```

**Step 2: Add daemon plist methods to scheduler**

Add to `lib/ruboto/scheduler.rb`, after the `uninstall_schedule` method (before the closing `end end`):

```ruby
    DAEMON_PLIST_LABEL = "com.ruboto.daemon"
    DAEMON_PLIST_PATH = File.join(PLIST_DIR, "#{DAEMON_PLIST_LABEL}.plist")

    def install_daemon
      bin_path = File.expand_path("../../bin/ruboto-ai", __dir__)
      ruby_path = RbConfig.ruby

      plist_content = <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>#{DAEMON_PLIST_LABEL}</string>
            <key>ProgramArguments</key>
            <array>
                <string>#{ruby_path}</string>
                <string>#{bin_path}</string>
                <string>--daemon</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>StandardOutPath</key>
            <string>#{RUBOTO_DIR}/daemon.stdout.log</string>
            <key>StandardErrorPath</key>
            <string>#{RUBOTO_DIR}/daemon.stderr.log</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>OPENROUTER_API_KEY</key>
                <string>#{ENV["OPENROUTER_API_KEY"]}</string>
            </dict>
        </dict>
        </plist>
      PLIST

      Dir.mkdir(PLIST_DIR) unless Dir.exist?(PLIST_DIR)
      Dir.mkdir(RUBOTO_DIR) unless Dir.exist?(RUBOTO_DIR)

      File.write(DAEMON_PLIST_PATH, plist_content)

      system("launchctl", "unload", DAEMON_PLIST_PATH, err: File::NULL, out: File::NULL)
      success = system("launchctl", "load", DAEMON_PLIST_PATH)

      if success
        puts "Ruboto daemon installed."
        puts "  Polls email every 5 minutes"
        puts "  Auto-acts on actionable emails after 5-min notification"
        puts "  Handles morning/evening briefings"
        puts "  Plist: #{DAEMON_PLIST_PATH}"
        puts "  Log: #{RUBOTO_DIR}/daemon.log"
      else
        $stderr.puts "Error: launchctl load failed. Check plist at #{DAEMON_PLIST_PATH}"
        exit 1
      end
    end

    def uninstall_daemon
      unless File.exist?(DAEMON_PLIST_PATH)
        puts "No daemon installed (#{DAEMON_PLIST_PATH} not found)."
        return
      end

      system("launchctl", "unload", DAEMON_PLIST_PATH, err: File::NULL, out: File::NULL)
      File.delete(DAEMON_PLIST_PATH)
      puts "Ruboto daemon removed."
    end
```

**Step 3: Verify syntax**

Run: `ruby -c lib/ruboto/cli.rb && ruby -c lib/ruboto/scheduler.rb`
Expected: Both `Syntax OK`

**Step 4: Verify --help shows new flags**

Run: `ruby bin/ruboto-ai --help`
Expected: Shows `--daemon`, `--install-daemon`, `--uninstall-daemon`, `--queue`, `--cancel-action`.

**Step 5: Commit**

```bash
git add lib/ruboto/cli.rb lib/ruboto/scheduler.rb
git commit -m "feat: add daemon CLI flags and launchd plist management"
```

---

### Task 8: REPL Commands (/queue, /cancel)

Add `/queue` and `/cancel` slash commands to the interactive REPL, and update help text.

**Files:**
- Modify: `lib/ruboto.rb` — REPL command handlers and help text

**Step 1: Add /queue and /cancel commands**

In `lib/ruboto.rb`, find the `/briefing` handler (around line 1393-1398). Add after it, before the `/history` handler:

```ruby
          if user_input == "/queue"
            show_action_queue
            next
          end

          if user_input.start_with?("/cancel")
            action_id = user_input.split(" ")[1]
            if action_id && action_id.match?(/\A\d+\z/)
              cancel_action(action_id.to_i)
            else
              puts "#{RED}Usage: /cancel <action_id>#{RESET}"
            end
            next
          end
```

**Step 2: Update help text**

In the `print_help` method, add after the `/briefing` line:

```ruby
          #{BOLD}/queue#{RESET}    #{DIM}show pending daemon actions#{RESET}
          #{BOLD}/cancel#{RESET}   #{DIM}cancel a daemon action (/cancel <id>)#{RESET}
```

**Step 3: Update capabilities in help**

Find the "Scheduled" capabilities line and update it to:

```ruby
          #{DIM}•#{RESET} Autonomous: background daemon, email monitoring, auto-actions
```

**Step 4: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax OK`

**Step 5: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add /queue and /cancel REPL commands for daemon actions"
```

---

### Task 9: Integration Testing and Version Bump

Verify all Phase 5 components work together.

**Step 1: Syntax check all files**

```bash
ruby -c lib/ruboto.rb
ruby -c lib/ruboto/cli.rb
ruby -c lib/ruboto/daemon.rb
ruby -c lib/ruboto/scheduler.rb
ruby -c lib/ruboto/intelligence/intent_extractor.rb
ruby -c lib/ruboto/intelligence/action_executor.rb
```

**Step 2: Verify --help**

Run: `ruby bin/ruboto-ai --help`
Expected: Shows all flags including new daemon flags.

**Step 3: Verify --queue**

Run: `ruby bin/ruboto-ai --queue`
Expected: "No pending actions." (clean queue).

**Step 4: Verify --cancel-action error handling**

Run: `ruby bin/ruboto-ai --cancel-action abc 2>&1; echo "EXIT: $?"`
Expected: Error message, exit code 1.

**Step 5: Verify --install-daemon and --uninstall-daemon**

```bash
ruby bin/ruboto-ai --install-daemon
ls ~/Library/LaunchAgents/com.ruboto.daemon.plist && echo "DAEMON PLIST EXISTS"
ruby bin/ruboto-ai --uninstall-daemon
```
Expected: Plist created, then removed.

**Step 6: Verify daemon starts and stops**

Run in background for 10 seconds:
```bash
timeout 10 ruby bin/ruboto-ai --daemon || true
cat ~/.ruboto/daemon.log | tail -5
```
Expected: daemon.log shows `daemon_started` and `poll_complete` events (poll may show errors if Mail.app isn't running — that's fine, it shouldn't crash).

**Step 7: Verify DB tables exist**

```bash
ruby -e 'require_relative "lib/ruboto"; Ruboto.send(:ensure_db_exists); puts Ruboto.send(:run_sql, ".tables")'
```
Expected: Includes `action_queue` and `watched_items`.

**Step 8: Verify existing features still work**

```bash
ruby bin/ruboto-ai --tasks 3
ruby bin/ruboto-ai --briefing morning
```
Expected: Both work as before.

**Step 9: Version bump**

Update `lib/ruboto/version.rb` to `0.4.0`.

```bash
git add lib/ruboto/version.rb
git commit -m "chore: bump version to 0.4.0 for Phase 5 (Autonomous Daemon)"
```
