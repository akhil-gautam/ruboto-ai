# Memory Foundation (Phase 1) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade Ruboto's single-table SQLite schema into a full memory system with episodic, semantic, procedural, and pattern memory — plus `/teach`, `/profile`, and memory-aware system prompt.

**Architecture:** Four new SQLite tables alongside the existing `messages` table. New module methods for each memory type. New slash commands integrated into the existing REPL loop. The LLM gets a `memory_context` tool to query and store memories. All SQL via the existing `run_sql` helper.

**Tech Stack:** Ruby stdlib, SQLite3 (via CLI), existing Ruboto module pattern

---

## Task 1: Expand the SQLite Schema

**Files:**
- Modify: `lib/ruboto.rb:747-762` (`ensure_db_exists` method)

**Step 1: Replace the `ensure_db_exists` method**

Replace the entire `ensure_db_exists` method with:

```ruby
def ensure_db_exists
  Dir.mkdir(RUBOTO_DIR) unless Dir.exist?(RUBOTO_DIR)

  schema = <<~SQL
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      session_id TEXT,
      working_dir TEXT,
      created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request TEXT NOT NULL,
      outcome TEXT,
      tools_used TEXT,
      success INTEGER,
      session_id TEXT,
      working_dir TEXT,
      created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS profile (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      key TEXT NOT NULL,
      value TEXT NOT NULL,
      confidence REAL DEFAULT 1.0,
      source TEXT DEFAULT 'explicit',
      updated_at TEXT DEFAULT (datetime('now')),
      UNIQUE(key)
    );

    CREATE TABLE IF NOT EXISTS workflows (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      trigger TEXT NOT NULL,
      steps TEXT NOT NULL,
      frequency INTEGER DEFAULT 0,
      last_run TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      UNIQUE(name)
    );

    CREATE TABLE IF NOT EXISTS patterns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pattern_type TEXT NOT NULL,
      description TEXT NOT NULL,
      conditions TEXT,
      frequency INTEGER DEFAULT 1,
      confidence REAL DEFAULT 0.5,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    );
  SQL

  run_sql(schema)
end
```

**Step 2: Verify schema creation works**

Run: `ruby -Ilib -e "require 'ruboto'; Ruboto.ensure_db_exists; puts 'ok'"`

Expected: `ok` (no errors)

**Step 3: Verify tables exist**

Run: `sqlite3 ~/.ruboto/history.db ".tables"`

Expected: `messages  patterns  profile  tasks  workflows`

**Step 4: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: expand SQLite schema with tasks, profile, workflows, patterns tables"
```

---

## Task 2: Add Memory Helper Methods

**Files:**
- Modify: `lib/ruboto.rb` (add after `load_readline_history` method, around line 788)

**Step 1: Add task memory methods**

Add after `load_readline_history`:

```ruby
# --- Memory helpers ---

def save_task(request, outcome, tools_used, success, session_id = nil)
  escaped_request = request.gsub("'", "''")
  escaped_outcome = (outcome || "").gsub("'", "''")
  escaped_tools = (tools_used || "").gsub("'", "''")
  success_int = success ? 1 : 0
  session_part = session_id ? "'#{session_id}'" : "NULL"
  escaped_dir = Dir.pwd.gsub("'", "''")

  sql = "INSERT INTO tasks (request, outcome, tools_used, success, session_id, working_dir) " \
        "VALUES ('#{escaped_request}', '#{escaped_outcome}', '#{escaped_tools}', #{success_int}, #{session_part}, '#{escaped_dir}');"
  run_sql(sql)
end

def recent_tasks(limit = 10)
  sql = "SELECT request, outcome, success, created_at FROM tasks ORDER BY id DESC LIMIT #{limit};"
  run_sql(sql)
end
```

**Step 2: Add profile memory methods**

Add after the task methods:

```ruby
def set_profile(key, value, confidence = 1.0, source = "explicit")
  escaped_key = key.gsub("'", "''")
  escaped_value = value.gsub("'", "''")
  escaped_source = source.gsub("'", "''")

  sql = "INSERT INTO profile (key, value, confidence, source, updated_at) " \
        "VALUES ('#{escaped_key}', '#{escaped_value}', #{confidence}, '#{escaped_source}', datetime('now')) " \
        "ON CONFLICT(key) DO UPDATE SET value='#{escaped_value}', confidence=#{confidence}, source='#{escaped_source}', updated_at=datetime('now');"
  run_sql(sql)
