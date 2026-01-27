# Phase 4: Interface Expansion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expand Ruboto beyond the terminal with CLI modes (--quick, --briefing, --tasks), scheduled briefings via launchd, and a Swift menu bar agent with global hotkey.

**Architecture:** A new `Ruboto::CLI` module parses ARGV and dispatches to headless modes (quick, briefing, tasks) or the existing REPL. A thin Swift menu bar app (`RubotoBar`) spawns `ruboto-ai` subprocesses. Scheduled briefings run via launchd. Zero new Ruby dependencies.

**Tech Stack:** Ruby (core logic), Swift (menu bar + hotkey, ~200 lines), AppleScript (notifications), launchd (scheduling)

---

### Task 1: CLI Argument Parser

Extract CLI dispatch logic into a new module so `bin/ruboto-ai` can route to different modes based on ARGV.

**Files:**
- Create: `lib/ruboto/cli.rb`
- Modify: `bin/ruboto-ai` (lines 1-6)

**Step 1: Create `lib/ruboto/cli.rb`**

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
      else
        $stderr.puts "Unknown option: #{argv.first}"
        $stderr.puts USAGE
        exit 1
      end
    end
  end
end
```

**Step 2: Update `bin/ruboto-ai`**

Replace the entire file with:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/ruboto/cli"

Ruboto::CLI.run(ARGV)
```

**Step 3: Verify existing REPL still works**

Run: `ruby bin/ruboto-ai` with no arguments — should launch the interactive REPL as before. Ctrl+C to exit.

**Step 4: Verify --help works**

Run: `ruby bin/ruboto-ai --help`
Expected: Prints usage text and exits.

**Step 5: Verify unknown flags error**

Run: `ruby bin/ruboto-ai --bogus`
Expected: "Unknown option: --bogus" on stderr, exits with code 1.

**Step 6: Commit**

```bash
git add lib/ruboto/cli.rb bin/ruboto-ai
git commit -m "feat: add CLI argument parser with mode dispatch"
```

---

### Task 2: Quick Mode

Add `run_quick` to Ruboto — a single-shot headless mode that sends one request to the LLM, runs the agentic loop, prints the result, and exits. No ANSI colors, no animation, no model selection (uses first model).

**Files:**
- Modify: `lib/ruboto.rb` — add `run_quick` method after `run` (after line 1499)

**Step 1: Add `run_quick` method to `lib/ruboto.rb`**

Add after the closing `end` of the `run` method (after line 1499):

```ruby
    def run_quick(request, context: nil)
      ensure_db_exists
      model = MODELS.first[:id]
      session_id = Time.now.strftime("%Y%m%d_%H%M%S")

      # Build memory context
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
          $stderr.puts "Error: #{response.dig("error", "message")}"
          exit 1
        end

        choice = response.dig("choices", 0)
        unless choice
          $stderr.puts "Error: No response from model"
          exit 1
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

      puts final_text if final_text

      # Save task
      unless interaction_tools.empty?
        save_task(request, (final_text || "")[0, 200], interaction_tools.uniq.join(", "), task_success, session_id)
      end

      exit(task_success ? 0 : 1)
    rescue => e
      $stderr.puts "Error: #{e.message}"
      exit 1
    end
```

**Step 2: Verify quick mode runs**

Run: `ruby bin/ruboto-ai --quick "What is 2+2?"`
Expected: Prints a plain text answer and exits with code 0.

**Step 3: Verify --context flag**

Run: `ruby bin/ruboto-ai --quick "What app am I in?" --context "app:Safari"`
Expected: Response mentions Safari context.

