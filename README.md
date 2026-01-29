# Ruboto

A minimal agentic assistant for the terminal. Built in Ruby, powered by multiple LLM providers via OpenRouter. Controls macOS apps, browses the web, manages files, runs shell commands — and automates repetitive workflows from plain English descriptions.

## Features

- **Multi-model support**: Claude, Gemini, DeepSeek, Grok, and more via OpenRouter
- **Agentic tools**: Read, write, edit files, run shell commands, search codebases
- **Workflow automation**: Describe tasks in plain English, watch them execute, let them graduate to autonomous
- **Meta-tools**: Exploration, verification, patching, planning
- **macOS automation**: Calendar, reminders, mail, notes, clipboard, notifications
- **Browser control**: Open URLs, read pages, fill forms, click buttons (Safari)
- **Persistent memory**: Remembers your name, preferences, and workflows across sessions
- **Intelligence layer**: Pattern detection, briefings, and smart suggestions
- **Background daemon**: Monitors email, watches files, runs scheduled workflows automatically
- **Scheduled briefings**: Morning/evening briefings via launchd
- **Safety by default**: AI never takes destructive actions unless you explicitly ask
- **Zero dependencies**: Pure Ruby stdlib, no external gems required

## Installation

### From RubyGems

```bash
gem install ruboto-ai
```

### From Source

```bash
git clone https://github.com/akhil-gautam/ruboto-ai.git
cd ruboto-ai
gem build ruboto.gemspec
gem install ruboto-ai-*.gem
```

### Configuration

Set your OpenRouter API key:

```bash
export OPENROUTER_API_KEY="your-api-key-here"
```

Add this to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.) to persist it.

## Quick Start

### Interactive Mode (default)

```bash
ruboto-ai
```

Select a model by number, then start chatting. Ruboto acts autonomously — it reads files, runs commands, and fixes issues without asking for permission on every step.

### Quick Mode (single request)

```bash
# One-shot request — runs, prints result, exits
ruboto-ai --quick "list all TODO comments in this project"

# With app context (e.g., read from a macOS app)
ruboto-ai --quick "summarize my unread emails" --context "app:Mail"
```

## Workflow Automation

Ruboto includes a powerful workflow automation engine. Describe what you want automated in plain English, and Ruboto will:

1. **Parse your intent** — Extract triggers, data sources, and destinations
2. **Generate a plan** — Create executable steps using available tools
3. **Execute with supervision** — Ask for approval on each step initially
4. **Learn from corrections** — Adjust confidence based on your feedback
5. **Graduate to autonomous** — Run automatically once confident

### Creating Workflows

```bash
# In the REPL, describe what you want automated:
/workflow "Every Friday at 5pm, pull invoices from ~/Downloads, extract vendor and amount, add to expenses.csv"

# Ruboto will parse this and show:
# → Trigger: Weekly (Friday at 17:00)
# → Steps:
#   1. Scan ~/Downloads for *.pdf files
#   2. Extract vendor + amount from each PDF
#   3. Append to ~/expenses.csv
#
# Save this workflow? [y/n]
```

### Workflow Triggers

Workflows can be triggered by:

| Trigger | Example |
|---------|---------|
| **Schedule** | "Every Friday at 5pm", "Every morning", "Every day at 9am" |
| **File watch** | "When a new file appears in ~/Invoices" |
| **Email** | "When I receive an email from billing@vendor.com" |
| **Manual** | Run with `/run workflow-name` |

### Managing Workflows

```bash
# List all workflows
/workflows

# Run a workflow manually
/run expense-processing

# View/adjust confidence levels
/trust expense-processing
/trust expense-processing 2 90    # Set step 2 to 90% confidence

# Manage schedules
/schedule list                    # Show scheduled workflows
/schedule status                  # Check what's due to run
/schedule enable expense-processing
/schedule disable expense-processing

# View run history
/history expense-processing       # History for specific workflow
/history                          # All recent runs

# View detailed audit logs
/audit expense-processing         # Summary of all runs
/audit expense-processing 5       # Details for run #5

# Export/import workflows
/export expense-processing        # Export to JSON file
/import workflow-backup.json      # Import from file
```