end

def get_profile(key = nil)
  if key
    escaped_key = key.gsub("'", "''")
    sql = "SELECT key, value, confidence, source FROM profile WHERE key='#{escaped_key}';"
  else
    sql = "SELECT key, value, confidence, source FROM profile ORDER BY key;"
  end
  run_sql(sql)
end

def delete_profile(key)
  escaped_key = key.gsub("'", "''")
  sql = "DELETE FROM profile WHERE key='#{escaped_key}';"
  run_sql(sql)
end
```

**Step 3: Add workflow memory methods**

Add after profile methods:

```ruby
def save_workflow(name, trigger, steps)
  escaped_name = name.gsub("'", "''")
  escaped_trigger = trigger.gsub("'", "''")
  escaped_steps = steps.is_a?(Array) ? steps.to_json.gsub("'", "''") : steps.gsub("'", "''")

  sql = "INSERT INTO workflows (name, trigger, steps) " \
        "VALUES ('#{escaped_name}', '#{escaped_trigger}', '#{escaped_steps}') " \
        "ON CONFLICT(name) DO UPDATE SET trigger='#{escaped_trigger}', steps='#{escaped_steps}';"
  run_sql(sql)
end

def get_workflows
  sql = "SELECT name, trigger, steps, frequency, last_run FROM workflows ORDER BY frequency DESC;"
  run_sql(sql)
end

def find_workflow(trigger_text)
  escaped = trigger_text.downcase.gsub("'", "''")
  sql = "SELECT name, trigger, steps FROM workflows WHERE lower(trigger) LIKE '%#{escaped}%' LIMIT 5;"
  run_sql(sql)
end

def increment_workflow(name)
  escaped_name = name.gsub("'", "''")
  sql = "UPDATE workflows SET frequency = frequency + 1, last_run = datetime('now') WHERE name='#{escaped_name}';"
  run_sql(sql)
end
```

**Step 4: Add pattern memory methods**

Add after workflow methods:

```ruby
def save_pattern(pattern_type, description, conditions = nil)
  escaped_type = pattern_type.gsub("'", "''")
  escaped_desc = description.gsub("'", "''")
  conditions_part = conditions ? "'#{conditions.gsub("'", "''")}'" : "NULL"

  sql = "INSERT INTO patterns (pattern_type, description, conditions) " \
        "VALUES ('#{escaped_type}', '#{escaped_desc}', #{conditions_part});"
  run_sql(sql)
end

def get_patterns(min_confidence = 0.5)
  sql = "SELECT pattern_type, description, conditions, frequency, confidence FROM patterns " \
        "WHERE confidence >= #{min_confidence} ORDER BY confidence DESC;"
  run_sql(sql)
end

def reinforce_pattern(id)
  sql = "UPDATE patterns SET frequency = frequency + 1, " \
        "confidence = MIN(1.0, confidence + 0.1), updated_at = datetime('now') WHERE id=#{id};"
  run_sql(sql)
end

def weaken_pattern(id)
  sql = "UPDATE patterns SET confidence = MAX(0.0, confidence - 0.1), updated_at = datetime('now') WHERE id=#{id};"
  run_sql(sql)
end
```

**Step 5: Verify methods load without error**

Run: `ruby -Ilib -e "require 'ruboto'; Ruboto.ensure_db_exists; Ruboto.set_profile('test', 'value'); puts Ruboto.get_profile('test')"`

Expected: `test|value|1.0|explicit`

**Step 6: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add memory helper methods for tasks, profile, workflows, patterns"
```

---

## Task 3: Add `/profile` Command

**Files:**
- Modify: `lib/ruboto.rb:960-984` (command handling in the REPL loop)

**Step 1: Add /profile command handler**

Find this block in the `run` method (around line 968):

```ruby
if user_input == "/h" || user_input == "/help"
  print_help
  next
end
```

Add after it:

