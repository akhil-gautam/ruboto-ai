# Ruboto

A minimal agentic coding assistant for the terminal. Built in Ruby, powered by multiple LLM providers via OpenRouter.

## Features

- **Multi-model support**: GPT-4o, Claude Sonnet, Gemini, Llama, DeepSeek
- **Agentic tools**: Read, write, edit files, run shell commands, search codebases
- **Meta-tools**: High-level tools for exploration, verification, and patching
- **Conversation history**: Persisted in SQLite with session tracking
- **Autonomous operation**: Acts first, asks questions only when needed
- **Zero dependencies**: Pure Ruby stdlib, no external gems required

## Installation

### From RubyGems

```bash
gem install ruboto-ai
```

### From Source

```bash
git clone https://github.com/akhilgautam/ruboto-ai.git
cd ruboto-ai
gem build ruboto.gemspec
gem install ruboto-ai-0.1.0.gem
```

### Configuration

Set your OpenRouter API key:

```bash
export OPENROUTER_API_KEY="your-api-key-here"
```

Add this to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.) to persist it.

## Usage

```bash
ruboto-ai
```

### Starting a Session

```
$ ruboto-ai

              ██████╗ ██╗   ██╗██████╗  ██████╗ ████████╗ ██████╗
              ██╔══██╗██║   ██║██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗
              ██████╔╝██║   ██║██████╔╝██║   ██║   ██║   ██║   ██║
              ██╔══██╗██║   ██║██╔══██╗██║   ██║   ██║   ██║   ██║
              ██║  ██║╚██████╔╝██████╔╝╚██████╔╝   ██║   ╚██████╔╝
              ╚═╝  ╚═╝ ╚═════╝ ╚═════╝  ╚═════╝    ╚═╝    ╚═════╝

                       Professional YAML indenter

                              myproject

                          Select a model:

    1. GPT-4o          OpenAI flagship
    2. GPT-4o Mini     Fast & cheap
    3. Claude Sonnet 4 Anthropic's latest
    4. Claude 3.5 Sonnet Great for code
    5. Gemini 2.0 Flash Google's fast model
    6. Llama 3.3 70B   Open source
    7. DeepSeek Chat   Strong reasoning

    Enter number (1-7):
```

Select a model by number, then start chatting.

### Example Interactions

**Exploring a codebase:**
```
> where is the authentication logic?

⏺ Exploring: where is the authentication logic?
  ⎿ Question: where is the authentication logic? (+15 more lines)

Authentication is handled in two places:
- src/auth/login.js - main login logic with JWT token generation
- src/middleware/auth.js - route protection middleware
```

**Debugging a bug:**
```
> the todo app is not working, clicking the add button does nothing

⏺ Listing directory
  ⎿ ├── app.js (+5 more)

⏺ Reading app.js
  ⎿    1| import { loadTodos, saveTodos } from "./storage"; ...

⏺ Patching app.js
  ⎿ ok: applied 1 hunk(s)

⏺ Verifying: npm test
  ⎿ {"status":"success","attempts":1,"output":"PASS"}

Fixed! The addBtn click handler was missing. Added it and verified tests pass.
```

**Creating a new file:**
```
> create a utility function to format dates in utils.js

⏺ Writing to utils.js
  ⎿ ok

Created utils.js with a formatDate function that handles ISO strings and Date objects.
```

**Running commands with verification:**
```
> run the tests and make sure they all pass

⏺ Verifying: npm test
  ⎿ {"status":"success","attempts":1,"output":"PASS src/todo.test.js..."}

All 5 tests passed.
```

**Applying multi-line changes:**
```
> add error handling to the fetchUser function

⏺ Reading api.js
  ⎿    1| export async function fetchUser(id) { ...

⏺ Patching api.js
  ⎿ ok: applied 1 hunk(s)

⏺ Verifying: npm test
  ⎿ {"status":"success","attempts":1,"output":"PASS"}

Added try/catch with proper error handling. Tests still pass.
```

### Commands

| Command | Description |
|---------|-------------|
| `/h` | Show help |
| `/c` | Clear conversation context |
| `/q` | Quit |
| `/history` | Show recent commands |
| `Ctrl+C` | Exit |

## Available Tools

### Meta-Tools (Preferred)

| Tool | Description |
|------|-------------|
| `explore` | Answer "where is X?" / "how does Y work?" questions automatically |
| `patch` | Apply unified diffs for multi-line edits (more reliable than string replace) |
| `verify` | Run commands and check success/failure with optional retries |

### Primitive Tools

| Tool | Description |
|------|-------------|
| `read` | Read file contents with line numbers |
| `write` | Create or overwrite a file |
| `edit` | Modify a file (find & replace, must be unique match) |
| `glob` | Find files by pattern (`*.js`, `**/*.test.rb`) |
| `grep` | Search file contents with regex |
| `find` | Locate files by name substring |
| `tree` | Show directory structure |
| `bash` | Run shell commands (git, npm, python, etc.) |

## Supported Models

| Model | Provider | Best For |
|-------|----------|----------|
| GPT-4o | OpenAI | General coding tasks |
| GPT-4o Mini | OpenAI | Fast, cheap tasks |
| Claude Sonnet 4 | Anthropic | Complex reasoning |
| Claude 3.5 Sonnet | Anthropic | Code generation |
| Gemini 2.0 Flash | Google | Fast responses |
| Llama 3.3 70B | Meta | Open source option |
| DeepSeek Chat | DeepSeek | Strong reasoning |

## Data Storage

Ruboto stores data in `~/.ruboto/`:

| File | Purpose |
|------|---------|
| `history.db` | Conversation history (SQLite) |

## Requirements

- Ruby 3.0+
- SQLite3 (usually pre-installed on macOS/Linux)
- OpenRouter API key ([get one here](https://openrouter.ai/keys))

## Development

```bash
# Clone the repo
git clone https://github.com/akhilgautam/ruboto-ai.git
cd ruboto-ai

# Run directly without installing
ruby -Ilib bin/ruboto-ai

# Build the gem
gem build ruboto.gemspec

# Install locally
gem install ruboto-ai-0.1.0.gem

# Uninstall
gem uninstall ruboto-ai
```

## License

MIT - See [LICENSE.txt](LICENSE.txt)