### Confidence & Learning

Each workflow step has a confidence score (0-100%):

- **< 80%**: Requires your approval before executing
- **≥ 80%**: Runs autonomously without asking

Confidence changes based on your actions:
- **Approve without changes**: +20%
- **Make a correction**: -30%
- **Skip step**: -50%

After 5+ successful runs with no corrections, steps graduate to autonomous execution.

### Example Workflows

**Expense Processing**
```
/workflow "Every Friday at 5pm, pull PDF invoices from Downloads folder,
           extract vendor name and amount, add them to my expenses.csv"
```

**Backup Important Files**
```
/workflow "Every day at midnight, copy new files from ~/Documents to ~/Backup"
```

**Email Attachment Handler**
```
/workflow "When I receive an email from invoices@company.com,
           save the PDF attachment to ~/Invoices"
```

**Report Generation**
```
/workflow "Every Monday morning, read sales.csv, calculate weekly totals,
           email summary to team@company.com"
```

## Background Daemon

```bash
# Install the daemon (runs via launchd, persists across reboots)
ruboto-ai --install-daemon

# Check what the daemon has queued
ruboto-ai --queue

# Cancel a queued action before it executes
ruboto-ai --cancel-action 3

# Uninstall the daemon
ruboto-ai --uninstall-daemon
```

The daemon runs in the background and:
- Polls Mail.app every minute for new emails
- Checks scheduled workflows and runs them when due
- Watches configured directories for new files
- Classifies emails and queues actions (flight check-ins, package tracking, etc.)
- Sends macOS notifications on workflow completion

### Scheduled Briefings

```bash
# Run a briefing manually
ruboto-ai --briefing morning
ruboto-ai --briefing evening
ruboto-ai --briefing auto       # picks based on current time

# Install scheduled briefings (8 AM and 5 PM daily via launchd)
ruboto-ai --install-schedule

# Remove scheduled briefings
ruboto-ai --uninstall-schedule
```

### Task History

```bash
# Show last 10 tasks
ruboto-ai --tasks

# Show last 20 tasks
ruboto-ai --tasks 20
```

## CLI Reference

| Flag | Description |
|------|-------------|
| *(no args)* | Interactive REPL |
| `--quick "request"` | Single-shot mode |
| `--context "app:Name"` | App context for quick mode |
| `--briefing morning\|evening\|auto` | Run a briefing |
| `--tasks [N]` | Show recent N tasks (default 10) |
| `--workflow "description"` | Create a new workflow |
| `--workflows` | List all workflows |
| `--run-workflow name` | Run a workflow |
| `--install-schedule` | Install launchd plist for scheduled briefings |
| `--uninstall-schedule` | Remove briefing schedule |
| `--daemon` | Start background daemon (foreground, for launchd) |
| `--install-daemon` | Install launchd plist for background daemon |
| `--uninstall-daemon` | Remove daemon plist |
| `--queue` | Show pending action queue |
| `--cancel-action ID` | Cancel a pending/notified action |
| `--help` | Show help |

## REPL Commands

| Command | Description |
|---------|-------------|
| `/h` | Show help |
| `/c` | Clear conversation context |
| `/q` | Quit |
| `/history` | Show recent commands |
| `/briefing [morning\|evening\|auto]` | Run a briefing inside the REPL |
| `/queue` | Show pending daemon actions |
| `/cancel <id>` | Cancel a daemon action |
| **Workflow Commands** | |
| `/workflow "description"` | Create a new workflow |
| `/workflows` | List all workflows |
| `/run <name>` | Run a workflow |
| `/trust <name> [step] [0-100]` | View/adjust confidence |
| `/schedule list\|status\|enable\|disable` | Manage schedules |
| `/history [name] [limit]` | View run history |
| `/audit <name> [run-id]` | View audit logs |
| `/export <name> [file]` | Export workflow to JSON |
| `/import <file>` | Import workflow from JSON |
| `Ctrl+C` | Exit |