**Step 4: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add quick mode (--quick) for single-shot requests"
```

---

### Task 3: Tasks CLI Mode

Add `run_tasks_cli` to Ruboto — prints recent task history as plain text and exits.

**Files:**
- Modify: `lib/ruboto.rb` — add `run_tasks_cli` method after `run_quick`

**Step 1: Add `run_tasks_cli` method**

```ruby
    def run_tasks_cli(limit = 10)
      ensure_db_exists
      data = recent_tasks(limit)
      if data.empty?
        puts "No task history."
        return
      end
      data.split("\n").each do |row|
        cols = row.split("|")
        next if cols.length < 4
        status = cols[2] == "1" ? "[OK]" : "[FAIL]"
        puts "#{status} #{cols[0][0, 60]}"
        puts "  #{cols[3]}"
      end
    end
```

**Step 2: Verify**

Run: `ruby bin/ruboto-ai --tasks 5`
Expected: Prints recent tasks or "No task history." and exits.

**Step 3: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add tasks CLI mode (--tasks) for headless task history"
```

---

### Task 4: Briefings Module

Create the briefings module that gathers calendar, email, triggers, and task data to produce morning and evening summaries. Delivers via stdout (for CLI) and macOS notification.

**Files:**
- Create: `lib/ruboto/intelligence/briefings.rb`
- Modify: `lib/ruboto.rb` — add require, include, and `run_briefing` method

**Step 1: Create `lib/ruboto/intelligence/briefings.rb`**

```ruby
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
```

**Step 2: Wire into `lib/ruboto.rb`**

Add require after line 17:
```ruby
require_relative "ruboto/intelligence/briefings"
```

Add include inside `class << self` (after the existing intelligence includes):
```ruby
include Intelligence::Briefings
```

**Step 3: Verify morning briefing**

Run: `ruby bin/ruboto-ai --briefing morning`
Expected: Prints briefing summary with calendar/email/suggestions sections. May show "error" for calendar/email if apps aren't accessible, but should not crash.

**Step 4: Verify evening briefing**

Run: `ruby bin/ruboto-ai --briefing evening`
Expected: Prints end-of-day summary.

**Step 5: Verify auto mode**

Run: `ruby bin/ruboto-ai --briefing auto`
Expected: Picks morning or evening based on current time.

**Step 6: Commit**

```bash
git add lib/ruboto/intelligence/briefings.rb lib/ruboto.rb
git commit -m "feat: add briefings module with morning/evening summaries"
```

---

### Task 5: Scheduler (launchd Integration)

Create the scheduler module to install/uninstall a launchd plist for automated briefings.

**Files:**
- Create: `lib/ruboto/scheduler.rb`
- Modify: `lib/ruboto.rb` — add require, include

**Step 1: Create `lib/ruboto/scheduler.rb`**

```ruby
# frozen_string_literal: true

module Ruboto
  module Scheduler
    PLIST_LABEL = "com.ruboto.briefing"
    PLIST_DIR = File.expand_path("~/Library/LaunchAgents")
    PLIST_PATH = File.join(PLIST_DIR, "#{PLIST_LABEL}.plist")

    def install_schedule
      bin_path = File.expand_path("../../bin/ruboto-ai", __dir__)
      ruby_path = find_ruby_path

      plist_content = <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>#{PLIST_LABEL}</string>
            <key>ProgramArguments</key>
            <array>
                <string>#{ruby_path}</string>
                <string>#{bin_path}</string>
                <string>--briefing</string>
                <string>auto</string>
            </array>
            <key>StartCalendarInterval</key>
            <array>
                <dict>
                    <key>Hour</key><integer>8</integer>
                    <key>Minute</key><integer>30</integer>
                </dict>
                <dict>
                    <key>Hour</key><integer>17</integer>
                    <key>Minute</key><integer>30</integer>
                </dict>
            </array>
            <key>StandardOutPath</key>
            <string>#{RUBOTO_DIR}/briefing.log</string>
            <key>StandardErrorPath</key>
            <string>#{RUBOTO_DIR}/briefing.log</string>
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

      File.write(PLIST_PATH, plist_content)

      # Unload first if already loaded (ignore errors)
      system("launchctl", "unload", PLIST_PATH, err: File::NULL, out: File::NULL)
      success = system("launchctl", "load", PLIST_PATH)

      if success
        puts "Scheduled briefings installed."
        puts "  Morning: 8:30am weekdays"
        puts "  Evening: 5:30pm weekdays"
        puts "  Plist: #{PLIST_PATH}"
        puts "  Log: #{RUBOTO_DIR}/briefing.log"
      else
        $stderr.puts "Error: launchctl load failed. Check plist at #{PLIST_PATH}"
        exit 1
      end
    end

    def uninstall_schedule
      unless File.exist?(PLIST_PATH)
        puts "No schedule installed (#{PLIST_PATH} not found)."
        return
      end

      system("launchctl", "unload", PLIST_PATH, err: File::NULL, out: File::NULL)
      File.delete(PLIST_PATH)
      puts "Scheduled briefings removed."
    end

    private

    def find_ruby_path
      # Use the same Ruby that's running this process
      RbConfig.ruby
    end
  end
end
```

