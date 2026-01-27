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
        steps_text.split(",").map do |step|
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