```ruby
if user_input.start_with?("/profile")
  parts = user_input.split(" ", 3)
  subcommand = parts[1]

  case subcommand
  when "set"
    # /profile set key value
    key_value = user_input.sub("/profile set ", "").split(" ", 2)
    if key_value.length == 2
      set_profile(key_value[0], key_value[1])
      puts "#{GREEN}✓#{RESET} Set #{BOLD}#{key_value[0]}#{RESET} = #{key_value[1]}"
    else
      puts "#{RED}Usage: /profile set <key> <value>#{RESET}"
    end
  when "del", "delete"
    key = parts[2]
    if key
      delete_profile(key)
      puts "#{GREEN}✓#{RESET} Deleted #{BOLD}#{key}#{RESET}"
    else
      puts "#{RED}Usage: /profile del <key>#{RESET}"
    end
  else
    # /profile (list all)
    data = get_profile
    if data.empty?
      puts "#{DIM}No profile data yet. Use /profile set <key> <value> to add.#{RESET}"
    else
      puts "#{CYAN}Your Profile:#{RESET}"
      data.split("\n").each do |row|
        cols = row.split("|")
        next if cols.length < 2
        puts "  #{BOLD}#{cols[0]}#{RESET} = #{cols[1]} #{DIM}(#{cols[3] || 'explicit'}, confidence: #{cols[2] || '1.0'})#{RESET}"
      end
    end
  end
  next
end
```

**Step 2: Update `print_help` to include /profile**

Find the `print_help` method and add the new command to the list. Replace:

```ruby
      #{BOLD}/history#{RESET}  #{DIM}show recent commands#{RESET}
```

With:

```ruby
      #{BOLD}/history#{RESET}  #{DIM}show recent commands#{RESET}
      #{BOLD}/profile#{RESET}  #{DIM}view/set profile (set <key> <val>, del <key>)#{RESET}
```

**Step 3: Test the /profile command**

Run: `ruby -Ilib bin/ruboto-ai`

Test sequence:
```
/profile
/profile set name Akhil
/profile set role Sales Lead
/profile
/profile del role
/profile
```

Expected:
- First `/profile`: "No profile data yet."
- After sets: Shows name and role
- After del: Shows only name

**Step 4: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add /profile command for viewing and editing user profile"
```

---

## Task 4: Add `/teach` Command

**Files:**
- Modify: `lib/ruboto.rb` (command handling section, after /profile handler)

**Step 1: Add /teach command handler**

Add after the `/profile` handler (before the `/history` handler):

```ruby
if user_input.start_with?("/teach")
  rest = user_input.sub("/teach", "").strip

  if rest.empty?
    # List existing workflows
    data = get_workflows
    if data.empty?
      puts "#{DIM}No workflows yet. Teach me with: /teach <name> when <trigger> do <step1>, <step2>, ...#{RESET}"
    else
      puts "#{CYAN}Learned Workflows:#{RESET}"
      data.split("\n").each do |row|
        cols = row.split("|")
        next if cols.length < 3
        puts "  #{BOLD}#{cols[0]}#{RESET}"
        puts "    #{DIM}Trigger:#{RESET} #{cols[1]}"
        puts "    #{DIM}Steps:#{RESET} #{cols[2]}"
        puts "    #{DIM}Used #{cols[3] || 0} times#{RESET}"
      end
    end
  elsif rest.include?(" when ") && rest.include?(" do ")
    # /teach <name> when <trigger> do <steps>
    match = rest.match(/\A(.+?)\s+when\s+(.+?)\s+do\s+(.+)\z/)
    if match
      name = match[1].strip
      trigger = match[2].strip
      steps = match[3].strip
      save_workflow(name, trigger, steps)
      puts "#{GREEN}✓#{RESET} Learned workflow #{BOLD}#{name}#{RESET}"
      puts "  #{DIM}When:#{RESET} #{trigger}"
      puts "  #{DIM}Do:#{RESET} #{steps}"
    else
      puts "#{RED}Usage: /teach <name> when <trigger> do <step1>, <step2>, ...#{RESET}"
    end
  else
    puts "#{RED}Usage: /teach <name> when <trigger> do <step1>, <step2>, ...#{RESET}"
    puts "#{DIM}Example: /teach weekly-report when \"weekly report\" do pull CRM data, format summary, email to team#{RESET}"
  end
  next