**Step 2: Wire into `lib/ruboto.rb`**

Add require after line 17 (after briefings require):
```ruby
require_relative "ruboto/scheduler"
```

Add include inside `class << self`:
```ruby
include Scheduler
```

Also add `require "rbconfig"` at the top of `lib/ruboto.rb` (after the existing requires, around line 8).

**Step 3: Verify install**

Run: `ruby bin/ruboto-ai --install-schedule`
Expected: Creates plist at `~/Library/LaunchAgents/com.ruboto.briefing.plist`, prints confirmation.

**Step 4: Verify uninstall**

Run: `ruby bin/ruboto-ai --uninstall-schedule`
Expected: Removes plist, prints confirmation.

**Step 5: Commit**

```bash
git add lib/ruboto/scheduler.rb lib/ruboto.rb
git commit -m "feat: add launchd scheduler for automated briefings"
```

---

### Task 6: /briefing REPL Command

Add `/briefing` as a REPL command so users can run briefings inline during an interactive session.

**Files:**
- Modify: `lib/ruboto.rb` — add command handler in REPL loop (around line 1389, before `/history`)

**Step 1: Add /briefing handler**

Insert before the `/history` handler (before line 1389):

```ruby
          if user_input.start_with?("/briefing")
            mode = user_input.split(" ")[1] || "auto"
            run_briefing(mode)
            next
          end
```

**Step 2: Update help text**

In `print_help` method, add after the `/tasks` line:
```ruby
          #{BOLD}/briefing#{RESET} #{DIM}run morning/evening briefing (/briefing morning|evening|auto)#{RESET}
```

**Step 3: Update system prompt capabilities**

In the system prompt section (around line 1248, before "Be concise"), add to the capabilities awareness:
```
Scheduled: morning briefings, end-of-day summaries (via /briefing command or --briefing flag)
```

**Step 4: Verify**

Run `ruby bin/ruboto-ai`, then type `/briefing morning`.
Expected: Prints morning briefing inline, then returns to REPL.

