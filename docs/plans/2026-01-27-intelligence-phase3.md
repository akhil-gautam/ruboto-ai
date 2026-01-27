# Phase 3: Intelligence Layer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add pattern detection, proactive suggestions, and task planning to Ruboto's Intelligence Layer.

**Architecture:** Three new modules under `lib/ruboto/intelligence/` mixed into the main Ruboto module. Pattern detector and proactive triggers run at session start. Task planner is an LLM tool. All use existing SQLite tables (patterns, tasks, workflows).

**Tech Stack:** Ruby, SQLite (existing DB), keyword matching, existing `run_sql` helper

---

### Task 1: Pattern Detector Module

**Files:**
- Create: `lib/ruboto/intelligence/pattern_detector.rb`

**Step 1: Create the pattern detector module**

Create `lib/ruboto/intelligence/pattern_detector.rb` with the full implementation:

```ruby
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

          # Check if similar pattern already exists
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

        # Group by tool + 2-hour window
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

        # Group tools by session
        sessions = Hash.new { |h, k| h[k] = [] }
        rows.split("\n").each do |row|
          cols = row.split("|")
          next if cols.length < 2
          session = cols[0]
          tools = cols[1].to_s.split(", ").map(&:strip)
          sessions[session].concat(tools)
        end

        # Find tool pairs that co-occur in 3+ sessions
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
```

**Step 2: Verify syntax**

Run: `ruby -c lib/ruboto/intelligence/pattern_detector.rb`
Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add lib/ruboto/intelligence/pattern_detector.rb
git commit -m "feat: add pattern detector module for recurring request, time, and sequence detection"
```

---

### Task 2: Proactive Triggers Module

**Files:**
- Create: `lib/ruboto/intelligence/proactive_triggers.rb`

**Step 1: Create the proactive triggers module**

Create `lib/ruboto/intelligence/proactive_triggers.rb`:

```ruby
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
        # Triggers are non-critical — never crash startup
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
```

**Step 2: Verify syntax**

Run: `ruby -c lib/ruboto/intelligence/proactive_triggers.rb`
Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add lib/ruboto/intelligence/proactive_triggers.rb
git commit -m "feat: add proactive triggers module with time-based, overdue, and confidence-based suggestions"
```

---

### Task 3: Task Planner Module

**Files:**
- Create: `lib/ruboto/intelligence/task_planner.rb`

**Step 1: Create the task planner module**

Create `lib/ruboto/intelligence/task_planner.rb`:

