# Phase 4: Interface Expansion Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expand Ruboto beyond the terminal with a menu bar agent, global hotkey, scheduled briefings, and single-shot CLI mode — making the assistant always reachable.

**Architecture:** A thin Swift menu bar app (`RubotoBar`) serves as the persistent GUI shell. All intelligence stays in Ruby. New CLI flags (`--quick`, `--briefing`, `--tasks`) enable headless operation. Scheduled briefings via `launchd`. Zero new Ruby dependencies.

**Tech Stack:** Ruby (core logic), Swift (menu bar + hotkey, ~200 lines), AppleScript (notifications), launchd (scheduling)

---

## Architecture Overview

```
                    +------------------+
                    |   RubotoBar.app  |  (Swift, menu bar)
                    |  - Status icon   |
                    |  - Quick input   |
                    |  - Global hotkey |
                    |  - Cmd+Shift+R   |
                    +--------+---------+
                             |
                    spawns ruboto-ai subprocess
                             |
              +--------------+--------------+
              |              |              |
     --quick "req"    --briefing am    --tasks 5
              |              |              |
              v              v              v
        +------------------------------------+
        |         Ruboto::CLI                |
        |  Parses flags, dispatches mode     |
        +------------------------------------+
              |              |              |
              v              v              v
        run_quick()    run_briefing()   run_tasks()
              |              |              |
              v              v              v
        [LLM + tools]  [Direct tool    [SQLite
         single-shot    calls, no LLM]  query]
              |              |              |
              v              v              v
        stdout/exit    notify + exit    stdout/exit


    launchd (com.ruboto.briefing.plist)
        |
        +-- 8:30am weekdays --> ruboto-ai --briefing morning
        +-- 5:30pm weekdays --> ruboto-ai --briefing evening
```

The Swift app is purely a launcher. Ruboto's Ruby core handles all intelligence. New CLI modes enable headless operation for the menu bar app, hotkey, and scheduled tasks.

## Menu Bar Agent

### RubotoBar Swift App

A lightweight macOS app (~200 lines of Swift) using `NSStatusItem`. No Xcode project needed — compiled with `swiftc` directly.

**Menu items:**
- Quick Input — opens a text field popup, runs `ruboto-ai --quick "request"`
- Morning Briefing — runs `ruboto-ai --briefing morning`
- Open Terminal — launches Terminal.app with `ruboto-ai`
- Recent Tasks — runs `ruboto-ai --tasks 5`, shows in submenu
- Quit

**Status indicator:**
- Idle: monochrome "R" icon
- Working: animated dots while subprocess runs
- Result: brief flash of green (success) or orange (error)

**Location:** `macos/RubotoBar/`

**Files:**
- `AppDelegate.swift` — NSStatusItem, menu, subprocess management, floating panel
- `build.sh` — `swiftc` build command, outputs `RubotoBar.app` bundle

**No Xcode required.** Build with:
```bash
cd macos/RubotoBar && ./build.sh
```

## Global Hotkey

Registered by the RubotoBar Swift app. Default: `Cmd+Shift+R`.

**Behavior:**
1. Press `Cmd+Shift+R` from any app
2. A floating panel (`NSPanel`) appears at top center of screen
3. Type a request, press Enter
4. Panel shows spinner, runs `ruboto-ai --quick "request" --context "app:FrontmostApp"`
5. Result displayed in panel or as macOS notification
6. Press Escape to dismiss

**Context awareness:**
- On hotkey press, Swift app reads `NSWorkspace.shared.frontmostApplication?.localizedName`
- Passes to Ruby via `--context "app:Safari"` flag
- Ruby injects into system prompt: "User is currently in Safari"
- LLM adapts suggestions based on active app

**Implementation:**
- `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` for the hotkey
- `NSPanel` with `level: .floating`, borderless, dark styled
- `NSTextField` for input, `NSTextView` for result display
- Auto-dismiss after 10 seconds of inactivity

## Scheduled Briefings

### Morning Briefing (default: 8:30am weekdays)

Gathers data using existing tools (no LLM call needed):
1. `calendar_today` — today's events
2. `mail_read` with limit 5 — recent unread emails
3. `check_triggers` — proactive suggestions from intelligence layer
4. Overdue workflow check

Formats into a summary, delivers via:
- macOS notification (short version via `notify`)
- Note in Notes.app (full version via `note_create`)

### End-of-Day Summary (default: 5:30pm weekdays)

Gathers from task history:
1. Today's completed tasks from `tasks` table
2. Failed tasks that may need retry
3. Pattern-based suggestions for tomorrow

Same delivery: notification + note.

### Scheduling

A `launchd` plist installed at `~/Library/LaunchAgents/com.ruboto.briefing.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ruboto.briefing</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/env</string>
        <string>ruby</string>
        <string>RUBOTO_BIN_PATH</string>
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
    <string>~/.ruboto/briefing.log</string>
    <key>StandardErrorPath</key>
    <string>~/.ruboto/briefing.log</string>
</dict>
</plist>
```

The `auto` argument picks morning or evening based on current time.

### Install/Uninstall

```bash
ruboto-ai --install-schedule    # Copies plist, runs launchctl load
ruboto-ai --uninstall-schedule  # Runs launchctl unload, removes plist
```

## CLI Modes

### New flags

```
ruboto-ai                          # Default: full REPL (existing)
ruboto-ai --quick "request"        # Single-shot: one request, print result, exit
ruboto-ai --quick "req" --context "app:Safari"  # With app context
ruboto-ai --briefing morning       # Run morning briefing
ruboto-ai --briefing evening       # Run evening briefing
ruboto-ai --briefing auto          # Pick based on current time
ruboto-ai --tasks 5                # Print recent tasks, exit
ruboto-ai --install-schedule       # Install launchd plist
ruboto-ai --uninstall-schedule     # Remove launchd plist
```

### Quick Mode (`--quick`)

1. Skip startup animation, model selection (use default model)
2. Build system prompt with memory context
3. If `--context` provided, append to system prompt
4. Send single user message to LLM
5. Run agentic loop until completion
6. Print final text response to stdout
7. Exit with code 0 (success) or 1 (error)

Output is plain text — no ANSI colors in quick mode (for machine parsing by Swift app).

### Implementation

**New files:**
- `lib/ruboto/cli.rb` — CLI argument parser, dispatches modes
- `lib/ruboto/intelligence/briefings.rb` — Briefing data gathering + formatting
- `lib/ruboto/scheduler.rb` — launchd plist install/uninstall

**Modified files:**
- `bin/ruboto-ai` — Use `Ruboto::CLI.run(ARGV)` instead of `Ruboto.run`
- `lib/ruboto.rb` — Add `run_quick(request, context)`, `run_tasks_cli(limit)` methods

### New REPL command

`/briefing` or `/briefing morning` or `/briefing evening` — runs briefing inline and prints results.

### System prompt update

Add to META-TOOLS:
```
- plan: Break complex requests into step-by-step plans using available tools
```

(Already added in Phase 3.)

Add context awareness note:
```
CONTEXT: User is currently in {app_name}
```
(Only when `--context` is provided.)

### Help text update

Add to Commands:
```
/briefing  run morning/evening briefing
```

Add to Capabilities:
```
Scheduled: morning briefings, end-of-day summaries
```