**Step 5: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add /briefing REPL command and update help text"
```

---

### Task 7: Swift Menu Bar App (RubotoBar)

Create the Swift menu bar app. This is a standalone macOS app compiled with `swiftc` — no Xcode required.

**Files:**
- Create: `macos/RubotoBar/AppDelegate.swift`
- Create: `macos/RubotoBar/build.sh`

**Step 1: Create directory**

```bash
mkdir -p macos/RubotoBar
```

**Step 2: Create `macos/RubotoBar/AppDelegate.swift`**

```swift
import Cocoa
import Carbon

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var inputPanel: NSPanel?
    var inputField: NSTextField?
    var resultView: NSTextView?
    var isWorking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "R"
            button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        }

        // Menu
        let menu = NSMenu()
        menu.addItem(withTitle: "Quick Input...", action: #selector(showQuickInput), keyEquivalent: "r")
        menu.addItem(withTitle: "Morning Briefing", action: #selector(runMorningBriefing), keyEquivalent: "")
        menu.addItem(withTitle: "Open Terminal", action: #selector(openTerminal), keyEquivalent: "t")

        let recentItem = NSMenuItem(title: "Recent Tasks", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit RubotoBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu

        // Register global hotkey: Cmd+Shift+R
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 15 { // 15 = R
                DispatchQueue.main.async {
                    self?.showQuickInput()
                }
            }
        }

        // Also monitor local events
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 15 {
                DispatchQueue.main.async {
                    self?.showQuickInput()
                }
                return nil
            }
            return event
        }

        refreshRecentTasks()
    }

    @objc func showQuickInput() {
        if let panel = inputPanel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringAllOtherApps: true)
            inputField?.selectText(nil)
            return
        }

        // Get frontmost app for context
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        // Create floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.title = "Ruboto Quick Input"
        panel.isFloatingPanel = true
        panel.center()

        // Move to top center
        if let screen = NSScreen.main {
            let x = (screen.frame.width - 500) / 2
            let y = screen.frame.height - 300
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))

        // Input field
        let field = NSTextField(frame: NSRect(x: 20, y: 160, width: 460, height: 24))
        field.placeholderString = "Ask Ruboto anything..."
        field.target = self
        field.action = #selector(submitQuickInput(_:))
        field.tag = frontApp.isEmpty ? 0 : 1
        contentView.addSubview(field)
        self.inputField = field

        // Store context
        if !frontApp.isEmpty {
            let label = NSTextField(labelWithString: "Context: \(frontApp)")
            label.frame = NSRect(x: 20, y: 135, width: 460, height: 18)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            contentView.addSubview(label)
        }

        // Result area
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 460, height: 108))
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = ""
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        contentView.addSubview(scrollView)
        self.resultView = textView

        panel.contentView = contentView
        self.inputPanel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringAllOtherApps: true)
        field.becomeFirstResponder()
    }

    @objc func submitQuickInput(_ sender: NSTextField) {
        let request = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        resultView?.string = "Working..."
        statusItem.button?.title = "R·"
        isWorking = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runRuboto(request: request, context: frontApp.isEmpty ? nil : "app:\(frontApp)")
            DispatchQueue.main.async {
                self?.resultView?.string = result ?? "No response"
                self?.statusItem.button?.title = "R"
                self?.isWorking = false
            }
        }
    }

    @objc func runMorningBriefing() {
        statusItem.button?.title = "R·"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runRuboto(args: ["--briefing", "morning"])
            DispatchQueue.main.async {
                self?.statusItem.button?.title = "R"
                if let result = result, !result.isEmpty {
                    self?.showResult("Morning Briefing", result)
                }
            }
        }
    }

    @objc func openTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(FileManager.default.currentDirectoryPath) && ruboto-ai"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    func refreshRecentTasks() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            let result = self?.runRuboto(args: ["--tasks", "5"])
            DispatchQueue.main.async {
                guard let self = self, let result = result else { return }
                let recentItem = self.statusItem.menu?.item(withTitle: "Recent Tasks")
                let submenu = recentItem?.submenu ?? NSMenu()
                submenu.removeAllItems()
                let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
                if lines.isEmpty {
                    submenu.addItem(withTitle: "No recent tasks", action: nil, keyEquivalent: "")
                } else {
                    for line in lines.prefix(10) {
                        submenu.addItem(withTitle: String(line.prefix(60)), action: nil, keyEquivalent: "")
                    }
                }
                recentItem?.submenu = submenu
            }
        }
    }

    func runRuboto(request: String? = nil, context: String? = nil, args: [String]? = nil) -> String? {
        let rubotoPath = findRubotoPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = ["ruby", rubotoPath]
        if let args = args {
            arguments.append(contentsOf: args)
        } else if let request = request {
            arguments.append("--quick")
            arguments.append(request)
            if let context = context {
                arguments.append("--context")
                arguments.append(context)
            }
        }
        process.arguments = arguments

        // Pass through environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    func findRubotoPath() -> String {
        // Look for ruboto-ai relative to this app's bundle
        let bundlePath = Bundle.main.bundlePath
        let projectDir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binPath = projectDir.appendingPathComponent("bin/ruboto-ai").path
        if FileManager.default.fileExists(atPath: binPath) {
            return binPath
        }
        // Fallback: assume it's in PATH
        return "ruboto-ai"
    }

    func showResult(_ title: String, _ body: String) {
        let truncated = String(body.prefix(200))
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = truncated
        NSUserNotificationCenter.default.deliver(notification)
    }
}
```

**Step 3: Create `macos/RubotoBar/build.sh`**

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RubotoBar"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

echo "Building $APP_NAME..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"

# Compile
swiftc \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework Carbon \
    "$SCRIPT_DIR/AppDelegate.swift"

# Create Info.plist
cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>RubotoBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.ruboto.bar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>RubotoBar</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>RubotoBar needs to control apps to run automations.</string>
</dict>
</plist>
EOF

echo "Built: $APP_DIR"
echo "Run: open $APP_DIR"
```

