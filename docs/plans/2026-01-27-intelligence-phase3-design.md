# Phase 3: Intelligence Layer Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give Ruboto the ability to detect behavioral patterns, surface proactive suggestions at session start, and decompose complex requests into multi-step plans.

**Architecture:** Three new modules under `lib/ruboto/intelligence/` — pattern detector (startup), proactive triggers (startup), and task planner (LLM tool). No background daemon — everything runs at session start or on-demand.

**Tech Stack:** Ruby, SQLite (existing patterns/tasks/workflows tables), keyword matching

---

## Architecture Overview

```
Session Start
    |
    v
+---------------------+
|  Pattern Detector    |  <-- Scans tasks table for recurring behaviors
|  (runs on startup)   |  <-- Writes to patterns table
+----------+----------+
           |
           v
+---------------------+
|  Proactive Triggers  |  <-- Matches patterns + context (time, day)
|  (runs on startup)   |  <-- Prints numbered suggestions to user
+----------+----------+
           |
           v
       REPL Loop
           |
           v
+---------------------+
|  Task Planner        |  <-- New LLM tool: plan(goal)
|  (LLM-invoked)       |  <-- Returns structured step list
+---------------------+
```

Three new modules mixed into the main Ruboto module, following the same pattern as Phase 2 (osascript, safety, macos_auto, browser).

## Pattern Detector

Runs once at session start, silently. Queries the `tasks` table, analyzes results in Ruby, writes findings to the existing `patterns` table.

### What It Detects (3 pattern types)

1. **Recurring requests** — Same or similar requests appearing 3+ times. Uses keyword overlap (shared significant words / total words >= 0.6) to group similar requests. Example: "check my calendar", "what's on my calendar today", "calendar for today" all cluster together.

2. **Time-of-day patterns** — Tasks clustered at similar times. Extracts hour from `created_at`, groups by 2-hour windows. If 3+ tasks with the same tool appear in the same window, it's a pattern. Example: "You tend to check email in the morning" if mail_read shows up 3+ times between 8-10am.

3. **Tool sequences** — Tools that consistently appear together within the same session. If `calendar_today` and `mail_send` co-occur in 3+ sessions, that's a detectable chain. Tracked via `session_id` grouping.

### Implementation

```ruby
module Ruboto
  module Intelligence
    module PatternDetector
      MIN_OCCURRENCES = 3
      SIMILARITY_THRESHOLD = 0.6
      STOP_WORDS = %w[the a an is are was were do does did my me i to for in on what how].freeze

      def detect_patterns
        detect_recurring_requests
        detect_time_patterns
        detect_tool_sequences
      end

      private

      def detect_recurring_requests
        # Query last 100 tasks
        # Extract significant keywords from each request
        # Group by keyword similarity
        # Save clusters with 3+ members as "recurring_request" patterns
      end

      def detect_time_patterns
        # Query tasks with created_at and tools_used
        # Extract hour, group into 2-hour windows (8-10, 10-12, etc.)
        # Find tool+window combos with 3+ occurrences
        # Save as "time_pattern" patterns with conditions = JSON({tool, hour_start, hour_end, day_of_week})
      end

      def detect_tool_sequences
        # Query tasks grouped by session_id
        # Find tool pairs that co-occur in 3+ sessions
        # Save as "tool_sequence" patterns with conditions = JSON({tools: [a, b], sessions: count})
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
    end
  end
end
```

Saves patterns using the existing `save_pattern(type, description, conditions)` helper. Reinforces existing patterns with `reinforce_pattern(id)` if re-detected. Minimum 3 occurrences to create a pattern. Confidence starts at 0.5.

## Proactive Triggers

Runs right after pattern detection at session start. Checks detected patterns against current context (time, day of week) and generates actionable suggestions.

### What It Checks

1. **Time-based triggers** — Current hour/day matches a time_pattern. "It's Monday morning and you usually check your calendar around now."

2. **Overdue workflows** — Workflows with `last_run` older than their typical frequency. If `weekly-report` hasn't run in 8+ days, suggest it. Estimates frequency from the name (weekly = 7 days, daily = 1 day) or defaults to 7 days.

3. **High-confidence patterns** — Any pattern with confidence >= 0.8 that matches current context gets surfaced as a suggestion.

### Output Format