end
```

**Step 2: Update `print_help` to include /teach**

Add after the /profile help line:

```ruby
      #{BOLD}/teach#{RESET}    #{DIM}teach workflows (/teach name when <trigger> do <steps>)#{RESET}
```

**Step 3: Test the /teach command**

Run: `ruby -Ilib bin/ruboto-ai`

Test sequence:
```
/teach
/teach weekly-report when "weekly report" do pull CRM data, format summary, email to team
/teach
```

Expected:
- First `/teach`: "No workflows yet."
- After teaching: Shows confirmation
- Second `/teach`: Lists the workflow

**Step 4: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add /teach command for teaching workflows"
```

---

## Task 5: Add `memory` Tool for LLM Access

**Files:**
- Modify: `lib/ruboto.rb` (tool implementations and TOOLS hash)

**Step 1: Add the memory tool implementation**

Add after `tool_patch` (around line 459):

```ruby
def tool_memory(args)
  action = args["action"]
  case action
  when "get_profile"
    result = get_profile
    result.empty? ? "No profile data stored." : "User profile:\n#{result}"

  when "set_profile"
    key = args["key"]
    value = args["value"]
    confidence = args["confidence"] || 0.8
    return "error: key and value required" unless key && value
    set_profile(key, value, confidence, "inferred")
    "Stored: #{key} = #{value}"

  when "get_workflows"
    result = get_workflows
    result.empty? ? "No workflows stored." : "Known workflows:\n#{result}"

  when "find_workflow"
    query = args["query"]
    return "error: query required" unless query
    result = find_workflow(query)
    result.empty? ? "No matching workflows." : "Matching workflows:\n#{result}"

  when "get_tasks"
    result = recent_tasks(args["limit"] || 10)
    result.empty? ? "No task history." : "Recent tasks:\n#{result}"

  when "save_fact"
    key = args["key"]
    value = args["value"]
    return "error: key and value required" unless key && value
    set_profile(key, value, args["confidence"] || 0.7, "inferred")
    "Learned: #{key} = #{value}"

  else
    "error: unknown action '#{action}'. Use: get_profile, set_profile, get_workflows, find_workflow, get_tasks, save_fact"
  end
rescue => e
  "error: #{e.message}"
end
```

**Step 2: Add memory to the tools hash**

Add after the `patch` tool entry in the `tools` method:

```ruby
"memory" => {
  impl: method(:tool_memory),
  schema: {
    type: "function",
    name: "memory",
    description: "Access the user's persistent memory. Use to recall profile info, find learned workflows, check task history, or save new facts about the user.",
    parameters: {
      type: "object",
      properties: {
        action: {
          type: "string",
          description: "Action: get_profile, set_profile, get_workflows, find_workflow, get_tasks, save_fact",
          enum: ["get_profile", "set_profile", "get_workflows", "find_workflow", "get_tasks", "save_fact"]
        },
        key: { type: "string", description: "Profile key (for set_profile, save_fact)" },
        value: { type: "string", description: "Profile value (for set_profile, save_fact)" },
        confidence: { type: "number", description: "Confidence 0.0-1.0 (for save_fact, default 0.7)" },
        query: { type: "string", description: "Search query (for find_workflow)" },
        limit: { type: "integer", description: "Max results (for get_tasks, default 10)" }
      },
      required: ["action"]
    }
  }
},
```

**Step 3: Add tool_message case for memory**

Add in `tool_message`:

```ruby
when "memory"
  action = args["action"] || "access"
  "Memory: #{action.tr('_', ' ')}"
```

**Step 4: Verify the tool loads**

Run: `ruby -Ilib -e "require 'ruboto'; puts Ruboto.tool_schemas.length"`

Expected: `12` (11 existing + 1 new memory tool)

