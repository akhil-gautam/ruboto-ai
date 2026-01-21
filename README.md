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

    1. Claude Sonnet 4.5  Anthropic's best
    2. Gemini 3 Flash     Google's latest
    3. DeepSeek v3.2      Strong reasoning
    4. Grok Code Fast     xAI coding model
    5. MiniMax M2.1       Versatile model
    6. Seed 1.6           ByteDance model
    7. GLM 4.7            Zhipu AI model
    8. MiMo v2 Flash      Xiaomi (free)
    9. LFM 2.5 Thinking   Liquid (free)

    Or enter any OpenRouter model ID (e.g., openai/gpt-4o)

    Choice:
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

### Default Models

| Model | Provider | Best For |
|-------|----------|----------|
| Claude Sonnet 4.5 | Anthropic | Best overall |
| Gemini 3 Flash | Google | Fast responses |
| DeepSeek v3.2 | DeepSeek | Strong reasoning |
| Grok Code Fast | xAI | Code generation |
| MiniMax M2.1 | MiniMax | Versatile tasks |
| Seed 1.6 | ByteDance | General purpose |
| GLM 4.7 | Zhipu AI | Chinese + English |
| MiMo v2 Flash | Xiaomi | Free tier |
| LFM 2.5 Thinking | Liquid | Free tier |

### Custom Models

You can use **any model** from [OpenRouter](https://openrouter.ai/models) by entering its ID directly:

```
Choice: openai/gpt-4o
Choice: meta-llama/llama-3.3-70b-instruct
Choice: mistralai/mistral-large
```

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