```
  Suggestions based on your patterns:
    1. It's Monday morning -- you usually check your calendar around now
    2. "weekly-report" workflow hasn't run in 9 days

  Type a number to act on it, or just start typing.
```

### User Feedback Loop

- User acts on a suggestion (types its number) -> `reinforce_pattern(id)` (confidence +0.1)
- User ignores all suggestions and types something else -> `weaken_pattern(id)` for each suggestion (confidence -0.1)
- Patterns below 0.5 confidence stop appearing
- Over time, useful suggestions get stronger, irrelevant ones fade

### Implementation

```ruby
module Ruboto
  module Intelligence
    module ProactiveTriggers
      OVERDUE_THRESHOLD_DAYS = 7

      def check_triggers
        suggestions = []
        suggestions += time_based_triggers
        suggestions += overdue_workflow_triggers
        suggestions += high_confidence_triggers
        suggestions.uniq { |s| s[:description] }.first(5)
      end

      def print_suggestions(suggestions)
        return if suggestions.empty?
        # Print formatted suggestion list with numbers
      end

      def handle_suggestion_input(input, suggestions)
        # If input is a number 1-N matching a suggestion:
        #   reinforce the pattern, return the suggestion text as user input
        # Otherwise:
        #   weaken all suggestion patterns, return nil (use original input)
      end

      private

      def time_based_triggers
        # Query time_pattern patterns
        # Check if current hour falls in the pattern's window
        # Check if current day matches (if day_of_week is set)
        # Return matching suggestions with pattern_id for feedback
      end

      def overdue_workflow_triggers
        # Query workflows table
        # Check last_run vs estimated frequency
        # Return overdue workflows as suggestions
      end

      def high_confidence_triggers
        # Query patterns with confidence >= 0.8
        # Filter to recurring_request and tool_sequence types
        # Return as suggestions
      end
    end
  end
end
```

## Task Planner

An LLM tool (not startup logic). Takes a complex goal, returns a structured plan as numbered steps. The LLM then executes each step using existing tools.

### How It Works

```
User: "Prep for my 2pm meeting with Acme Corp"
    |
    v
LLM calls plan(goal: "prep for 2pm meeting with Acme Corp")
    |
    v
Plan tool returns:
  "Steps to accomplish: prep for 2pm meeting with Acme Corp
   1. [macos_auto:calendar_today] Check today's calendar for the 2pm meeting details
   2. [macos_auto:mail_read] Find recent emails from meeting attendees
   3. [browser:get_text] Look up Acme Corp latest news
   4. [macos_auto:note_create] Create meeting prep note with findings

   Execute each step using the indicated tool."
    |
    v
LLM executes each step, adapting as needed
```

### Key Design Decision

The plan tool is *advisory*. It returns text that guides the LLM, not a rigid execution engine. The LLM can skip steps, reorder, or adapt based on results. This keeps it simple and leverages the LLM's reasoning.

### Plan Generation Logic

No inner LLM call. Uses keyword matching and templates:

1. Extract keywords from goal (meeting, email, calendar, report, etc.)
2. Match keywords to available tool capabilities
3. Check user profile/workflows for relevant context
4. Build ordered step list using templates

**Keyword-to-tool mapping:**
- meeting/calendar/schedule -> macos_auto:calendar_today
- email/mail/send/reply -> macos_auto:mail_read, macos_auto:mail_send
- remind/reminder/todo -> macos_auto:reminder_add
- note/notes/document -> macos_auto:note_create
- search/look up/find online -> browser:open_url, browser:get_text
- open/launch/app -> macos_auto:open_app
- clipboard/copy/paste -> macos_auto:clipboard_read, macos_auto:clipboard_write

**Step ordering heuristic:**
1. Gather information first (read calendar, read email, browse)
2. Process/analyze (implicit — LLM handles this between tool calls)
3. Create output (write notes, send email, create reminder)

### Implementation

