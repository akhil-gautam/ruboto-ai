# Phase 2: Action Framework Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give Ruboto the ability to take real-world actions on macOS — controlling apps via AppleScript and automating Safari for web tasks.

**Architecture:** Two new LLM tools (`macos_auto` and `browser`) built on a shared osascript execution engine, with a confirmation gate for destructive/external actions. Zero new dependencies — everything via the system `osascript` CLI.

**Tech Stack:** Ruby, AppleScript, JXA (JavaScript for Automation), Safari, macOS native apps

---

## Architecture Overview

```
User Request
    ↓
LLM decides action
    ↓
┌─────────────┐    ┌───────────┐
│ macos_auto  │    │  browser  │
│ (10 actions)│    │(11 actions)│
└──────┬──────┘    └─────┬─────┘
       │                 │
       └────────┬────────┘
                ↓
      ┌─────────────────┐
      │  Safety Layer    │
      │ confirm_action() │
      └────────┬────────┘
               ↓
      ┌─────────────────┐
      │ osascript Engine │
      │ run_applescript() │
      │ run_jxa()        │
      └─────────────────┘
               ↓
         macOS / Safari
```

Two new tools registered in `tools` hash alongside existing tools. Both use the shared osascript engine. Safety layer intercepts actions flagged as requiring confirmation.

## osascript Engine (Shared Foundation)

### `run_applescript(script)`
- Executes AppleScript via `Open3.capture3('osascript', '-e', script)`
- Returns `{success: bool, output: string, error: string}`
- 30-second timeout via `Timeout.timeout`
- Strips trailing newlines from output

### `run_jxa(script)`
- Executes JXA via `Open3.capture3('osascript', '-l', 'JavaScript', '-e', script)`
- Same return format
- Better for structured data (returns JSON natively)

### Error Handling
- `Timeout::Error` → returns timeout message
- `Errno::ENOENT` → osascript not found
- `StandardError` → generic error

### Safety Layer: `confirm_action(description)`
- Prints action description to terminal
- Prompts `[y/N]`
- Returns boolean
- Called before actions tagged as destructive/external (sending emails, running arbitrary JS)

## `macos_auto` Tool

Single action-based LLM tool for macOS app automation.

### Actions

| Action | App | Description | Confirmation? |
|--------|-----|-------------|---------------|
| `open_app` | Any | Launch/activate app by name | No |
| `notify` | System | Show macOS notification (title + body) | No |
| `clipboard_read` | System | Read clipboard contents | No |
| `clipboard_write` | System | Write text to clipboard | No |
| `calendar_today` | Calendar | Get today's events (title, time, location) | No |
| `reminder_add` | Reminders | Create reminder with optional due date | No |
| `note_create` | Notes | Create note in specified folder | No |
| `mail_send` | Mail | Compose and send email | **Yes** |
| `mail_read` | Mail | Get recent unread emails (sender, subject, preview) | No |
| `finder_reveal` | Finder | Open Finder at a path | No |

### Parameters
- `action` (required, enum of above)
- `app_name` (for open_app)
- `title`, `body` (for notify, note_create, reminder_add)
- `to`, `subject` (for mail_send)
- `path` (for finder_reveal)
- `folder` (for note_create)
- `due_date` (for reminder_add)
- `limit` (for mail_read)

### Design Notes
- Read-only actions return plain text
- Write actions return confirmation strings
- All actions are atomic — no multi-step orchestration within the tool
- LLM handles chaining across multiple tool calls

## `browser` Tool

Safari automation via AppleScript's `do JavaScript` capability.

### Actions

| Action | Description | Confirmation? |
|--------|-------------|---------------|
| `open_url` | Open URL in Safari (new tab or current) | No |
| `get_url` | Get current tab's URL | No |
| `get_title` | Get current tab's title | No |
| `get_text` | Extract visible text from current page | No |
| `get_links` | Extract all links (text + href) | No |
| `run_js` | Execute arbitrary JavaScript in current tab | **Yes** |
| `click` | Click element by CSS selector (via JS) | No |
| `fill` | Fill form field by CSS selector with value | No |
| `screenshot` | Capture current tab (saves to temp, returns path) | No |
| `tabs` | List all open tabs (title + URL) | No |
| `switch_tab` | Switch to tab by index | No |

### Parameters
- `action` (required, enum of above)
- `url` (for open_url)
- `selector` (for click, fill)
- `value` (for fill)
- `js_code` (for run_js)
- `tab_index` (for switch_tab)

### Design Notes
- `get_text` runs `document.body.innerText` via AppleScript `do JavaScript`
- Output truncated to 10,000 chars to avoid context blowup
- `get_links` collects `[{text, href}]` via JS, returns formatted text
- Requires Safari "Allow JavaScript from Apple Events" (Develop menu)
- Tool checks this on first use, returns clear error + instructions if disabled
- `run_js` is the only action requiring confirmation (arbitrary JS can modify state)

## System Prompt Updates

### Tool Hierarchy Addition
```
1. META-TOOLS (prefer these):
   - macos_auto: Control macOS apps (calendar, reminders, mail, notes, clipboard, notifications)
   - browser: Interact with Safari (open URLs, read pages, fill forms, click, run JS)
   - explore / patch / verify / memory (existing)
```

### New ACTION RULES Section
- Actions requiring confirmation will prompt the user — LLM should proceed with the tool call
- Use `browser` to look things up, fill forms, extract data from pages
- Use `macos_auto` to create reminders, check calendar, send emails, create notes
- Chain actions naturally (e.g., check calendar → draft email → send)
- If action fails (app not running, permission denied), report clearly and suggest alternatives

### Spinner Labels
- `macos_auto`: `"macOS: #{action.tr('_', ' ')}"` (e.g., "macOS: calendar today")
- `browser`: `"Safari: #{action.tr('_', ' ')}"` (e.g., "Safari: get text")