**Step 4: Make build.sh executable**

```bash
chmod +x macos/RubotoBar/build.sh
```

**Step 5: Build and verify**

Run: `cd macos/RubotoBar && ./build.sh`
Expected: Compiles successfully, creates `build/RubotoBar.app`.

**Step 6: Test launch**

Run: `open macos/RubotoBar/build/RubotoBar.app`
Expected: "R" appears in menu bar. Click shows menu with Quick Input, Morning Briefing, Open Terminal, Recent Tasks, Quit.

**Step 7: Commit**

```bash
git add macos/RubotoBar/AppDelegate.swift macos/RubotoBar/build.sh
git commit -m "feat: add RubotoBar Swift menu bar app with global hotkey"
```

---

### Task 8: Integration Testing

Verify all Phase 4 components work together end-to-end.

**Step 1: Verify REPL mode (no args)**

Run: `ruby bin/ruboto-ai`
Expected: Normal interactive REPL launches with model selection.

**Step 2: Verify --help**

Run: `ruby bin/ruboto-ai --help`
Expected: Usage text with all flags documented.

**Step 3: Verify --quick**

Run: `ruby bin/ruboto-ai --quick "list files in current directory"`
Expected: Plain text response with file listing, exits 0.

**Step 4: Verify --quick with --context**

Run: `ruby bin/ruboto-ai --quick "what app am I in?" --context "app:Finder"`
Expected: Response references Finder.

**Step 5: Verify --briefing morning**

Run: `ruby bin/ruboto-ai --briefing morning`
Expected: Morning briefing with calendar/email/suggestions sections.

**Step 6: Verify --briefing evening**

Run: `ruby bin/ruboto-ai --briefing evening`
Expected: Evening summary with completed/failed tasks.

**Step 7: Verify --tasks**

Run: `ruby bin/ruboto-ai --tasks 3`
Expected: Recent 3 tasks listed.

**Step 8: Verify --install-schedule and --uninstall-schedule**

Run:
```bash
ruby bin/ruboto-ai --install-schedule
ls ~/Library/LaunchAgents/com.ruboto.briefing.plist
ruby bin/ruboto-ai --uninstall-schedule
```
Expected: Plist created then removed.

**Step 9: Verify /briefing in REPL**

Run `ruby bin/ruboto-ai`, then type `/briefing morning`.
Expected: Briefing printed inline.

**Step 10: Verify Swift app builds**

Run: `cd macos/RubotoBar && ./build.sh`
Expected: Clean compile, `build/RubotoBar.app` created.

**Step 11: Commit version bump if all passes**

Update `lib/ruboto/version.rb` to `0.3.0`:

```ruby
VERSION = "0.3.0"
```

```bash
git add lib/ruboto/version.rb
git commit -m "chore: bump version to 0.3.0 for Phase 4 (Interface Expansion)"
```