**Step 5: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add memory tool for LLM access to persistent memory"
```

---

## Task 6: Track Task Outcomes in the Agentic Loop

**Files:**
- Modify: `lib/ruboto.rb:990-1053` (the agentic loop in `run`)

**Step 1: Add task tracking variables**

Find this line in the `run` method (around line 990):

```ruby
messages << { role: "user", content: user_input }
```

Add after it:

```ruby
# Track tools used in this interaction
interaction_tools = []
```

**Step 2: Record tool usage**

Find this line inside the tool execution block (around line 1030):

```ruby
label = tool_message(tool_name, tool_args)
```

Add after it:

```ruby
interaction_tools << tool_name
```

**Step 3: Save task after interaction completes**

Find the line where the agentic loop ends. Look for:

```ruby
          end

          puts
```

This is where the inner agentic loop finishes and we print a blank line before the next user prompt. Add before `puts`:

```ruby
          # Save task to episodic memory
          unless interaction_tools.empty?
            last_text = messages.reverse.find { |m| m["content"] || m[:content] }&.then { |m| m["content"] || m[:content] }
            save_task(
              user_input,
              (last_text || "")[0, 200],
              interaction_tools.uniq.join(", "),
              true,
              session_id
            )
          end
```

**Step 4: Test task tracking**

Run: `ruby -Ilib bin/ruboto-ai`

Ask something that uses tools:
```
> List the files in this directory
```

Then check the database:
```bash
sqlite3 ~/.ruboto/history.db "SELECT * FROM tasks ORDER BY id DESC LIMIT 1;"
```

Expected: A row with the request, outcome, tools used.

**Step 5: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: track task outcomes in episodic memory"
```

---

## Task 7: Auto-Extract Facts from Conversations

**Files:**
- Modify: `lib/ruboto.rb:910-945` (system prompt)

**Step 1: Update the system prompt to include memory instructions**

Find the system prompt block and replace the entire `system_prompt = <<~PROMPT ... PROMPT` with:

```ruby
      # Build memory context
      profile_data = get_profile
      workflow_data = get_workflows
      recent = recent_tasks(5)

      memory_summary = ""
      memory_summary += "USER PROFILE:\n#{profile_data}\n\n" unless profile_data.empty?
      memory_summary += "KNOWN WORKFLOWS:\n#{workflow_data}\n\n" unless workflow_data.empty?
      memory_summary += "RECENT TASKS:\n#{recent}\n\n" unless recent.empty?

      system_prompt = <<~PROMPT
        You are a fast, autonomous coding assistant. Working directory: #{Dir.pwd}

        #{memory_summary.empty? ? "" : "MEMORY (what you know about this user):\n#{memory_summary}"}

        TOOL HIERARCHY - Use highest-level tool that fits:

        1. META-TOOLS (prefer these):
           - explore: Answer "where is X?" / "how does Y work?" questions
           - patch: Multi-line edits using unified diff format
           - verify: Check if command succeeds (use after code changes)
           - memory: Read/write persistent user memory (profile, workflows, task history)

        2. PRIMITIVES (when meta-tools don't fit):
           - read/write/edit: Single, targeted file operations
           - grep/glob/find: When you know exactly what to search for
           - tree: See directory structure
           - bash: Run shell commands (only real commands, not prose)

        AUTONOMY RULES:
        - ACT FIRST. Never ask "should I...?" or "would you like me to...?" - just do it
        - After ANY code change → immediately use verify to check it works
        - If verify fails → read the error, fix it, verify again
        - Keep using tools until you have a complete answer
        - Only ask questions when genuinely choosing between approaches

        MEMORY RULES:
        - When the user tells you personal info (name, role, preferences), save it with the memory tool
        - When the user describes a repeated workflow, suggest saving it
        - Check memory at start of complex tasks for relevant context
        - Use task history to avoid repeating past failures

        CRITICAL - BASH TOOL RULES:
        - ONLY use bash for executable commands: git, npm, python, node, ls, etc.
        - NEVER put prose, explanations, or markdown in bash
        - To communicate with user, just respond with text - no tool needed
        - NEVER put backticks in bash commands

        EFFICIENCY:
        - Use explore instead of multiple grep/read cycles
        - Use patch for multi-line changes (more reliable than edit)
        - Don't re-read files you just read

        Be concise. Act, don't narrate.
      PROMPT
```

