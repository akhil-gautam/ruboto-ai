# Phase 2: Action Framework Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add macOS system automation and Safari browser control to Ruboto via two new LLM tools (`macos_auto` and `browser`), built on a shared osascript engine with a confirmation safety gate. Code is modular — new files, not added to the monolith.

**Architecture:** Shared osascript engine in `lib/ruboto/osascript.rb`, safety layer in `lib/ruboto/safety.rb`, tool handlers in `lib/ruboto/tools/macos_auto.rb` and `lib/ruboto/tools/browser.rb`. Main `lib/ruboto.rb` requires these modules and integrates them into the existing `tools` hash and system prompt.

**Tech Stack:** Ruby, AppleScript, JXA (JavaScript for Automation), `Open3.capture3`, `Timeout`, Safari

---

### Task 1: osascript Engine Module

**Files:**
- Create: `lib/ruboto/osascript.rb`
- Modify: `lib/ruboto.rb:1-10` — add `require "timeout"` and `require_relative` for new module

**Step 1: Create the osascript engine module**

Create `lib/ruboto/osascript.rb`:

```ruby
# frozen_string_literal: true

require "open3"
require "timeout"

module Ruboto
  module Osascript
    TIMEOUT = 30

    def run_applescript(script)
      Timeout.timeout(TIMEOUT) do
        stdout, stderr, status = Open3.capture3("osascript", "-e", script)
        if status.success?
          { success: true, output: stdout.chomp, error: "" }
        else
          { success: false, output: "", error: stderr.chomp }
        end
      end
    rescue Timeout::Error
      { success: false, output: "", error: "Timed out after #{TIMEOUT}s" }
    rescue Errno::ENOENT
      { success: false, output: "", error: "osascript not found — macOS required" }
    rescue => e
      { success: false, output: "", error: e.message }
    end

    def run_jxa(script)
      Timeout.timeout(TIMEOUT) do
        stdout, stderr, status = Open3.capture3("osascript", "-l", "JavaScript", "-e", script)
        if status.success?
          { success: true, output: stdout.chomp, error: "" }
        else
          { success: false, output: "", error: stderr.chomp }
        end
      end
    rescue Timeout::Error
      { success: false, output: "", error: "Timed out after #{TIMEOUT}s" }
    rescue Errno::ENOENT
      { success: false, output: "", error: "osascript not found — macOS required" }
    rescue => e
      { success: false, output: "", error: e.message }
    end
  end
end
```

**Step 2: Require the module from main file**

In `lib/ruboto.rb`, after `require_relative "ruboto/version"` (line 10), add:

```ruby
require_relative "ruboto/osascript"
```

**Step 3: Include the module in `class << self`**

In `lib/ruboto.rb`, right after `class << self` (line 68), add:

```ruby
    include Osascript
    include Safety
```