```ruby
# frozen_string_literal: true

module Ruboto
  module Intelligence
    module TaskPlanner
      KEYWORD_TOOLS = {
        %w[meeting calendar schedule event today] => ["macos_auto:calendar_today"],
        %w[email mail inbox message unread] => ["macos_auto:mail_read"],
        %w[send reply compose draft] => ["macos_auto:mail_send"],
        %w[remind reminder todo followup follow-up] => ["macos_auto:reminder_add"],
        %w[note notes document summary summarize] => ["macos_auto:note_create"],
        %w[search look find online website browse research] => ["browser:open_url", "browser:get_text"],
        %w[open launch app application start] => ["macos_auto:open_app"],
        %w[copy paste clipboard] => ["macos_auto:clipboard_read", "macos_auto:clipboard_write"],
        %w[notify notification alert] => ["macos_auto:notify"],
        %w[read file code project] => ["read"],
        %w[run test build command execute] => ["verify"]
      }.freeze

      GATHER_TOOLS = %w[calendar_today mail_read clipboard_read get_url get_title get_text get_links tabs read].freeze
      OUTPUT_TOOLS = %w[mail_send reminder_add note_create clipboard_write open_url fill click notify].freeze

      def tool_plan(args)
        goal = args["goal"]
        return "error: goal is required" unless goal && !goal.strip.empty?

        steps = generate_plan(goal)
        if steps.empty?
          return "This goal is straightforward — handle it directly without a formal plan."
        end

        result = "Plan for: #{goal}\n\n"
        steps.each_with_index do |step, i|
          result += "#{i + 1}. [#{step[:tool]}] #{step[:description]}\n"
        end
        result += "\nExecute each step using the indicated tool. Adapt if a step fails — skip it or find alternatives."
        result
      end

      def plan_schema
        {
          type: "function",
          name: "plan",
          description: "Break a complex multi-step request into an ordered plan using available tools. Use for tasks like meeting prep, report generation, research, or any request that needs multiple tools chained together. Returns numbered steps with the tool to use for each.",
          parameters: {
            type: "object",
            properties: {
              goal: { type: "string", description: "The complex task or goal to plan for" }
            },
            required: ["goal"]
          }
        }
      end

      private

      def generate_plan(goal)
        goal_words = goal.downcase.split(/\W+/)
        matched_tools = []

        KEYWORD_TOOLS.each do |keywords, tools|
          if keywords.any? { |kw| goal_words.include?(kw) }
            tools.each { |t| matched_tools << t unless matched_tools.include?(t) }
          end
        end

        # Check workflows for matching steps
        workflow_steps = check_workflows_for_goal(goal)
        return workflow_steps unless workflow_steps.empty?

        # Need at least 2 tools to justify a plan
        return [] if matched_tools.length <= 1

        build_ordered_steps(matched_tools, goal)
      end

      def check_workflows_for_goal(goal)
        escaped = goal.downcase.gsub("'", "''")
        sql = "SELECT name, steps FROM workflows WHERE lower(trigger) LIKE '%#{escaped}%' OR lower(name) LIKE '%#{escaped}%' LIMIT 1;"
        result = run_sql(sql)
        return [] if result.empty?

        cols = result.split("|")
        return [] if cols.length < 2

        steps_text = cols[1]
        steps_text.split(",").map.with_index do |step, i|
          { tool: "workflow_step", description: step.strip }
        end
      end

      def build_ordered_steps(tools, goal)
        gather = []
        output = []
        other = []

        tools.each do |tool|
          action = tool.split(":").last || tool
          step = { tool: tool, description: describe_step(tool, goal) }
          if GATHER_TOOLS.include?(action)
            gather << step
          elsif OUTPUT_TOOLS.include?(action)
            output << step
          else
            other << step
          end
        end

        gather + other + output
      end

      def describe_step(tool, goal)
        _tool_name, action = tool.split(":", 2)
        case action || tool
        when "calendar_today" then "Check today's calendar for relevant events"
        when "mail_read" then "Check recent emails for relevant context"
        when "mail_send" then "Compose and send email based on findings"
        when "reminder_add" then "Create a reminder for follow-up"
        when "note_create" then "Create a note summarizing findings"
        when "open_url" then "Open relevant webpage in Safari"
        when "get_text" then "Extract text content from the current page"
        when "get_links" then "Extract links from the current page"
        when "clipboard_read" then "Read clipboard contents"
        when "clipboard_write" then "Copy results to clipboard"
        when "open_app" then "Launch the relevant application"
        when "notify" then "Send a notification with the result"
        when "read" then "Read relevant project files"
        when "verify" then "Run and verify the command"
        else "Use #{tool}"
        end
      end
    end
  end
end
```

**Step 2: Verify syntax**

Run: `ruby -c lib/ruboto/intelligence/task_planner.rb`
Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add lib/ruboto/intelligence/task_planner.rb
git commit -m "feat: add task planner module with keyword-based plan generation"
```

---

### Task 4: Wire Intelligence Modules into ruboto.rb

**Files:**
- Modify: `lib/ruboto.rb:11-14` (add requires)
- Modify: `lib/ruboto.rb:72-76` (add includes)

**Step 1: Add require_relative lines**

In `lib/ruboto.rb`, after line 14 (`require_relative "ruboto/tools/browser"`), add:

```ruby
require_relative "ruboto/intelligence/pattern_detector"
require_relative "ruboto/intelligence/proactive_triggers"
require_relative "ruboto/intelligence/task_planner"
```

**Step 2: Add include lines**

In `lib/ruboto.rb`, after line 76 (`include Tools::Browser`), add:

```ruby
    include Intelligence::PatternDetector
    include Intelligence::ProactiveTriggers
    include Intelligence::TaskPlanner
```

**Step 3: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax OK`

**Step 4: Verify all modules load**

Run: `ruby -Ilib -e 'require "ruboto"; puts Ruboto.respond_to?(:detect_patterns); puts Ruboto.respond_to?(:check_triggers); puts Ruboto.respond_to?(:tool_plan)'`
Expected:
```
true
true
true
```

**Step 5: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: wire intelligence modules (pattern detector, triggers, task planner) into main module"
```

---

### Task 5: Register Plan Tool and Add Spinner Label

**Files:**
- Modify: `lib/ruboto.rb:119-126` (add spinner label for plan)
- Modify: `lib/ruboto.rb:735-740` (add plan tool to tools hash)

**Step 1: Add spinner label**

In `lib/ruboto.rb`, in the `tool_message` method, add a new `when` clause after the `"browser"` case (after line 123 `"Safari: #{action.tr('_', ' ')}"`):

```ruby
      when "plan"
        goal = args["goal"] || "task"
        "Planning: #{goal[0, 40]}#{goal.length > 40 ? '...' : ''}"
```

**Step 2: Add plan tool to tools hash**

In `lib/ruboto.rb`, in the `tools` method, after the `"browser"` entry (after `schema: browser_schema` and its closing `}`), add:

```ruby
        "plan" => {
          impl: method(:tool_plan),
          schema: plan_schema
        }
```

**Step 3: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax OK`

