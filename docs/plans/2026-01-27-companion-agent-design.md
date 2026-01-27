# Ruboto Companion Agent Design

## Vision

Transform Ruboto from a terminal coding assistant into a true companion agent for laptop-dependent knowledge workers (Sales, Operations, general knowledge workers). The two core gaps in current AI assistants:

1. **They can't take action** - Chat only, no ability to actually do things on your behalf
2. **No memory/context** - Forget everything between sessions, don't know your work patterns

Ruboto closes both gaps by combining persistent memory with multi-surface action capabilities, growing from on-demand tool to proactive autonomous partner.

## Architecture

Four core layers, each building on the one below:

```
┌─────────────────────────────────────────────┐
│           INTERFACE LAYER                   │
│  Terminal │ Menu Bar │ Hotkey │ Notifications│
├─────────────────────────────────────────────┤
│           INTELLIGENCE LAYER                │
│  Pattern Detection │ Proactive Triggers │   │
│  Personalization │ Task Planning            │
├─────────────────────────────────────────────┤
│           ACTION LAYER                      │
│  System │ APIs │ Browser │ Files            │
├─────────────────────────────────────────────┤
│           MEMORY LAYER                      │
│  History │ Profile │ Patterns │ Knowledge   │
└─────────────────────────────────────────────┘
```

---

## Memory Layer

The foundation. Four distinct memory types, all stored in SQLite.

### 1. Episodic Memory (Task History)

```
tasks: id, timestamp, request, outcome, tools_used, duration, success
```

What you asked, what happened, what worked. Enables "last time you asked me to do X, I did Y" and learning from failures.

### 2. Semantic Memory (User Profile)

```
profile: key, value, confidence, source, updated_at
```

Structured facts: your name, role, company, team members, preferences ("I prefer bullet points", "always CC my manager on client emails"). Learned explicitly or inferred from conversations.

### 3. Procedural Memory (Workflows)

```
workflows: id, name, trigger, steps[], frequency, last_run
```

Learned sequences: "When I say 'weekly report', I mean: pull data from X, format as Y, send to Z". Can be taught explicitly or discovered from repeated patterns.

### 4. Pattern Memory (Behavioral)

```
patterns: id, type, conditions, frequency, confidence
```

Detected regularities: "User sends pipeline updates every Monday 9am", "User always checks Slack before email". Powers proactive suggestions.

Semantic search over memory using keyword matching initially, with an embedding layer added when memory grows large.

---

## Action Layer

Four executor types behind a unified interface:

```ruby
execute(action_type:, intent:, params:, confirm: false)
# Returns: { success:, result:, rollback_possible: }
```

### 1. System Executor (Desktop Automation)

- macOS: AppleScript, JXA (JavaScript for Automation), Shortcuts
- Controls native apps: Mail, Calendar, Finder, Notes, Reminders
- Can click, type, read screen content via Accessibility APIs
- Example: "Add this to my calendar" -> opens Calendar.app, creates event

### 2. API Executor (Service Integrations)

- OAuth2 flow for connecting accounts (stored securely in Keychain)
- Adapters for common services: Gmail, Slack, Notion, Salesforce, HubSpot, Airtable, Google Sheets
- Generic HTTP adapter for custom webhooks/APIs
- Example: "Update the deal in Salesforce" -> API call to Salesforce

### 3. Browser Executor (Web Automation)

- Playwright or Puppeteer under the hood
- Handles sites without APIs, form filling, data extraction
- Session management for logged-in state
- Example: "Check my Amazon order status" -> navigates, scrapes, reports

### 4. File Executor (Extended from current Ruboto)

- Read, write, edit, glob, grep (already exists)
- Extended for common document types: PDF reading, Excel/CSV manipulation

---

## Intelligence Layer

The brain connecting memory to action. Three core engines:

### 1. Pattern Detection Engine

- Runs periodically over episodic + pattern memory
- Detects recurring tasks: "User runs sales report every Monday"
- Detects sequences: "After updating CRM, user always emails manager"
- Assigns confidence scores; only acts on patterns above threshold (e.g., 80%)
- Low-confidence patterns become suggestions, high-confidence become automations

### 2. Proactive Trigger System

- **Time-based:** "It's Monday 9am, you usually prep the pipeline review"
- **Event-based:** "New email from client X - you typically respond within 30 min"
- **Context-based:** "You opened the CRM - want me to pull the latest numbers?"
- Each trigger maps to a suggested action + snooze/dismiss/automate options
- User feedback loop: dismissed suggestions reduce confidence, accepted ones increase it