## Example Interactions

**Check your calendar and draft a reply:**
```
> check my calendar for tomorrow and draft an email to the team about the standup time

⏺ macOS Automation: calendar → list_events
  ⎿ Tomorrow: 10:00 AM - Daily Standup, 2:00 PM - Design Review

⏺ macOS Automation: mail → draft
  ⎿ Draft created in Mail.app

Found 2 events tomorrow. Drafted an email to the team confirming the 10:00 AM standup.
```

**Create and run a workflow:**
```
> /workflow "Pull PDFs from Downloads, extract vendor and amount, add to expenses.csv"

Parsing workflow...

Workflow: pull-pdfs-extract-vendor
"Pull PDFs from Downloads, extract vendor and amount, add to expenses.csv"

Trigger: manual
Generated 3 steps:
  1. Scan ~/Downloads for *.pdf files
     Tool: file_glob, Output: $collected_files
  2. Extract vendor, amount from files
     Tool: pdf_extract, Output: $extracted_data
  3. Append data to ~/expenses.csv
     Tool: file_append, Output: none

Save this workflow? [y/n] y
✓ Saved workflow 'pull-pdfs-extract-vendor' (id: 1)
Run with: /run pull-pdfs-extract-vendor

> /run pull-pdfs-extract-vendor

Running workflow: pull-pdfs-extract-vendor

Step 1/3: Scan ~/Downloads for *.pdf files
  Tool: file_glob
  Confidence: 0% (supervised)
  Params: {path: "~/Downloads", pattern: "*.pdf"}

  [a]pprove  [s]kip  [e]dit  [c]ancel > a
  ✓ Found 3 files

Step 2/3: Extract vendor, amount from files
  ...
```

**Explore a codebase:**
```
> where is the authentication logic?

⏺ Exploring: where is the authentication logic?
  ⎿ Found in 2 files

Authentication is handled in:
- src/auth/login.js — main login logic with JWT token generation
- src/middleware/auth.js — route protection middleware
```

**Daemon in action (automatic):**
```
# Daemon detects a scheduled workflow is due
🔔 Notification: "Running: expense-processing"

# Workflow completes
✅ Notification: "Workflow completed: expense-processing"
```

## Available Tools

### Meta-Tools (high-level, preferred)

| Tool | Description |
|------|-------------|
| `macos_auto` | Control macOS apps — calendar, reminders, mail, notes, clipboard, notifications |
| `browser` | Interact with Safari — open URLs, read pages, fill forms, click, run JS |
| `explore` | Answer "where is X?" / "how does Y work?" questions automatically |
| `patch` | Apply unified diffs for multi-line edits |
| `verify` | Run commands and check success/failure with optional retries |
| `memory` | Read/write persistent user memory (profile, preferences, workflows) |
| `plan` | Break complex requests into step-by-step plans |

### Workflow Tools

| Tool | Description |
|------|-------------|
| `file_glob` | Find files by path and pattern |
| `pdf_extract` | Extract text and fields from PDFs |
| `csv_read` | Read CSV files |
| `csv_append` | Append rows to CSV files |
| `data_filter` | Filter data by conditions |
| `email_search` | Search emails by criteria |
| `email_send` | Send emails |

### Primitive Tools

| Tool | Description |
|------|-------------|
| `read` | Read file contents with line numbers |
| `write` | Create or overwrite a file |
| `edit` | Modify a file (find & replace) |
| `glob` | Find files by pattern (`*.js`, `**/*.test.rb`) |
| `grep` | Search file contents with regex |
| `find` | Locate files by name substring |
| `tree` | Show directory structure |
| `bash` | Run shell commands (git, npm, python, etc.) |