(We'll create Safety in the next task — add both includes now so we only touch this line once.)

**Step 4: Verify syntax**

Run: `ruby -c lib/ruboto/osascript.rb && ruby -c lib/ruboto.rb`
Expected: `Syntax check OK` for both (Safety will fail — that's expected, we handle it in Task 2)

Actually, skip the syntax check for `lib/ruboto.rb` until Task 2 is done. Just check the new file:

Run: `ruby -c lib/ruboto/osascript.rb`
Expected: `Syntax check OK`

**Step 5: Commit**

```bash
git add lib/ruboto/osascript.rb lib/ruboto.rb
git commit -m "feat: add osascript engine module (run_applescript, run_jxa)"
```

---

### Task 2: Safety Module

**Files:**
- Create: `lib/ruboto/safety.rb`
- Modify: `lib/ruboto.rb` — add `require_relative`

**Step 1: Create the safety module**

Create `lib/ruboto/safety.rb`:

```ruby
# frozen_string_literal: true

module Ruboto
  module Safety
    def confirm_action(description)
      print "\n\033[33m⚠ Action: #{description}\033[0m\n"
      print "\033[1mProceed? [y/N]:\033[0m "
      $stdout.flush
      answer = $stdin.gets&.strip&.downcase
      answer == "y" || answer == "yes"
    end
  end
end
```

**Step 2: Require the module from main file**

In `lib/ruboto.rb`, after the osascript require (added in Task 1), add:

```ruby
require_relative "ruboto/safety"
```

**Step 3: Verify both files and main**

Run: `ruby -c lib/ruboto/safety.rb && ruby -c lib/ruboto.rb`
Expected: `Syntax check OK` for both

**Step 4: Commit**

```bash
git add lib/ruboto/safety.rb lib/ruboto.rb
git commit -m "feat: add safety module with confirm_action for destructive actions"
```

---

### Task 3: `macos_auto` Tool Module

**Files:**
- Create: `lib/ruboto/tools/macos_auto.rb`
- Modify: `lib/ruboto.rb` — add `require_relative`

**Step 1: Create the tools directory and module**

Create `lib/ruboto/tools/macos_auto.rb`:

```ruby
# frozen_string_literal: true

require "json"

module Ruboto
  module Tools
    module MacosAuto
      def tool_macos_auto(args)
        action = args["action"]

        case action
        when "open_app"
          app = args["app_name"]
          return "error: app_name required" unless app
          result = run_applescript("tell application \"#{app.gsub('"', '\\"')}\" to activate")
          result[:success] ? "Opened #{app}" : "error: #{result[:error]}"

        when "notify"
          title = (args["title"] || "Ruboto").gsub('"', '\\"')
          body = (args["body"] || "").gsub('"', '\\"')
          result = run_applescript("display notification \"#{body}\" with title \"#{title}\"")
          result[:success] ? "Notification sent" : "error: #{result[:error]}"

        when "clipboard_read"
          result = run_applescript("the clipboard")
          result[:success] ? result[:output] : "error: #{result[:error]}"

        when "clipboard_write"
          text = args["value"]
          return "error: value required" unless text
          escaped = text.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
          result = run_applescript("set the clipboard to \"#{escaped}\"")
          result[:success] ? "Copied to clipboard" : "error: #{result[:error]}"

        when "calendar_today"
          jxa = <<~JS.strip
            var app = Application("Calendar");
            var now = new Date();
            var start = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 0, 0, 0);
            var end_ = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59);
            var cals = app.calendars();
            var events = [];
            for (var c = 0; c < cals.length; c++) {
              var evts = cals[c].events.whose({startDate: {_greaterThan: start}, startDate: {_lessThan: end_}})();
              for (var e = 0; e < evts.length; e++) {
                events.push({
                  title: evts[e].summary(),
                  start: evts[e].startDate().toLocaleTimeString(),
                  end: evts[e].endDate().toLocaleTimeString(),
                  location: evts[e].location() || ""
                });
              }
            }
            JSON.stringify(events);
          JS
          result = run_jxa(jxa)
          if result[:success]
            events = JSON.parse(result[:output]) rescue []
            if events.empty?
              "No events today."
            else
              events.map { |e| "#{e['start']}-#{e['end']}: #{e['title']}#{e['location'].empty? ? '' : " (#{e['location']})"}" }.join("\n")
            end
          else
            "error: #{result[:error]}"
          end

        when "reminder_add"
          title = args["title"]
          return "error: title required" unless title
          escaped_title = title.gsub('"', '\\"')
          due = args["due_date"]
          if due
            script = "tell application \"Reminders\"\nmake new reminder with properties {name:\"#{escaped_title}\", due date:date \"#{due.gsub('"', '\\"')}\"}\nend tell"
          else
            script = "tell application \"Reminders\"\nmake new reminder with properties {name:\"#{escaped_title}\"}\nend tell"
          end
          result = run_applescript(script)
          result[:success] ? "Reminder created: #{title}" : "error: #{result[:error]}"

        when "note_create"
          title = args["title"] || "Untitled"
          body = args["body"] || ""
          folder = args["folder"] || "Notes"
          escaped_title = title.gsub('"', '\\"')
          escaped_body = body.gsub('"', '\\"')
          escaped_folder = folder.gsub('"', '\\"')
          script = "tell application \"Notes\"\ntell folder \"#{escaped_folder}\"\nmake new note with properties {name:\"#{escaped_title}\", body:\"#{escaped_body}\"}\nend tell\nend tell"
          result = run_applescript(script)
          result[:success] ? "Note created: #{title}" : "error: #{result[:error]}"

        when "mail_send"
          to = args["to"]
          subject = args["subject"] || ""
          body = args["body"] || ""
          return "error: 'to' address required" unless to

          description = "Send email to #{to}: \"#{subject}\""
          return "Cancelled by user." unless confirm_action(description)

          escaped_to = to.gsub('"', '\\"')
          escaped_subj = subject.gsub('"', '\\"')
          escaped_body = body.gsub('"', '\\"')
          script = <<~APPLESCRIPT.strip
            tell application "Mail"
              set newMsg to make new outgoing message with properties {subject:"#{escaped_subj}", content:"#{escaped_body}", visible:false}
              tell newMsg
                make new to recipient with properties {address:"#{escaped_to}"}
              end tell
              send newMsg
            end tell
          APPLESCRIPT
          result = run_applescript(script)
          result[:success] ? "Email sent to #{to}" : "error: #{result[:error]}"

        when "mail_read"
          limit = (args["limit"] || 5).to_i.clamp(1, 20)
          jxa = <<~JS.strip
            var mail = Application("Mail");
            var inbox = mail.inbox();
            var msgs = inbox.messages();
            var results = [];
            var count = Math.min(#{limit}, msgs.length);
            for (var i = 0; i < count; i++) {
              var m = msgs[i];
              results.push({
                from: m.sender(),
                subject: m.subject(),
                date: m.dateReceived().toLocaleString(),
                read: m.readStatus()
              });
            }
            JSON.stringify(results);
          JS
          result = run_jxa(jxa)
          if result[:success]
            emails = JSON.parse(result[:output]) rescue []
            if emails.empty?
              "No emails found."
            else
              emails.map { |e| "#{e['read'] ? ' ' : '*'} #{e['from']}: #{e['subject']} (#{e['date']})" }.join("\n")
            end
          else
            "error: #{result[:error]}"
          end

        when "finder_reveal"
          path = args["path"]
          return "error: path required" unless path
          escaped = path.gsub('"', '\\"')
          result = run_applescript("tell application \"Finder\" to reveal POSIX file \"#{escaped}\"")
          run_applescript("tell application \"Finder\" to activate") if result[:success]
          result[:success] ? "Opened Finder at #{path}" : "error: #{result[:error]}"

        else
          "error: unknown action '#{action}'. Use: open_app, notify, clipboard_read, clipboard_write, calendar_today, reminder_add, note_create, mail_send, mail_read, finder_reveal"
        end
      rescue => e
        "error: #{e.message}"
      end

      def macos_auto_schema
        {
          type: "function",
          name: "macos_auto",
          description: "Control macOS apps: open apps, notifications, clipboard, calendar, reminders, notes, email, Finder. Use for any system-level automation.",
          parameters: {
            type: "object",
            properties: {
              action: {
                type: "string",
                description: "Action to perform",
                enum: ["open_app", "notify", "clipboard_read", "clipboard_write", "calendar_today", "reminder_add", "note_create", "mail_send", "mail_read", "finder_reveal"]
              },
              app_name: { type: "string", description: "App name (for open_app)" },
              title: { type: "string", description: "Title (for notify, reminder_add, note_create)" },
              body: { type: "string", description: "Body text (for notify, note_create, mail_send)" },
              to: { type: "string", description: "Email address (for mail_send)" },
              subject: { type: "string", description: "Email subject (for mail_send)" },
              path: { type: "string", description: "File/folder path (for finder_reveal)" },
              folder: { type: "string", description: "Notes folder (for note_create, default: Notes)" },
              value: { type: "string", description: "Text value (for clipboard_write)" },
              due_date: { type: "string", description: "Due date string (for reminder_add, e.g. 'January 28, 2026 9:00 AM')" },
              limit: { type: "integer", description: "Max results (for mail_read, default: 5)" }
            },
            required: ["action"]
          }
        }
      end
    end
  end
end
```

**Step 2: Add require in main file**

In `lib/ruboto.rb`, after the safety require, add:

```ruby
require_relative "ruboto/tools/macos_auto"
```

**Step 3: Include the module**

In `lib/ruboto.rb`, after the `include Safety` line (added in Task 1), add:

```ruby
    include Tools::MacosAuto
    include Tools::Browser
```

(Browser module created in Task 4 — add both includes now.)

**Step 4: Verify syntax of new file**

Run: `ruby -c lib/ruboto/tools/macos_auto.rb`
Expected: `Syntax check OK`

**Step 5: Commit**

```bash
git add lib/ruboto/tools/macos_auto.rb lib/ruboto.rb
git commit -m "feat: add macos_auto tool module with 10 actions"
```

---

### Task 4: `browser` Tool Module

**Files:**
- Create: `lib/ruboto/tools/browser.rb`
- Modify: `lib/ruboto.rb` — add `require_relative`

**Step 1: Create the browser tool module**

Create `lib/ruboto/tools/browser.rb`:

```ruby
# frozen_string_literal: true

require "json"

module Ruboto
  module Tools
    module Browser
      MAX_PAGE_TEXT = 10_000

      def tool_browser(args)
        action = args["action"]

        case action
        when "open_url"
          url = args["url"]
          return "error: url required" unless url
          escaped = url.gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\"\nactivate\nopen location \"#{escaped}\"\nend tell")
          result[:success] ? "Opened #{url}" : "error: #{result[:error]}"

        when "get_url"
          result = run_applescript("tell application \"Safari\" to get URL of current tab of front window")
          result[:success] ? result[:output] : "error: #{result[:error]}"

        when "get_title"
          result = run_applescript("tell application \"Safari\" to get name of current tab of front window")
          result[:success] ? result[:output] : "error: #{result[:error]}"

        when "get_text"
          result = run_applescript("tell application \"Safari\" to do JavaScript \"document.body.innerText\" in current tab of front window")
          if result[:success]
            text = result[:output]
            text.length > MAX_PAGE_TEXT ? text[0, MAX_PAGE_TEXT] + "\n... (truncated)" : text
          else
            if result[:error].include?("not allowed") || result[:error].include?("JavaScript")
              "error: Safari's 'Allow JavaScript from Apple Events' is disabled. Enable it in Safari > Develop > Allow JavaScript from Apple Events"
            else
              "error: #{result[:error]}"
            end
          end

        when "get_links"
          js = "JSON.stringify(Array.from(document.querySelectorAll('a[href]')).slice(0,100).map(a=>({text:a.innerText.trim().substring(0,80),href:a.href})))"
          escaped_js = js.gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\" to do JavaScript \"#{escaped_js}\" in current tab of front window")
          if result[:success]
            links = JSON.parse(result[:output]) rescue []
            links.empty? ? "No links found." : links.map { |l| "#{l['text']} -> #{l['href']}" }.join("\n")
          else
            "error: #{result[:error]}"
          end

        when "run_js"
          js_code = args["js_code"]
          return "error: js_code required" unless js_code

          description = "Run JavaScript in Safari: #{js_code[0, 80]}#{js_code.length > 80 ? '...' : ''}"
          return "Cancelled by user." unless confirm_action(description)

          escaped = js_code.gsub('\\', '\\\\\\\\').gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\" to do JavaScript \"#{escaped}\" in current tab of front window")
          result[:success] ? (result[:output].empty? ? "JS executed (no return value)" : result[:output]) : "error: #{result[:error]}"

        when "click"
          selector = args["selector"]
          return "error: selector required" unless selector
          escaped_sel = selector.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("'", "\\\\'")
          js = "document.querySelector('#{escaped_sel}').click(); 'clicked'"
          escaped_js = js.gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\" to do JavaScript \"#{escaped_js}\" in current tab of front window")
          result[:success] ? "Clicked #{selector}" : "error: #{result[:error]}"

        when "fill"
          selector = args["selector"]
          value = args["value"]
          return "error: selector and value required" unless selector && value
          escaped_sel = selector.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("'", "\\\\'")
          escaped_val = value.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("'", "\\\\'")
          js = "var el=document.querySelector('#{escaped_sel}'); el.value='#{escaped_val}'; el.dispatchEvent(new Event('input',{bubbles:true})); 'filled'"
          escaped_js = js.gsub('"', '\\"')
          result = run_applescript("tell application \"Safari\" to do JavaScript \"#{escaped_js}\" in current tab of front window")
          result[:success] ? "Filled #{selector}" : "error: #{result[:error]}"

        when "screenshot"
          tmp = "/tmp/ruboto_screenshot_#{Time.now.to_i}.png"
          result = run_applescript("do shell script \"screencapture -l $(osascript -e 'tell app \\\"Safari\\\" to id of window 1') #{tmp}\"")
          if result[:success] && File.exist?(tmp)
            "Screenshot saved: #{tmp}"
          else
            "error: #{result[:error]}"
          end

        when "tabs"
          jxa = <<~JS.strip
            var safari = Application("Safari");
            var wins = safari.windows();
            var tabs = [];
            for (var w = 0; w < wins.length; w++) {
              var wtabs = wins[w].tabs();
              for (var t = 0; t < wtabs.length; t++) {
                tabs.push({index: tabs.length, title: wtabs[t].name(), url: wtabs[t].url()});
              }
            }
            JSON.stringify(tabs);
          JS
          result = run_jxa(jxa)
          if result[:success]
            tabs_list = JSON.parse(result[:output]) rescue []
            tabs_list.empty? ? "No tabs open." : tabs_list.map { |t| "[#{t['index']}] #{t['title']} - #{t['url']}" }.join("\n")
          else
            "error: #{result[:error]}"
          end

        when "switch_tab"
          idx = args["tab_index"]
          return "error: tab_index required" unless idx
          idx = idx.to_i
          jxa = <<~JS.strip
            var safari = Application("Safari");
            var wins = safari.windows();
            var counter = 0;
            for (var w = 0; w < wins.length; w++) {
              var wtabs = wins[w].tabs();
              for (var t = 0; t < wtabs.length; t++) {
                if (counter === #{idx}) {
                  wins[w].currentTab = wtabs[t];
                  safari.activate();
                  JSON.stringify({title: wtabs[t].name(), url: wtabs[t].url()});
                }
                counter++;
              }
            }
            "not found";
          JS
          result = run_jxa(jxa)
          result[:success] ? "Switched to tab #{idx}: #{result[:output]}" : "error: #{result[:error]}"

        else
          "error: unknown action '#{action}'. Use: open_url, get_url, get_title, get_text, get_links, run_js, click, fill, screenshot, tabs, switch_tab"
        end
      rescue => e
        "error: #{e.message}"
      end

      def browser_schema
        {
          type: "function",
          name: "browser",
          description: "Control Safari browser: open URLs, read page text/links, fill forms, click elements, run JavaScript, manage tabs. Use for any web interaction.",
          parameters: {
            type: "object",
            properties: {
              action: {
                type: "string",
                description: "Action to perform",
                enum: ["open_url", "get_url", "get_title", "get_text", "get_links", "run_js", "click", "fill", "screenshot", "tabs", "switch_tab"]
              },
              url: { type: "string", description: "URL to open (for open_url)" },
              selector: { type: "string", description: "CSS selector (for click, fill)" },
              value: { type: "string", description: "Value to fill (for fill)" },
              js_code: { type: "string", description: "JavaScript code (for run_js)" },
              tab_index: { type: "integer", description: "Tab index (for switch_tab)" }
            },
            required: ["action"]
          }
        }
      end
    end
  end
end
```

**Step 2: Add require in main file**

In `lib/ruboto.rb`, after the macos_auto require, add:

```ruby
require_relative "ruboto/tools/browser"
```

**Step 3: Verify syntax**

Run: `ruby -c lib/ruboto/tools/browser.rb && ruby -c lib/ruboto.rb`
Expected: `Syntax check OK` for both

**Step 4: Commit**

```bash
git add lib/ruboto/tools/browser.rb lib/ruboto.rb
git commit -m "feat: add browser tool module with 11 Safari actions"
```

---

### Task 5: Register Tools, Spinner Labels, System Prompt

**Files:**
- Modify: `lib/ruboto.rb` — three changes: tools hash, tool_message, system prompt

**Step 1: Add tools to `tools` hash**

In `lib/ruboto.rb`, in the `tools` method, after the `"memory"` entry (after line 716, before the closing `}`), add:

```ruby
        "macos_auto" => {
          impl: method(:tool_macos_auto),
          schema: macos_auto_schema
        },
        "browser" => {
          impl: method(:tool_browser),
          schema: browser_schema
        }
```

**Step 2: Add spinner labels in `tool_message`**

In `tool_message` method, after the `when "memory"` case (after line 109), before `else`, add:

```ruby
      when "macos_auto"
        action = args["action"] || "action"
        "macOS: #{action.tr('_', ' ')}"
      when "browser"
        action = args["action"] || "action"
        "Safari: #{action.tr('_', ' ')}"
```

**Step 3: Update system prompt — tool hierarchy**

In the `run` method, find the META-TOOLS section (~line 930-934) and replace:

```ruby
        1. META-TOOLS (prefer these):
           - explore: Answer "where is X?" / "how does Y work?" questions
           - patch: Multi-line edits using unified diff format
           - verify: Check if command succeeds (use after code changes)
           - memory: Read/write persistent user memory (profile, workflows, task history)
```

With:

```ruby
        1. META-TOOLS (prefer these):
           - macos_auto: Control macOS apps (calendar, reminders, mail, notes, clipboard, notifications)
           - browser: Interact with Safari (open URLs, read pages, fill forms, click, run JS)
           - explore: Answer "where is X?" / "how does Y work?" questions
           - patch: Multi-line edits using unified diff format
           - verify: Check if command succeeds (use after code changes)
           - memory: Read/write persistent user memory (profile, workflows, task history)
```

**Step 4: Add ACTION RULES to system prompt**

After the MEMORY RULES section (~line 953), add:

```ruby
        ACTION RULES:
        - Use macos_auto to open apps, check calendar, create reminders, send emails, create notes, manage clipboard
        - Use browser to open URLs, read page content, fill forms, click buttons, extract links
        - Chain actions naturally: check calendar → draft email → send it
        - mail_send and browser run_js require user confirmation — just call the tool, user will be prompted
        - If an action fails (app not running, permission denied), report the error and suggest alternatives
```

**Step 5: Update system prompt description line**

Change: `You are a fast, autonomous coding assistant. Working directory: #{Dir.pwd}`
To: `You are a fast, autonomous assistant with coding AND system automation powers. Working directory: #{Dir.pwd}`

**Step 6: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax check OK`

**Step 7: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: register macos_auto and browser tools, update system prompt"
```

---

### Task 6: Update Help Text

**Files:**
- Modify: `lib/ruboto.rb` — update `print_help` method

**Step 1: Add capabilities section to help**

In `print_help`, after the examples section (after `"Run the tests and fix any failures"` line), add:

```ruby
        #{CYAN}Capabilities:#{RESET}
          #{DIM}•#{RESET} Code: read, write, edit, search, run commands
          #{DIM}•#{RESET} macOS: calendar, reminders, email, notes, clipboard, notifications
          #{DIM}•#{RESET} Safari: open URLs, read pages, fill forms, click elements
```

**Step 2: Verify syntax**

Run: `ruby -c lib/ruboto.rb`
Expected: `Syntax check OK`

**Step 3: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: update help text with macOS and Safari capabilities"
```

---

### Task 7: Integration Smoke Test

**Files:**
- No files modified — manual testing

**Step 1: Verify the app loads and shows all tools**

Run: `ruby -e "require_relative 'lib/ruboto'; puts Ruboto.tools.keys.sort.join(', ')"`

Expected output includes: `bash, browser, edit, explore, find, glob, grep, macos_auto, memory, patch, read, tree, verify, write`

**Step 2: Test osascript engine**

Run: `ruby -e "require_relative 'lib/ruboto'; r = Ruboto.run_applescript('return \"hello\"'); puts r.inspect"`

Expected: `{success: true, output: "hello", error: ""}`

**Step 3: Test notification**

Run: `ruby -e "require_relative 'lib/ruboto'; puts Ruboto.tool_macos_auto({'action' => 'notify', 'title' => 'Ruboto', 'body' => 'Phase 2 works!'})"`

Expected: macOS notification appears, output: `Notification sent`

**Step 4: Test clipboard roundtrip**

Run: `ruby -e "require_relative 'lib/ruboto'; Ruboto.tool_macos_auto({'action' => 'clipboard_write', 'value' => 'ruboto-test'}); puts Ruboto.tool_macos_auto({'action' => 'clipboard_read'})"`

Expected: `ruboto-test`

**Step 5: Test browser get_url (if Safari is open)**

Run: `ruby -e "require_relative 'lib/ruboto'; puts Ruboto.tool_browser({'action' => 'get_url'})"`

Expected: URL of current Safari tab, or error if Safari not open

**Step 6: Test tool schema count**

Run: `ruby -e "require_relative 'lib/ruboto'; puts Ruboto.tool_schemas.length"`

Expected: `14` (12 existing + 2 new)

**Step 7: Commit (tag integration test passed)**

```bash
git commit --allow-empty -m "test: Phase 2 integration smoke tests passed"
```

---

## File Structure After Phase 2

```
lib/
  ruboto.rb                      # Main module (existing, modified)
  ruboto/
    version.rb                   # Version (existing)
    osascript.rb                 # NEW: osascript engine
    safety.rb                    # NEW: confirmation safety layer
    tools/
      macos_auto.rb              # NEW: macOS automation tool
      browser.rb                 # NEW: Safari browser tool
```

## Summary

| Task | What | File |
|------|------|------|
| 1 | osascript engine module | `lib/ruboto/osascript.rb` (new) |
| 2 | Safety module | `lib/ruboto/safety.rb` (new) |
| 3 | macOS automation tool (10 actions) | `lib/ruboto/tools/macos_auto.rb` (new) |
| 4 | Browser tool (11 actions) | `lib/ruboto/tools/browser.rb` (new) |
| 5 | Tool registration + spinner + system prompt | `lib/ruboto.rb` (modify) |
| 6 | Help text update | `lib/ruboto.rb` (modify) |
| 7 | Integration smoke test | manual |

**Total:** 4 new files, ~400 lines of new code, 7 tasks, 7 commits