### 3. Task Planner

- Breaks complex requests into multi-step plans using available executors
- Example: "Prep for my 2pm meeting with Acme Corp" becomes:
  1. Check calendar for attendees
  2. Pull Acme's recent activity from CRM
  3. Summarize last 3 email threads with them
  4. Draft talking points
  5. Send prep doc to Notes
- Handles failures gracefully: if step 3 fails, continues with what it has
- Learns which plans work and reuses them

---

## Interface Layer

Multiple surfaces so the agent is always reachable:

### 1. Terminal (Enhanced Current)

- Remains the power-user interface
- `/teach` - explicitly teach workflows ("when I say X, do Y")
- `/profile` - view/edit what the agent knows about you
- `/auto` - view and manage automated tasks
- `/connect` - connect new services (OAuth flows)

### 2. Menu Bar Agent (macOS)

- Persistent icon in menu bar showing status (idle, working, needs attention)
- Click to open quick-input popup - ask anything without opening terminal
- Notification badges for proactive suggestions
- Built with Ruby + native macOS bindings or a lightweight Tauri shell

### 3. Global Hotkey

- Configurable shortcut (e.g., `Cmd+Shift+Space`) summons a floating input bar
- Type a quick request from any app context
- Agent sees which app you're in and adapts (e.g., triggered from Mail -> email-related actions)

### 4. System Notifications

- Proactive nudges delivered as native macOS notifications
- Actionable: "Weekly report due - [Generate] [Snooze] [Dismiss]"
- Grouped by urgency: blocking (needs input), informational (FYI), completions (done in background)
- Respects Do Not Disturb / Focus modes

---

## Feature Catalog by Persona

### Sales Professional

- Draft personalized outreach emails from CRM data + LinkedIn context
- Auto-log meeting notes to CRM after calls
- "Prep me for my next meeting" -> pulls contact history, deal stage, recent emails
- Pipeline reminders: "3 deals haven't been updated in 7 days"
- Generate follow-up emails after meetings using notes

### Operations Manager

- "Weekly status report" -> pulls data from multiple sources, formats, distributes
- Process documentation: watch how you do a task, write the SOP
- Vendor follow-ups: track pending responses, nudge when overdue
- Data entry automation: extract from emails/PDFs, push to spreadsheets
- Recurring checklist execution with variance flagging

### General Knowledge Worker

- Smart email triage: summarize inbox, draft replies, flag urgent
- Meeting prep across all calendar events
- "Summarize what happened while I was away" -> scans email, Slack, docs
- Expense report assembly from receipts
- Cross-app search: "Find that document about Q3 targets" -> searches Mail, Docs, Slack, files

### Universal (All Personas)

- Morning briefing: today's calendar, pending tasks, unread priorities
- End-of-day summary: what was accomplished, what's pending
- Quick capture: "Remind me to follow up with Sarah on Thursday"
- Template system: learn your formatting preferences and reuse them

---

## Implementation Roadmap

### Phase 1: Memory Foundation

- Upgrade SQLite schema from single `messages` table to full memory model (episodic, semantic, procedural, pattern)
- `/teach` command to explicitly store workflows and preferences
- `/profile` command to view/edit agent's knowledge of you
- Semantic search over memory using keyword matching (embeddings later)
- Agent automatically extracts and stores facts from conversations

### Phase 2: Action Framework

- Plugin architecture for executors with unified `execute()` interface
- System executor: AppleScript/JXA bridge for macOS native apps
- API executor: OAuth2 flow + adapters for Gmail, Slack, Google Calendar
- File executor enhancements: PDF reading, CSV/Excel manipulation
- `/connect` command for linking services
- Confirmation prompts for destructive or external actions

### Phase 3: Intelligence + Proactivity

- Pattern detection engine running over memory on each session start
- Proactive trigger system: time-based and context-based suggestions
- Task planner: decompose complex requests into multi-step plans
- Confidence scoring and user feedback loop (accept/dismiss/automate)
- Background task runner for automated workflows

### Phase 4: Interface Expansion

- Menu bar agent with quick-input popup
- Global hotkey with app-context awareness
- Native macOS notifications for proactive nudges
- Morning briefing and end-of-day summary as scheduled routines
- `/auto` command to manage all automated behaviors