**Step 4: Verify tool is registered**

Run: `ruby -Ilib -e 'require "ruboto"; puts Ruboto.tools.keys.sort.join(", ")'`
Expected output should include `plan` in the list.

**Step 5: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: register plan tool with spinner label"
```

---

### Task 6: Add Startup Intelligence (detect + suggest) and Suggestion Handling

**Files:**
- Modify: `lib/ruboto.rb:1151-1160` (add detect_patterns and check_triggers to run method)
- Modify: `lib/ruboto.rb:1229-1240` (add suggestion handling to REPL input)

**Step 1: Add intelligence startup to run method**

In `lib/ruboto.rb`, in the `run` method, after `ensure_db_exists` (line 1152) and before `load_readline_history` (line 1153), add:

```ruby
      detect_patterns
```

After `session_id = Time.now.strftime(...)` (line 1159) and before `# Build memory context` (line 1161), add:

```ruby
      suggestions = check_triggers
      print_suggestions(suggestions)
```

**Step 2: Add suggestion handling in REPL loop**

In the `run` method, after `next if user_input.empty?` (line 1238) and before the `/q` exit check (line 1239), add:

```ruby
          # Handle suggestion selection
          if !suggestions.empty? && user_input.match?(/\A\d+\z/)
            action = handle_suggestion_input(user_input, suggestions)
            if action
              user_input = action
              puts "#{GREEN}✓#{RESET} #{action}"
            end
          end

          # After first non-empty input, clear suggestions (weaken if ignored)
          unless suggestions.empty?
            unless user_input.match?(/\A\d+\z/) && handle_suggestion_input(user_input, suggestions)
              weaken_all_suggestions(suggestions)
            end
            suggestions = []
          end
```

**Step 3: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax OK`

**Step 4: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add startup intelligence (pattern detection + proactive suggestions) to REPL"
```

---

### Task 7: Update System Prompt and Help Text

**Files:**
- Modify: `lib/ruboto.rb:1178-1184` (add plan to META-TOOLS)
- Modify: `lib/ruboto.rb:1205-1210` (add INTELLIGENCE RULES section)
- Modify: `lib/ruboto.rb:1135-1138` (update help capabilities)

**Step 1: Add plan to META-TOOLS in system prompt**

In the system prompt, after the `memory` line in META-TOOLS section, add:

```
           - plan: Break complex requests into step-by-step plans using available tools
```

**Step 2: Add INTELLIGENCE RULES section**

After the ACTION RULES section and before CRITICAL - BASH TOOL RULES, add:

```
        INTELLIGENCE RULES:
        - For complex multi-step requests, use the plan tool first to structure the approach
        - Detected patterns and suggestions are shown to the user at session start
        - When executing a plan, adapt if a step fails -- skip or find alternatives
        - The plan tool returns advisory steps -- you decide execution order and can skip/add steps
```

**Step 3: Update help text capabilities**

In `print_help`, add after the Safari capabilities line:

```ruby
          #{DIM}•#{RESET} Intelligence: pattern detection, proactive suggestions, task planning
```

**Step 4: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax OK`

**Step 5: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: update system prompt with plan tool and intelligence rules"
```

---

### Task 8: Integration Smoke Tests

**Files:**
- None (manual testing)

**Step 1: Verify all 16 tools load**

Run: `ruby -Ilib -e 'require "ruboto"; puts "#{Ruboto.tools.length} tools"; Ruboto.tools.each_key { |k| puts "  - #{k}" }'`
Expected: 16 tools listed, including `plan`.

**Step 2: Test pattern detector with empty DB**

Run: `ruby -Ilib -e 'require "ruboto"; Ruboto.send(:ensure_db_exists); Ruboto.detect_patterns; puts "Pattern detection OK"'`
Expected: `Pattern detection OK` (no crash on empty data)

**Step 3: Test proactive triggers with empty DB**

Run: `ruby -Ilib -e 'require "ruboto"; Ruboto.send(:ensure_db_exists); s = Ruboto.check_triggers; puts "#{s.length} suggestions"; puts "Triggers OK"'`
Expected: `0 suggestions` and `Triggers OK`

**Step 4: Test plan tool**

Run: `ruby -Ilib -e 'require "ruboto"; puts Ruboto.tool_plan({"goal" => "prep for my 2pm meeting with client and send follow-up email"})'`
Expected: Multi-step plan with calendar, mail, and note steps.

**Step 5: Test plan tool with simple goal**

Run: `ruby -Ilib -e 'require "ruboto"; puts Ruboto.tool_plan({"goal" => "check calendar"})'`
Expected: "This goal is straightforward" (only 1 tool matched, no plan needed).

**Step 6: Commit smoke test results**

```bash
git add -A
git commit -m "test: Phase 3 intelligence layer integration smoke tests passed"
```
