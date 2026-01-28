# Phase 5: Autonomous Background Daemon — Design Document

## Overview

A long-lived Ruby background daemon that continuously monitors email (and later calendar), extracts actionable intents via LLM classification, and autonomously executes actions after a 5-minute notification countdown. If the user doesn't dismiss the notification, the action proceeds automatically.

## Architecture

Single Ruby process managed by launchd with `KeepAlive: true`. Runs a poll loop every 5 minutes:

1. **Poll sources** — read new emails from Mail.app via JXA
2. **Deduplicate** — compare against `watched_items` SQLite table
3. **Extract intent** — batch LLM call classifying emails into actionable intents
4. **Queue actions** — insert into `action_queue` table with `pending` status
5. **Notify** — send macOS notification with 5-minute countdown and cancel button
6. **Execute mature actions** — after countdown, run via existing tool pipeline
7. **Check briefing schedule** — handle morning/evening briefings internally

No new dependencies. Reuses: `call_api`, `tool_macos_auto`, `tool_browser`, SQLite.

## Intent Extraction

New emails are batched (up to 10) into a single LLM call using the cheapest available model. The prompt requests structured JSON classification:

```json
{
  "items": [
    {
      "email_id": "msg-123",
      "intent": "flight_checkin",
      "confidence": 0.95,
      "data": {
        "airline": "Delta",
        "confirmation": "ABC123",
        "flight": "DL456",
        "date": "2026-02-03",
        "checkin_url": "https://www.delta.com/checkin"
      },
      "action": "Open check-in page, fill confirmation number, complete check-in",
      "urgency": "immediate"
    }
  ]
}
```

### Supported Intents (v1)

| Intent | Extracted Data | Auto-Action |
|--------|---------------|-------------|
| `flight_checkin` | airline, confirmation #, flight #, date, check-in URL | Open check-in page, fill confirmation, attempt check-in |
| `hotel_booking` | hotel name, dates, confirmation # | Save to calendar, notify day before |
| `package_tracking` | carrier, tracking #, tracking URL | Open tracking page, notify on delivery day |
| `bill_due` | vendor, amount, due date | Notify 2 days before due date |
| `meeting_prep` | meeting title, time, attendees, agenda | Gather context from email/calendar before meeting |

Confidence threshold: only queue actions for `confidence >= 0.8`. Below that, notify but don't auto-act.

## Database Schema

Two new tables in `~/.ruboto/history.db`:

```sql
CREATE TABLE action_queue (
  id INTEGER PRIMARY KEY,
  intent TEXT NOT NULL,
  description TEXT,
  source_email_id TEXT,
  extracted_data TEXT,       -- JSON
  action_plan TEXT,          -- prompt for the agentic loop
  status TEXT DEFAULT 'pending',  -- pending/notified/executing/completed/failed/cancelled
  confidence REAL,
  not_before TEXT,           -- ISO timestamp for countdown expiry
  result TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  executed_at TEXT
);

CREATE TABLE watched_items (
  id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,      -- "mail", "calendar"
  source_id TEXT NOT NULL,   -- Mail message ID or calendar event ID
  seen_at TEXT DEFAULT (datetime('now')),
  UNIQUE(source, source_id)
);
```

### Action Lifecycle

1. `pending` — intent extracted, action queued
2. `notified` — notification sent, `not_before` set to now + 5 minutes
3. `executing` — countdown expired, action running via tool pipeline
4. `completed` / `failed` — result stored, confirmation notification sent
5. `cancelled` — user dismissed via cancel button or CLI

## Daemon Process

### Main Loop

```ruby
POLL_INTERVAL = 300      # 5 minutes
COUNTDOWN_SECONDS = 300  # 5-minute auto-act window

def run_daemon
  ensure_db_exists
  ensure_daemon_tables
  log("Ruboto daemon started")

  loop do
    new_emails = poll_mail
    if new_emails.any?
      intents = extract_intents(new_emails)
      intents.each { |item| queue_action(item) }
    end

    notify_pending_actions
    execute_ready_actions
    check_briefing_schedule

    sleep(POLL_INTERVAL)
  rescue => e
    log("Cycle error: #{e.message}")
    sleep(POLL_INTERVAL)
  end
end
```

### Logging

Structured JSON lines to `~/.ruboto/daemon.log`:
```json
{"ts":"2026-01-28T08:30:00","event":"poll","new_emails":3}
{"ts":"2026-01-28T08:30:02","event":"intent","email_id":"abc","intent":"flight_checkin","confidence":0.95}
{"ts":"2026-01-28T08:35:01","event":"execute","action_id":42,"status":"completed"}
```

### Graceful Shutdown

Traps `SIGTERM` (from `launchctl unload`) to finish current cycle and exit cleanly.

### launchd Configuration

Separate plist `com.ruboto.daemon` with `KeepAlive: true`. Installed/uninstalled via `--install-daemon` / `--uninstall-daemon` flags.

## Action Execution

Actions execute within the daemon process using the existing tool pipeline. A new `run_headless` method provides the agentic loop without calling `exit()`:

```ruby
def execute_action(action)
  update_action_status(action[:id], "executing")
  prompt = "#{action[:action_plan]}\n\nExtracted data: #{action[:extracted_data]}"
  result = run_headless(prompt, model: MODELS.first[:id])
  status = result[:success] ? "completed" : "failed"
  update_action_status(action[:id], status, result[:text])
  deliver_notification("#{status == 'completed' ? 'Done' : 'Failed'}: #{action[:description]}", result[:text].to_s[0, 200])
end
```

`run_headless` is like `run_quick` but returns `{success:, text:, tools_used:}` instead of calling `exit()`.

## CLI Integration

### New CLI Flags

| Flag | Purpose |
|------|---------|
| `--daemon` | Start the daemon process (foreground, for launchd) |
| `--install-daemon` | Install `com.ruboto.daemon` launchd plist |
| `--uninstall-daemon` | Remove daemon plist |
| `--cancel-action ID` | Cancel a pending/notified action |
| `--queue` | Show current action queue |

### New REPL Commands

| Command | Purpose |
|---------|---------|
| `/queue` | Show pending/notified/executing actions |
| `/cancel <id>` | Cancel an action from the REPL |

## File Plan

| File | Action |
|------|--------|
| `lib/ruboto/daemon.rb` | New — daemon main loop, polling, intent extraction |
| `lib/ruboto/intelligence/intent_extractor.rb` | New — LLM-based email classification |
| `lib/ruboto/intelligence/action_executor.rb` | New — action queue management and execution |
| `lib/ruboto.rb` | Modify — add `run_headless`, `run_daemon`, daemon DB tables, `/queue` and `/cancel` REPL commands |
| `lib/ruboto/cli.rb` | Modify — add `--daemon`, `--install-daemon`, `--uninstall-daemon`, `--cancel-action`, `--queue` flags |
| `lib/ruboto/scheduler.rb` | Modify — add `install_daemon` / `uninstall_daemon` methods |