**Step 2: Test memory-aware prompt**

Run: `ruby -Ilib bin/ruboto-ai`

First set some profile data:
```
/profile set name Akhil
/profile set role Founder
```

Then restart the app and ask:
```
> What do you know about me?
```

Expected: Agent should use the memory tool and reference your name and role.

**Step 3: Test fact extraction**

```
> I prefer concise answers and I work on Ruby projects mostly
```

Expected: Agent should use the memory tool to save preferences (e.g., `preferred_style = concise`, `primary_language = ruby`).

**Step 4: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: memory-aware system prompt with auto fact extraction"
```

---

## Task 8: Add `/tasks` Command to View History

**Files:**
- Modify: `lib/ruboto.rb` (command handling section)

**Step 1: Add /tasks command handler**

Add after the `/teach` handler:

```ruby
if user_input.start_with?("/tasks")
  limit = user_input.split(" ")[1]&.to_i || 10
  data = recent_tasks(limit)
  if data.empty?
    puts "#{DIM}No task history yet.#{RESET}"
  else
    puts "#{CYAN}Recent Tasks:#{RESET}"
    data.split("\n").each do |row|
      cols = row.split("|")
      next if cols.length < 4
      status = cols[2] == "1" ? "#{GREEN}✓#{RESET}" : "#{RED}✗#{RESET}"
      puts "  #{status} #{cols[0][0, 50]}"
      puts "    #{DIM}#{cols[3]}#{RESET}"
    end
  end
  next
end
```

**Step 2: Update `print_help` to include /tasks**

Add after the /teach help line:

```ruby
      #{BOLD}/tasks#{RESET}    #{DIM}show recent task history (/tasks <count>)#{RESET}
```

**Step 3: Test the /tasks command**

Run: `ruby -Ilib bin/ruboto-ai`

```
> List files in this directory
/tasks
```

Expected: Shows the recent task with a checkmark.

**Step 4: Commit**

```bash
git add lib/ruboto.rb
git commit -m "feat: add /tasks command to view episodic task history"
```

---

## Task 9: Integration Test — Full Memory Workflow

**Step 1: Clean slate test**

Delete old database to start fresh:

```bash
rm -f ~/.ruboto/history.db
```

Run: `ruby -Ilib bin/ruboto-ai`

**Step 2: Test profile memory**

```
/profile set name Akhil
/profile set role Founder
/profile
```

Expected: Shows both entries.

**Step 3: Test workflow teaching**

```
/teach deploy when "deploy to prod" do run tests, build Docker image, push to registry, deploy to k8s
/teach
```

Expected: Shows the workflow.

**Step 4: Test LLM memory access**

```
> What do you know about me?
```

Expected: Agent uses memory tool, mentions name and role.

**Step 5: Test fact extraction**

```
> By the way, I usually work between 9am and 6pm IST
```

Expected: Agent saves this as a profile fact.

**Step 6: Test task history**

```
> Show me the directory structure
/tasks
```

Expected: Shows the task with tools used.

**Step 7: Test workflow matching**

```
> I need to deploy to prod
```

Expected: Agent checks memory for matching workflow and references the taught steps.

**Step 8: Verify persistence across sessions**

Quit and restart:

```
/q
```

Run again: `ruby -Ilib bin/ruboto-ai`

```
/profile
/teach
/tasks
```

Expected: All data persists from previous session.

**Step 9: Final commit if any fixes needed**

```bash
git add lib/ruboto.rb
git commit -m "fix: integration fixes for memory foundation"
```

---

## Summary

| Task | What | Key Changes |
|------|------|-------------|
| 1 | Schema expansion | 4 new tables: tasks, profile, workflows, patterns |
| 2 | Memory helpers | CRUD methods for each memory type |
| 3 | /profile command | View, set, delete profile entries |
| 4 | /teach command | Teach named workflows with triggers and steps |
| 5 | memory tool | LLM can read/write all memory types |
| 6 | Task tracking | Agentic loop records task outcomes automatically |
| 7 | Smart system prompt | Memory injected into context + auto fact extraction |
| 8 | /tasks command | View episodic task history |
| 9 | Integration test | End-to-end verification of all memory features |