## Supported Models

| Model | Provider | Notes |
|-------|----------|-------|
| Claude Sonnet 4.5 | Anthropic | Best overall |
| Gemini 3 Flash | Google | Fast responses |
| DeepSeek v3.2 | DeepSeek | Strong reasoning |
| Grok Code Fast | xAI | Code generation |
| MiniMax M2.1 | MiniMax | Versatile |
| Seed 1.6 | ByteDance | General purpose |
| GLM 4.7 | Zhipu AI | Chinese + English |
| MiMo v2 Flash | Xiaomi | Free tier |
| LFM 2.5 Thinking | Liquid | Free tier |

You can also enter **any** [OpenRouter model ID](https://openrouter.ai/models) directly:

```
Choice: openai/gpt-4o
Choice: meta-llama/llama-3.3-70b-instruct
```

## Data Storage

All data lives in `~/.ruboto/`:

| File/Directory | Purpose |
|----------------|---------|
| `history.db` | Conversations, tasks, memory, workflows, action queue (SQLite) |
| `daemon.log` | Structured JSON log from the background daemon |
| `logs/workflows/` | Detailed audit logs for each workflow run |

### Database Tables

| Table | Purpose |
|-------|---------|
| `user_workflows` | Workflow definitions with triggers and confidence |
| `workflow_steps` | Individual steps for each workflow |
| `workflow_runs` | Execution history with state and logs |
| `step_corrections` | User corrections for learning |
| `trigger_history` | When and why workflows were triggered |
| `action_queue` | Pending daemon actions |
| `patterns` | Detected usage patterns |

## Requirements

- Ruby 3.0+
- macOS (for Mail.app integration, launchd, notifications)
- SQLite3 (pre-installed on macOS)
- OpenRouter API key ([get one here](https://openrouter.ai/keys))

## Development

```bash
git clone https://github.com/akhil-gautam/ruboto-ai.git
cd ruboto-ai

# Run directly without installing
ruby -Ilib bin/ruboto-ai

# Quick mode during development
ruby -Ilib bin/ruboto-ai --quick "hello"

# Run tests
ruby -Ilib -Itest test/workflow/integration_test.rb
ruby -Ilib -Itest test/workflow/confidence_tracker_test.rb
ruby -Ilib -Itest test/workflow/trigger_manager_test.rb
ruby -Ilib -Itest test/workflow/history_test.rb

# Build and install the gem
gem build ruboto.gemspec
gem install ruboto-ai-*.gem
```

## Architecture

```
lib/ruboto/
├── workflow/
│   ├── intent_parser.rb      # Natural language → structured workflow
│   ├── plan_generator.rb     # Workflow → executable steps
│   ├── runtime.rb            # Step execution with state
│   ├── storage.rb            # Workflow persistence
│   ├── confidence_tracker.rb # Learning from corrections
│   ├── trigger_manager.rb    # Schedule/file/email triggers
│   ├── history.rb            # Run history and statistics
│   ├── export_import.rb      # Workflow backup/restore
│   ├── error_recovery.rb     # Retry logic and error handling
│   ├── audit_logger.rb       # Detailed execution logs
│   └── extractors/
│       ├── pdf.rb            # PDF text extraction
│       └── csv.rb            # CSV operations
├── intelligence/
│   ├── pattern_detector.rb   # Usage pattern detection
│   ├── proactive_triggers.rb # Smart suggestions
│   ├── intent_extractor.rb   # Email intent classification
│   └── action_executor.rb    # Autonomous action execution
├── tools/
│   ├── macos_auto.rb         # macOS app automation
│   └── browser.rb            # Safari automation
├── daemon.rb                 # Background processing
└── scheduler.rb              # launchd integration
```

## License

MIT — See [LICENSE.txt](LICENSE.txt)