```ruby
module Ruboto
  module Intelligence
    module TaskPlanner
      KEYWORD_TOOLS = {
        %w[meeting calendar schedule event] => ["macos_auto:calendar_today"],
        %w[email mail inbox message] => ["macos_auto:mail_read"],
        %w[send reply compose draft] => ["macos_auto:mail_send"],
        %w[remind reminder todo] => ["macos_auto:reminder_add"],
        %w[note notes document write] => ["macos_auto:note_create"],
        %w[search look find online website] => ["browser:open_url", "browser:get_text"],
        %w[open launch app application] => ["macos_auto:open_app"],
        %w[copy paste clipboard] => ["macos_auto:clipboard_read", "macos_auto:clipboard_write"],
        %w[read file code] => ["read"],
        %w[run test build command] => ["bash", "verify"]
      }.freeze

      GATHER_TOOLS = %w[calendar_today mail_read clipboard_read get_url get_title get_text get_links tabs].freeze
      OUTPUT_TOOLS = %w[mail_send reminder_add note_create clipboard_write open_url fill click].freeze

      def tool_plan(args)
        goal = args["goal"]
        return "error: goal is required" unless goal && !goal.strip.empty?

        steps = generate_plan(goal)
        return "This goal is straightforward enough to handle directly without a plan." if steps.empty?

        result = "Steps to accomplish: #{goal}\n"
        steps.each_with_index do |step, i|
          result += "#{i + 1}. [#{step[:tool]}] #{step[:description]}\n"
        end
        result += "\nExecute each step using the indicated tool. Adapt if a step fails."
        result
      end

      def plan_schema
        {
          type: "function",
          name: "plan",
          description: "Break a complex request into a step-by-step plan using available tools. Use for multi-step tasks like meeting prep, report generation, research workflows. Returns an ordered list of steps — execute each using the indicated tool.",
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

        return [] if matched_tools.length <= 1

        # Check workflows for matching steps
        workflow_steps = check_workflows_for_goal(goal)

        # Sort: gather first, then output
        steps = build_ordered_steps(matched_tools, goal)
        workflow_steps + steps
      end

      def check_workflows_for_goal(goal)
        # Search workflows table for matching triggers
        # If found, convert workflow steps to plan steps
        []
      end

      def build_ordered_steps(tools, goal)
        gather = []
        output = []
        other = []

        tools.each do |tool|
          action = tool.split(":").last
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
        # Generate human-readable description based on tool and goal context
        tool_name, action = tool.split(":", 2)
        case action || tool_name
        when "calendar_today" then "Check today's calendar for relevant events"
        when "mail_read" then "Check recent emails for relevant context"
        when "mail_send" then "Compose and send email based on findings"
        when "reminder_add" then "Create a reminder for follow-up"
        when "note_create" then "Create a note summarizing findings"
        when "open_url" then "Open relevant webpage in Safari"
        when "get_text" then "Extract text from the current page"
        when "clipboard_read" then "Read clipboard contents"
        when "clipboard_write" then "Copy results to clipboard"
        else "Use #{tool} for this step"
        end
      end
    end
  end
end
```

## Integration with ruboto.rb

### New requires

```ruby
require_relative "ruboto/intelligence/pattern_detector"
require_relative "ruboto/intelligence/proactive_triggers"
require_relative "ruboto/intelligence/task_planner"
```

### New includes

```ruby
include Intelligence::PatternDetector
include Intelligence::ProactiveTriggers
include Intelligence::TaskPlanner
```

### Changes to `run` method

After `ensure_db_exists`, before model selection:
```ruby
detect_patterns
suggestions = check_triggers
print_suggestions(suggestions)
```

In the REPL input handling, before saving to history:
```ruby
# Handle suggestion selection
if !suggestions.empty?
  result = handle_suggestion_input(user_input, suggestions)
  if result
    user_input = result
  else
    # Weaken all suggestion patterns
    suggestions.each { |s| weaken_pattern(s[:pattern_id]) if s[:pattern_id] }
  end
  suggestions = [] # Clear after first input
end
```

### New tool registration

```ruby
"plan" => {
  impl: method(:tool_plan),
  schema: plan_schema
}
```

### Spinner label

```ruby
when "plan"
  goal = args["goal"] || "task"
  "Planning: #{goal[0, 40]}#{goal.length > 40 ? '...' : ''}"
```

### System prompt additions

Add to META-TOOLS:
```
- plan: Break complex requests into step-by-step plans using available tools
```

Add INTELLIGENCE RULES section:
```
INTELLIGENCE RULES:
- For complex multi-step requests, use the plan tool first to structure the approach
- Detected patterns and suggestions are shown to the user at session start
- When executing a plan, adapt if a step fails -- skip or find alternatives
- The plan tool returns advisory steps -- you decide execution order and can skip/add steps
```

### Help text update

Add to Capabilities:
```
Intelligence: pattern detection, proactive suggestions, task planning
```
