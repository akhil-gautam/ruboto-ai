# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "openssl"
require "readline"
require "open3"

require_relative "ruboto/version"
require_relative "ruboto/osascript"
require_relative "ruboto/safety"
require_relative "ruboto/tools/macos_auto"
require_relative "ruboto/tools/browser"
require_relative "ruboto/intelligence/pattern_detector"
require_relative "ruboto/intelligence/proactive_triggers"
require_relative "ruboto/intelligence/task_planner"
require_relative "ruboto/intelligence/briefings"
require_relative "ruboto/scheduler"
require_relative "ruboto/intelligence/intent_extractor"
require_relative "ruboto/intelligence/action_executor"
require_relative "ruboto/daemon"

module Ruboto
  API_URL = "https://openrouter.ai/api/v1/chat/completions"

  MODELS = [
    { id: "anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5", desc: "Anthropic's best" },
    { id: "google/gemini-3-flash-preview", name: "Gemini 3 Flash", desc: "Google's latest" },
    { id: "deepseek/deepseek-v3.2", name: "DeepSeek v3.2", desc: "Strong reasoning" },
    { id: "x-ai/grok-code-fast-1", name: "Grok Code Fast", desc: "xAI coding model" },
    { id: "minimax/minimax-m2.1", name: "MiniMax M2.1", desc: "Versatile model" },
    { id: "bytedance-seed/seed-1.6", name: "Seed 1.6", desc: "ByteDance model" },
    { id: "z-ai/glm-4.7", name: "GLM 4.7", desc: "Zhipu AI model" },
    { id: "xiaomi/mimo-v2-flash:free", name: "MiMo v2 Flash", desc: "Xiaomi (free)" },
    { id: "liquid/lfm-2.5-1.2b-thinking:free", name: "LFM 2.5 Thinking", desc: "Liquid (free)" }
  ].freeze

  # ANSI colors
  RESET = "\033[0m"
  BOLD = "\033[1m"
  DIM = "\033[2m"
  BLUE = "\033[34m"
  CYAN = "\033[36m"
  GREEN = "\033[32m"
  YELLOW = "\033[33m"
  RED = "\033[31m"

  MAX_OUTPUT = 4000
  IGNORE_DIRS = [".git", "node_modules", "__pycache__", ".venv", "venv", ".bundle", "vendor", "tmp", "log", "coverage"].freeze

  # History configuration
  RUBOTO_DIR = File.expand_path("~/.ruboto")
  MAX_HISTORY_LOAD = 100

  def self.db_path
    ENV["RUBOTO_DB_PATH"] || File.join(RUBOTO_DIR, "history.db")
  end

  # Spinner frames (braille dots for smooth animation)
  SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

  LOGO = <<~'ASCII'
    ██████╗ ██╗   ██╗██████╗  ██████╗ ████████╗ ██████╗
    ██╔══██╗██║   ██║██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗
    ██████╔╝██║   ██║██████╔╝██║   ██║   ██║   ██║   ██║
    ██╔══██╗██║   ██║██╔══██╗██║   ██║   ██║   ██║   ██║
    ██║  ██║╚██████╔╝██████╔╝╚██████╔╝   ██║   ╚██████╔╝
    ╚═╝  ╚═╝ ╚═════╝ ╚═════╝  ╚═════╝    ╚═╝    ╚═════╝
  ASCII

  TAGLINES = [
    "Your mass-produced artisanal code monkey",
    "Writes code. Breaks things. Blames the compiler.",
    "50% AI, 50% chaos, 100% overconfident",
    "I've read Stack Overflow so you don't have to",
    "Will code for electricity",
    "Professional YAML indenter",
    "I put the 'pro' in 'probably works'",
    "Powered by mass compute and strong opinions"
  ].freeze

  class << self
    include Osascript
    include Safety
    include Tools::MacosAuto
    include Tools::Browser
    include Intelligence::PatternDetector
    include Intelligence::ProactiveTriggers
    include Intelligence::TaskPlanner
    include Intelligence::Briefings
    include Intelligence::IntentExtractor
    include Intelligence::ActionExecutor
    include Scheduler
    include Daemon

    # Human-readable tool action messages
    def tool_message(name, args)
      case name
      when "read"
        path = args["path"] || "file"
        "Reading #{File.basename(path)}"
      when "write"
        path = args["path"] || "file"
        "Writing to #{File.basename(path)}"
      when "edit"
        path = args["path"] || "file"
        "Editing #{File.basename(path)}"
      when "glob"
        pattern = args["pattern"] || "*"
        "Searching for #{pattern}"
      when "grep"
        pattern = args["pattern"] || "pattern"
        "Searching for '#{pattern[0, 30]}'"
      when "bash"
        cmd = args["cmd"] || ""
        cmd_preview = cmd.split.first(2).join(" ")
        "Running #{cmd_preview}"
      when "tree"
        path = args["path"] || "."
        "Listing #{path == "." ? "directory" : path}"
      when "find"
        name_arg = args["name"] || ""
        "Finding files matching '#{name_arg}'"
      when "explore"
        question = args["question"] || "codebase"
        "Exploring: #{question[0, 40]}#{question.length > 40 ? '...' : ''}"
      when "verify"
        cmd = args["command"] || ""
        cmd_preview = cmd.split.first(2).join(" ")
        "Verifying: #{cmd_preview}"
      when "patch"
        path = args["path"] || "file"
        "Patching #{File.basename(path)}"
      when "memory"
        action = args["action"] || "access"
        "Memory: #{action.tr('_', ' ')}"
      when "macos_auto"
        action = args["action"] || "action"
        "macOS: #{action.tr('_', ' ')}"
      when "browser"
        action = args["action"] || "action"
        "Safari: #{action.tr('_', ' ')}"
      when "plan"
        goal = args["goal"] || "task"
        "Planning: #{goal[0, 40]}#{goal.length > 40 ? '...' : ''}"
      else
        name.capitalize.to_s
      end
    end

    # Run a block with a spinner, returns the block's result
    def with_spinner(message)
      result = nil
      done = false
      spinner_thread = Thread.new do
        i = 0
        while !done
          print "\r#{YELLOW}#{SPINNER_FRAMES[i % SPINNER_FRAMES.length]}#{RESET} #{message}"
          $stdout.flush
          sleep 0.08
          i += 1
        end
      end

      begin
        result = yield
      ensure
        done = true
        spinner_thread.join
        print "\r#{GREEN}⏺#{RESET} #{message}\n"
      end

      result
    end

    # --- Tool implementations ---

    def tool_read(args)
      path = args["path"]
      offset = args["offset"] || 0
      limit = args["limit"]

      lines = File.readlines(path)
      limit ||= lines.length
      selected = lines[offset, limit] || []

      selected.each_with_index.map { |line, idx| format("%4d| %s", offset + idx + 1, line) }.join
    end

    def tool_write(args)
      File.write(args["path"], args["content"])
      "ok"
    end

    def tool_edit(args)
      path, old, new_str = args["path"], args["old"], args["new"]
      replace_all = args["all"] || false

      text = File.read(path)

      return "error: old_string not found" unless text.include?(old)

      count = text.scan(old).length
      if !replace_all && count > 1
        return "error: old_string appears #{count} times, must be unique (use all=true)"
      end

      replacement = replace_all ? text.gsub(old, new_str) : text.sub(old, new_str)
      File.write(path, replacement)
      "ok"
    end

    def tool_glob(args)
      base_path = args["path"] || "."
      pattern = File.join(base_path, args["pattern"]).gsub("//", "/")

      files = Dir.glob(pattern, File::FNM_DOTMATCH)
      files = files.select { |f| File.file?(f) }
                   .sort_by { |f| -File.mtime(f).to_i }

      files.empty? ? "none" : files.join("\n")
    end

    def tool_grep(args)
      pattern = Regexp.new(args["pattern"])
      path = args["path"] || "."
      type = args["type"]
      limit = args["limit"] || 30

      glob_pattern = type ? File.join(path, "**", "*.#{type}") : File.join(path, "**", "*")
      hits = []

      Dir.glob(glob_pattern).each do |filepath|
        next unless File.file?(filepath)
        begin
          File.readlines(filepath).each_with_index do |line, idx|
            if pattern.match?(line)
              hits << "#{filepath}:#{idx + 1}:#{line.rstrip}"
              break if hits.length >= limit
            end
          end
        rescue
          # Skip unreadable files
        end
        break if hits.length >= limit
      end

      hits.empty? ? "none" : hits.join("\n")
    end

    def tool_bash(args)
      cmd = args["cmd"]

      # Allowlist of valid command prefixes
      valid_commands = %w[
        git npm npx node ruby python python3 pip pip3 cargo rustc go
        ls cat head tail less more file wc grep awk sed find xargs
        cd pwd mkdir rmdir rm cp mv ln chmod chown touch
        curl wget ssh scp rsync tar zip unzip gzip gunzip
        docker docker-compose kubectl helm
        make cmake gcc g++ clang javac java
        bundle gem rake rails yarn pnpm bun deno
        brew apt yum dnf pacman
        echo printf test expr date cal
        ps top kill pkill htop df du free
        open code vim nano
      ]

      first_word = cmd.strip.split(/\s+/).first&.downcase || ""

      unless valid_commands.include?(first_word)
        return "error: '#{first_word}' is not a recognized command. Use bash only for shell commands like: git, npm, node, python, ls, etc."
      end

      # Reject backticks as a safety measure
      if cmd.include?("`")
        return "error: backticks not allowed in commands (causes shell command substitution)"
      end

      output = `#{cmd} 2>&1`
      output.strip.empty? ? "(empty)" : output.strip
    rescue => e
      "error: #{e.message}"
    end

    def tool_tree(args)
      path = args["path"] || "."
      depth = args["depth"] || 3
      result = get_file_tree(path, depth)
      result.empty? ? "(empty)" : result
    end

    def tool_find(args)
      name = args["name"]
      path = args["path"] || "."

      matches = Dir.glob(File.join(path, "**", "*"))
        .reject { |f| IGNORE_DIRS.any? { |i| f.split("/").include?(i) } }
        .select { |f| File.file?(f) && File.basename(f).downcase.include?(name.downcase) }
        .first(20)

      matches.empty? ? "none" : matches.join("\n")
    end

    def extract_keywords(question)
      stop_words = %w[the a an is are was were what where how does do did can could would should this that these those]
      words = question.downcase.gsub(/[^\w\s]/, '').split
      words.reject { |w| stop_words.include?(w) || w.length < 3 }
    end

    def tool_explore(args)
      question = args["question"]
      scope = args["scope"] || "."

      keywords = extract_keywords(question)
      return "error: couldn't extract keywords from question" if keywords.empty?

      # Phase 1: Get structure overview
      structure = get_file_tree(scope, 2)

      # Phase 2: Search for keywords
      pattern = keywords.first(3).join("|")
      hits = tool_grep("pattern" => pattern, "path" => scope, "limit" => 15)

      if hits == "none"
        # Fallback: try glob for filenames
        keywords.each do |kw|
          file_hits = tool_find("name" => kw, "path" => scope)
          next if file_hits == "none"
          hits = file_hits
          break
        end
      end

      return "No matches found for: #{question}\n\nDirectory structure:\n#{structure}" if hits == "none"

      # Phase 3: Extract unique files and read top 3
      files = hits.lines.map { |l| l.split(":").first }.uniq.first(3)

      context = files.map do |f|
        content = tool_read("path" => f, "limit" => 50)
        "=== #{f} ===\n#{content}"
      end.join("\n\n")

      "Question: #{question}\n\nFiles found: #{files.join(', ')}\n\n#{context}"
    rescue => e
      "error: #{e.message}"
    end

    def tool_verify(args)
      cmd = args["command"]
      expect_pattern = args["expect_pattern"]
      fail_pattern = args["fail_pattern"]
      retries = args["retries"] || 0
      retries = [retries, 10].min

      # Validate command against allowlist
      first_word = cmd.strip.split(/\s+/).first&.downcase || ""
      valid_commands = %w[
        git npm npx node ruby python python3 pip pip3 cargo rustc go
        ls cat head tail less more file wc grep awk sed find xargs
        bundle gem rake rails yarn pnpm bun deno
        make cmake gcc g++ clang javac java
        pytest rspec jest mocha
        echo test expr
      ]

      unless valid_commands.include?(first_word)
        return { status: "error", message: "command '#{first_word}' not in allowlist" }.to_json
      end

      if cmd.include?("`")
        return { status: "error", message: "backticks not allowed in commands" }.to_json
      end

      attempts = 0
      output = ""
      exit_code = 0

      loop do
        attempts += 1
        output = `#{cmd} 2>&1`
        exit_code = $?.exitstatus

        passed = exit_code == 0
        passed &&= output.match?(Regexp.new(expect_pattern)) if expect_pattern
        passed = false if fail_pattern && output.match?(Regexp.new(fail_pattern))

        if passed
          return {
            status: "success",
            attempts: attempts,
            output: truncate_output(output, 1000)
          }.to_json
        end

        break if attempts > retries
        sleep 0.5
      end

      {
        status: "failed",
        attempts: attempts,
        exit_code: exit_code,
        output: truncate_output(output, 2000)
      }.to_json
    rescue => e
      { status: "error", message: e.message }.to_json
    end

    def parse_unified_diff(diff)
      hunks = []
      current_hunk = nil

      diff.lines.each do |line|
        if line.start_with?("@@")
          match = line.match(/@@ -(\d+),?(\d*) \+(\d+),?(\d*) @@/)
          if match
            current_hunk = {
              old_start: match[1].to_i,
              old_count: match[2].empty? ? 1 : match[2].to_i,
              new_start: match[3].to_i,
              new_count: match[4].empty? ? 1 : match[4].to_i,
              old_lines: [],
              new_lines: []
            }
            hunks << current_hunk
          end
        elsif current_hunk
          case line[0]
          when "-"
            current_hunk[:old_lines] << line[1..].chomp
          when "+"
            current_hunk[:new_lines] << line[1..].chomp
          when " "
            current_hunk[:old_lines] << line[1..].chomp
            current_hunk[:new_lines] << line[1..].chomp
          end
        end
      end

      hunks
    end

    def fuzzy_find_hunk(lines, old_lines, expected_start, tolerance: 20)
      return expected_start - 1 if old_lines.empty?

      search_start = [expected_start - tolerance - 1, 0].max
      search_end = [expected_start + tolerance - 1, lines.length - 1].min

      (search_start..search_end).each do |idx|
        match = old_lines.each_with_index.all? do |old_line, offset|
          lines[idx + offset]&.chomp == old_line
        end
        return idx if match
      end

      # Fallback: search entire file
      lines.each_with_index do |_, idx|
        match = old_lines.each_with_index.all? do |old_line, offset|
          lines[idx + offset]&.chomp == old_line
        end
        return idx if match
      end

      nil
    end

    def tool_patch(args)
      path = args["path"]
      diff = args["diff"]

      return "error: file not found: #{path}" unless File.exist?(path)

      lines = File.readlines(path)
      hunks = parse_unified_diff(diff)

      return "error: no valid hunks found in diff" if hunks.empty?

      # Apply hunks in reverse order to preserve line numbers
      hunks.reverse.each_with_index do |hunk, idx|
        actual_start = fuzzy_find_hunk(lines, hunk[:old_lines], hunk[:old_start])

        unless actual_start
          return "error: couldn't locate hunk #{hunks.length - idx} near line #{hunk[:old_start]}"
        end

        lines.slice!(actual_start, hunk[:old_lines].length)
        hunk[:new_lines].reverse.each do |new_line|
          lines.insert(actual_start, new_line + "\n")
        end
      end

      File.write(path, lines.join)
      "ok: applied #{hunks.length} hunk(s)"
    rescue => e
      "error: #{e.message}"
    end

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

    # --- Tool definitions ---

    def tools
      @tools ||= {
        "read" => {
          impl: method(:tool_read),
          schema: {
            type: "function",
            name: "read",
            description: "Read file with line numbers (file path, not directory)",
            parameters: {
              type: "object",
              properties: {
                path: { type: "string", description: "Path to the file" },
                offset: { type: "integer", description: "Line offset to start from" },
                limit: { type: "integer", description: "Number of lines to read" }
              },
              required: ["path"]
            }
          }
        },
        "write" => {
          impl: method(:tool_write),
          schema: {
            type: "function",
            name: "write",
            description: "Write content to file",
            parameters: {
              type: "object",
              properties: {
                path: { type: "string", description: "Path to the file" },
                content: { type: "string", description: "Content to write" }
              },
              required: ["path", "content"]
            }
          }
        },
        "edit" => {
          impl: method(:tool_edit),
          schema: {
            type: "function",
            name: "edit",
            description: "Replace old with new in file (old must be unique unless all=true)",
            parameters: {
              type: "object",
              properties: {
                path: { type: "string", description: "Path to the file" },
                old: { type: "string", description: "String to find and replace" },
                new: { type: "string", description: "Replacement string" },
                all: { type: "boolean", description: "Replace all occurrences" }
              },
              required: ["path", "old", "new"]
            }
          }
        },
        "glob" => {
          impl: method(:tool_glob),
          schema: {
            type: "function",
            name: "glob",
            description: "Find files by pattern, sorted by mtime",
            parameters: {
              type: "object",
              properties: {
                pattern: { type: "string", description: "Glob pattern (e.g., **/*.rb)" },
                path: { type: "string", description: "Base path to search from" }
              },
              required: ["pattern"]
            }
          }
        },
        "grep" => {
          impl: method(:tool_grep),
          schema: {
            type: "function",
            name: "grep",
            description: "Search file contents for regex pattern",
            parameters: {
              type: "object",
              properties: {
                pattern: { type: "string", description: "Regex pattern to search for" },
                path: { type: "string", description: "Directory to search (default: current)" },
                type: { type: "string", description: "File extension filter (e.g., 'rb', 'js')" },
                limit: { type: "integer", description: "Max results (default: 30)" }
              },
              required: ["pattern"]
            }
          }
        },
        "bash" => {
          impl: method(:tool_bash),
          schema: {
            type: "function",
            name: "bash",
            description: "Run shell command",
            parameters: {
              type: "object",
              properties: {
                cmd: { type: "string", description: "Command to execute" }
              },
              required: ["cmd"]
            }
          }
        },
        "tree" => {
          impl: method(:tool_tree),
          schema: {
            type: "function",
            name: "tree",
            description: "Show directory structure (use to orient yourself)",
            parameters: {
              type: "object",
              properties: {
                path: { type: "string", description: "Directory to show (default: current)" },
                depth: { type: "integer", description: "Max depth (default: 3)" }
              },
              required: []
            }
          }
        },
        "find" => {
          impl: method(:tool_find),
          schema: {
            type: "function",
            name: "find",
            description: "Find files by name (fast, no content reading)",
            parameters: {
              type: "object",
              properties: {
                name: { type: "string", description: "Filename substring to search for" },
                path: { type: "string", description: "Directory to search (default: current)" }
              },
              required: ["name"]
            }
          }
        },
        "explore" => {
          impl: method(:tool_explore),
          schema: {
            type: "function",
            name: "explore",
            description: "Answer questions about the codebase (where is X, how does Y work). Searches and reads relevant files automatically.",
            parameters: {
              type: "object",
              properties: {
                question: { type: "string", description: "What you want to know about the codebase" },
                scope: { type: "string", description: "Directory to focus on (optional)" }
              },
              required: ["question"]
            }
          }
        },
        "verify" => {
          impl: method(:tool_verify),
          schema: {
            type: "function",
            name: "verify",
            description: "Run a command and check if it succeeds. Use after code changes to verify they work.",
            parameters: {
              type: "object",
              properties: {
                command: { type: "string", description: "Command to run" },
                expect_pattern: { type: "string", description: "Regex that should match output on success" },
                fail_pattern: { type: "string", description: "Regex indicating failure" },
                retries: { type: "integer", description: "Number of retries (default: 0)" }
              },
              required: ["command"]
            }
          }
        },
        "patch" => {
          impl: method(:tool_patch),
          schema: {
            type: "function",
            name: "patch",
            description: "Apply a unified diff to a file. More reliable than string replacement for multi-line changes.",
            parameters: {
              type: "object",
              properties: {
                path: { type: "string", description: "File to patch" },
                diff: { type: "string", description: "Unified diff format (like git diff output)" }
              },
              required: ["path", "diff"]
            }
          }
        },
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
        "macos_auto" => {
          impl: method(:tool_macos_auto),
          schema: macos_auto_schema
        },
        "browser" => {
          impl: method(:tool_browser),
          schema: browser_schema
        },
        "plan" => {
          impl: method(:tool_plan),
          schema: plan_schema
        }
      }
    end

    def truncate_output(result, max = MAX_OUTPUT)
      return result if result.length <= max
      result[0, max] + "\n... (truncated, #{result.length - max} chars omitted)"
    end

    def run_tool(name, args)
      tool = tools[name]
      return "error: unknown tool '#{name}'" unless tool
      result = tool[:impl].call(args)
      truncate_output(result)
    rescue => e
      "error: #{e.message}"
    end

    def tool_schemas
      tools.values.map do |t|
        schema = t[:schema]
        {
          type: "function",
          function: {
            name: schema[:name],
            description: schema[:description],
            parameters: schema[:parameters]
          }
        }
      end
    end

    def call_api(messages, model)
      uri = URI(API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      api_key = ENV['OPENROUTER_API_KEY']
      raise "OPENROUTER_API_KEY environment variable is required" unless api_key
      request["Authorization"] = "Bearer #{api_key}"
      request["HTTP-Referer"] = "https://github.com/ruboto"
      request["X-Title"] = "Ruboto"

      body = {
        model: model,
        messages: messages,
        tools: tool_schemas,
        max_tokens: 8192
      }

      request.body = body.to_json

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        puts "#{RED}Debug - Response body: #{response.body}#{RESET}"
        return { "error" => { "message" => "HTTP #{response.code}: #{response.message}" } }
      end
      JSON.parse(response.body)
    end

    def get_file_tree(path = ".", depth = 3, prefix = "")
      return "" if depth <= 0

      entries = Dir.entries(path) - [".", ".."]
      entries = entries.reject { |e| e.start_with?(".") || IGNORE_DIRS.include?(e) }
      entries = entries.sort_by { |e| [File.directory?(File.join(path, e)) ? 0 : 1, e.downcase] }

      lines = []
      entries.each_with_index do |entry, idx|
        full_path = File.join(path, entry)
        is_last = idx == entries.length - 1
        connector = is_last ? "└── " : "├── "

        if File.directory?(full_path)
          lines << "#{prefix}#{connector}#{entry}/"
          extension = is_last ? "    " : "│   "
          lines << get_file_tree(full_path, depth - 1, prefix + extension)
        else
          lines << "#{prefix}#{connector}#{entry}"
        end
      end

      lines.reject(&:empty?).join("\n")
    end

    def separator
      width = [`tput cols`.to_i, 80].min
      width = 80 if width <= 0
      "#{DIM}#{'─' * width}#{RESET}"
    end

    def render_markdown(text)
      text.gsub(/\*\*(.+?)\*\*/m, "#{BOLD}\\1#{RESET}")
    end

    # --- History persistence ---

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

        CREATE TABLE IF NOT EXISTS action_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          intent TEXT NOT NULL,
          description TEXT,
          source_email_id TEXT,
          extracted_data TEXT,
          action_plan TEXT,
          status TEXT DEFAULT 'pending',
          confidence REAL,
          not_before TEXT,
          result TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          executed_at TEXT
        );

        CREATE TABLE IF NOT EXISTS watched_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source TEXT NOT NULL,
          source_id TEXT NOT NULL,
          seen_at TEXT DEFAULT (datetime('now')),
          UNIQUE(source, source_id)
        );

        CREATE TABLE IF NOT EXISTS user_workflows (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          description TEXT NOT NULL,
          trigger_type TEXT NOT NULL,
          trigger_config TEXT,
          sources TEXT,
          transforms TEXT,
          destinations TEXT,
          overall_confidence REAL DEFAULT 0.0,
          run_count INTEGER DEFAULT 0,
          success_count INTEGER DEFAULT 0,
          enabled INTEGER DEFAULT 1,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          UNIQUE(name)
        );

        CREATE TABLE IF NOT EXISTS workflow_steps (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          workflow_id INTEGER NOT NULL,
          step_order INTEGER NOT NULL,
          tool TEXT NOT NULL,
          params TEXT,
          output_key TEXT,
          description TEXT,
          confidence REAL DEFAULT 0.0,
          FOREIGN KEY (workflow_id) REFERENCES user_workflows(id)
        );

        CREATE TABLE IF NOT EXISTS workflow_runs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          workflow_id INTEGER NOT NULL,
          status TEXT DEFAULT 'running',
          started_at TEXT DEFAULT (datetime('now')),
          completed_at TEXT,
          state_snapshot TEXT,
          log TEXT,
          FOREIGN KEY (workflow_id) REFERENCES user_workflows(id)
        );

        CREATE TABLE IF NOT EXISTS step_corrections (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          workflow_id INTEGER NOT NULL,
          step_order INTEGER NOT NULL,
          correction_type TEXT NOT NULL,
          original_value TEXT,
          corrected_value TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          FOREIGN KEY (workflow_id) REFERENCES user_workflows(id)
        );

        CREATE TABLE IF NOT EXISTS trigger_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          workflow_id INTEGER NOT NULL,
          trigger_type TEXT NOT NULL,
          trigger_data TEXT,
          triggered_at TEXT DEFAULT (datetime('now')),
          FOREIGN KEY (workflow_id) REFERENCES user_workflows(id)
        );
      SQL

      run_sql(schema)
    end

    def run_sql(sql)
      output, _status = Open3.capture2('sqlite3', db_path, sql)
      output.strip
    rescue => e
      ""
    end

    def save_message(role, content, session_id = nil)
      escaped_content = content.gsub('"', '""').gsub('$', '\$')
      escaped_dir = Dir.pwd.gsub('"', '""')
      session_part = session_id ? "'#{session_id}'" : "NULL"

      sql = "INSERT INTO messages (role, content, session_id, working_dir) " \
            "VALUES ('#{role}', \"#{escaped_content}\", #{session_part}, \"#{escaped_dir}\");"
      run_sql(sql)
    end

    def load_readline_history
      sql = "SELECT content FROM messages WHERE role='user' ORDER BY id DESC LIMIT #{MAX_HISTORY_LOAD};"
      entries = run_sql(sql).split("\n").reverse
      entries.each { |cmd| Readline::HISTORY << cmd }
    rescue
      # Ignore history load errors
    end

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
      limit = limit.to_i.clamp(1, 100)
      sql = "SELECT request, outcome, success, created_at FROM tasks ORDER BY id DESC LIMIT #{limit};"
      run_sql(sql)
    end

    def set_profile(key, value, confidence = 1.0, source = "explicit")
      escaped_key = key.gsub("'", "''")
      escaped_value = value.gsub("'", "''")
      escaped_source = source.gsub("'", "''")
      confidence = confidence.to_f.clamp(0.0, 1.0)

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

    def save_pattern(pattern_type, description, conditions = nil)
      escaped_type = pattern_type.gsub("'", "''")
      escaped_desc = description.gsub("'", "''")
      conditions_part = conditions ? "'#{conditions.gsub("'", "''")}'" : "NULL"

      sql = "INSERT INTO patterns (pattern_type, description, conditions) " \
            "VALUES ('#{escaped_type}', '#{escaped_desc}', #{conditions_part});"
      run_sql(sql)
    end

    def get_patterns(min_confidence = 0.5)
      min_confidence = min_confidence.to_f.clamp(0.0, 1.0)
      sql = "SELECT pattern_type, description, conditions, frequency, confidence FROM patterns " \
            "WHERE confidence >= #{min_confidence} ORDER BY confidence DESC;"
      run_sql(sql)
    end

    def reinforce_pattern(id)
      id = id.to_i
      sql = "UPDATE patterns SET frequency = frequency + 1, " \
            "confidence = MIN(1.0, confidence + 0.1), updated_at = datetime('now') WHERE id=#{id};"
      run_sql(sql)
    end

    def weaken_pattern(id)
      id = id.to_i
      sql = "UPDATE patterns SET confidence = MAX(0.0, confidence - 0.1), updated_at = datetime('now') WHERE id=#{id};"
      run_sql(sql)
    end

    def terminal_width
      width = `tput cols 2>/dev/null`.to_i
      width > 0 ? width : 80
    end

    def center_text(text, width)
      padding = [(width - text.gsub(/\e\[[0-9;]*m/, '').length) / 2, 0].max
      " " * padding + text
    end

    def print_startup
      width = terminal_width
      colors = [RED, YELLOW, GREEN, CYAN, BLUE, "\033[35m"]

      # Clear screen and hide cursor
      print "\033[2J\033[H\033[?25l"

      # Animate logo reveal line by line with color wave
      logo_lines = LOGO.lines.map(&:chomp)

      logo_lines.each_with_index do |line, idx|
        color = colors[idx % colors.length]
        centered = center_text(line, width)
        print "\r#{color}#{centered}#{RESET}"
        puts
        sleep 0.06
      end

      # Pause then show tagline with typewriter effect
      sleep 0.3
      tagline = TAGLINES.sample
      centered_tag = center_text(tagline, width)

      puts
      print " " * [(width - tagline.length) / 2, 0].max
      tagline.each_char do |c|
        print "#{DIM}#{c}#{RESET}"
        $stdout.flush
        sleep 0.02
      end
      puts

      # Show directory
      sleep 0.2
      info = File.basename(Dir.pwd).to_s
      puts center_text("#{DIM}#{info}#{RESET}", width)

      # Show cursor again
      print "\033[?25h"

      # Brief pause before prompt
      sleep 0.3
      puts
    end

    def select_model
      width = terminal_width

      puts center_text("#{CYAN}Select a model:#{RESET}", width)
      puts

      MODELS.each_with_index do |model, idx|
        num = "#{BOLD}#{idx + 1}#{RESET}"
        name = "#{CYAN}#{model[:name]}#{RESET}"
        desc = "#{DIM}#{model[:desc]}#{RESET}"
        puts "    #{num}. #{name} #{desc}"
      end

      puts
      puts "    #{DIM}Or enter any OpenRouter model ID (e.g., openai/gpt-4o)#{RESET}"
      puts
      print "    #{DIM}Choice:#{RESET} "

      loop do
        input = gets&.strip
        return MODELS[0][:id] if input.nil? || input.empty?

        # Check if it's a number selection
        num = input.to_i
        if num >= 1 && num <= MODELS.length
          selected = MODELS[num - 1]
          puts "\n    #{GREEN}✓#{RESET} Using #{BOLD}#{selected[:name]}#{RESET}"
          puts
          return selected[:id]
        elsif input.include?("/")
          # Custom model ID (contains slash like "openai/gpt-4o")
          puts "\n    #{GREEN}✓#{RESET} Using #{BOLD}#{input}#{RESET}"
          puts
          return input
        else
          print "    #{RED}Invalid.#{RESET} Enter 1-#{MODELS.length} or a model ID: "
        end
      end
    end

    def print_help
      puts <<~HELP
        #{CYAN}Examples:#{RESET}
          #{DIM}•#{RESET} "Find all TODO comments in this project"
          #{DIM}•#{RESET} "Explain what the main function does"
          #{DIM}•#{RESET} "Add error handling to tool_read"
          #{DIM}•#{RESET} "Run the tests and fix any failures"

        #{CYAN}Capabilities:#{RESET}
          #{DIM}•#{RESET} Code: read, write, edit, search, run commands
          #{DIM}•#{RESET} macOS: calendar, reminders, email, notes, clipboard, notifications
          #{DIM}•#{RESET} Safari: open URLs, read pages, fill forms, click elements
          #{DIM}•#{RESET} Intelligence: pattern detection, proactive suggestions, task planning
          #{DIM}•#{RESET} Autonomous: background daemon, email monitoring, auto-actions

        #{CYAN}Commands:#{RESET}
          #{BOLD}/q#{RESET}        #{DIM}quit#{RESET}
          #{BOLD}/c#{RESET}        #{DIM}clear conversation context#{RESET}
          #{BOLD}/h#{RESET}        #{DIM}show this help#{RESET}
          #{BOLD}/history#{RESET}  #{DIM}show recent commands#{RESET}
          #{BOLD}/profile#{RESET}  #{DIM}view/set profile (set <key> <val>, del <key>)#{RESET}
          #{BOLD}/teach#{RESET}    #{DIM}teach workflows (/teach name when <trigger> do <steps>)#{RESET}
          #{BOLD}/tasks#{RESET}    #{DIM}show recent task history (/tasks <count>)#{RESET}
          #{BOLD}/briefing#{RESET} #{DIM}run morning/evening briefing (/briefing morning|evening|auto)#{RESET}
          #{BOLD}/queue#{RESET}    #{DIM}show pending daemon actions#{RESET}
          #{BOLD}/cancel#{RESET}   #{DIM}cancel a daemon action (/cancel <id>)#{RESET}
          #{BOLD}/workflow#{RESET} #{DIM}create workflow (/workflow "description")#{RESET}
          #{BOLD}/workflows#{RESET} #{DIM}list saved workflows#{RESET}
          #{BOLD}/run#{RESET}      #{DIM}run a workflow (/run <name>)#{RESET}
          #{BOLD}/trust#{RESET}    #{DIM}view/adjust step confidence (/trust <name> [step] [0-100])#{RESET}
          #{BOLD}/schedule#{RESET} #{DIM}manage workflow schedules (/schedule list|enable|disable|status)#{RESET}
          #{BOLD}/history#{RESET}  #{DIM}view workflow run history (/history [name] [limit])#{RESET}
          #{BOLD}/export#{RESET}   #{DIM}export workflow to file (/export <name> [file])#{RESET}
          #{BOLD}/import#{RESET}   #{DIM}import workflow from file (/import <file>)#{RESET}
          #{BOLD}/audit#{RESET}    #{DIM}view audit logs (/audit <name> [run-id])#{RESET}
      HELP
    end

    def run
      ensure_db_exists
      detect_patterns
      load_readline_history
      print_startup

      # Model selection
      model = select_model

      session_id = Time.now.strftime("%Y%m%d_%H%M%S")

      suggestions = check_triggers
      print_suggestions(suggestions)

      # Build memory context
      profile_data = get_profile
      workflow_data = get_workflows
      recent = recent_tasks(5)

      memory_summary = ""
      memory_summary += "USER PROFILE:\n#{profile_data}\n\n" unless profile_data.empty?
      memory_summary += "KNOWN WORKFLOWS:\n#{workflow_data}\n\n" unless workflow_data.empty?
      memory_summary += "RECENT TASKS:\n#{recent}\n\n" unless recent.empty?

      system_prompt = <<~PROMPT
        You are a fast, autonomous assistant with coding AND system automation powers. Working directory: #{Dir.pwd}

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

        INTELLIGENCE RULES:
        - For complex multi-step requests, use the plan tool first to structure the approach
        - Detected patterns and suggestions are shown to the user at session start
        - When executing a plan, adapt if a step fails -- skip or find alternatives
        - The plan tool returns advisory steps -- you decide execution order and can skip/add steps

        SAFETY RULES (HIGHEST PRIORITY):
        - NEVER take destructive actions unless the user explicitly asks for them
        - Destructive actions include: deleting files/emails/events, sending emails on behalf of the user, modifying or cancelling bookings/reservations, running rm/rmdir/git reset --hard, overwriting important data
        - When in doubt, READ and REPORT rather than modify or delete
        - Always prefer non-destructive alternatives (e.g., draft an email instead of sending it, list files instead of deleting them)
        - If a task inherently requires a destructive action, explain what you would do and ask for confirmation first

        ACTION RULES:
        - Use macos_auto to open apps, check calendar, create reminders, send emails, create notes, manage clipboard
        - Use browser to open URLs, read page content, fill forms, click buttons, extract links
        - Chain actions naturally: check calendar → draft email → send it
        - mail_send and browser run_js require user confirmation — just call the tool, user will be prompted
        - If an action fails (app not running, permission denied), report the error and suggest alternatives

        BROWSER WORKFLOW FOR EMAIL → ACTION TASKS:
        1. SEARCH: Use Gmail URL search (mail.google.com/mail/u/0/#search/your+terms) — never click labels or categories
        2. OPEN EMAIL: Use get_links to find email URLs, then open_url to view the specific email
        3. EXTRACT INFO: Use get_text to read the email body — extract PNR, booking ID, dates, names, links
        4. NAVIGATE TO ACTION SITE: Use open_url to go directly to the service website (airline, hotel, etc.)
        5. FILL FORM: Use get_text to identify ALL input fields first, then fill EACH field before clicking submit
        6. NEVER click submit/OTP buttons until ALL required fields are filled

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

      # Initialize conversation with system message
      messages = [{ role: "system", content: system_prompt }]

      puts "#{DIM}Type your request, or /h for help#{RESET}"

      loop do
        begin
          puts separator
          user_input = Readline.readline("#{BOLD}#{BLUE}> #{RESET}", false)&.strip
          puts separator

          break if user_input.nil?
          next if user_input.empty?

          # Handle suggestion selection
          unless suggestions.empty?
            if user_input.match?(/\A\d+\z/)
              action = handle_suggestion_input(user_input, suggestions)
              if action
                user_input = action
                puts "  #{GREEN}✓#{RESET} #{action}"
              end
            else
              weaken_all_suggestions(suggestions)
            end
            suggestions = []
          end

          break if ["/q", "exit"].include?(user_input)

          if user_input == "/c"
            messages = [{ role: "system", content: system_prompt }]
            puts "#{GREEN}⏺ Cleared conversation#{RESET}"
            next
          end

          if user_input == "/h" || user_input == "/help"
            print_help
            next
          end

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

          if user_input.start_with?("/briefing")
            mode = user_input.split(" ")[1] || "auto"
            run_briefing(mode)
            next
          end

          if user_input == "/queue"
            show_action_queue
            next
          end

          if user_input.start_with?("/cancel")
            action_id = user_input.split(" ")[1]
            if action_id && action_id.match?(/\A\d+\z/)
              cancel_action(action_id.to_i)
            else
              puts "#{RED}Usage: /cancel <action_id>#{RESET}"
            end
            next
          end

          if user_input == "/history"
            sql = "SELECT content FROM messages WHERE role='user' ORDER BY id DESC LIMIT 10;"
            entries = run_sql(sql).split("\n")
            if entries.empty?
              puts "#{DIM}No history yet.#{RESET}"
            else
              puts "#{DIM}Recent commands:#{RESET}"
              entries.each_with_index { |cmd, i| puts "  #{DIM}#{i + 1}.#{RESET} #{cmd[0, 60]}" }
            end
            next
          end

          if user_input.start_with?("/workflow")
            rest = user_input.sub("/workflow", "").strip
            if rest.empty?
              puts "#{RED}Usage: /workflow \"description of your workflow\"#{RESET}"
            else
              create_workflow_interactive(rest.gsub(/^["']|["']$/, ''))
            end
            next
          end

          if user_input == "/workflows"
            list_workflows_cli
            next
          end

          if user_input.start_with?("/run")
            name = user_input.sub("/run", "").strip
            if name.empty?
              puts "#{RED}Usage: /run <workflow-name>#{RESET}"
            else
              run_workflow_cli(name)
            end
            next
          end

          if user_input.start_with?("/trust")
            args = user_input.sub("/trust", "").strip.split(/\s+/)
            if args.empty?
              puts "#{RED}Usage: /trust <workflow-name> [step_number] [confidence 0-100]#{RESET}"
              puts "#{DIM}Example: /trust weekly-expenses 2 90#{RESET}"
            else
              trust_workflow_cli(args[0], args[1]&.to_i, args[2]&.to_i)
            end
            next
          end

          if user_input.start_with?("/schedule")
            args = user_input.sub("/schedule", "").strip.split(/\s+/)
            if args.empty?
              schedule_cli("list")
            else
              schedule_cli(args[0], args[1])
            end
            next
          end

          if user_input.start_with?("/history")
            args = user_input.sub("/history", "").strip.split(/\s+/)
            history_cli(args[0], args[1]&.to_i)
            next
          end

          if user_input.start_with?("/export")
            args = user_input.sub("/export", "").strip.split(/\s+/)
            if args.empty?
              puts "#{RED}Usage: /export <workflow-name> [file-path]#{RESET}"
            else
              export_cli(args[0], args[1])
            end
            next
          end

          if user_input.start_with?("/import")
            file_path = user_input.sub("/import", "").strip
            if file_path.empty?
              puts "#{RED}Usage: /import <file-path>#{RESET}"
            else
              import_cli(file_path)
            end
            next
          end

          if user_input.start_with?("/audit")
            args = user_input.sub("/audit", "").strip.split(/\s+/)
            if args.empty?
              puts "#{RED}Usage: /audit <workflow-name> [run-id]#{RESET}"
            else
              audit_cli(args[0], args[1])
            end
            next
          end

          # Save to history
          Readline::HISTORY << user_input
          save_message("user", user_input, session_id)

          # Add user message to conversation
          messages << { role: "user", content: user_input }

          # Track tools used in this interaction
          interaction_tools = []
          task_success = true

          # Agentic loop
          loop do
            response = with_spinner("Thinking...") do
              call_api(messages, model)
            end

            if response["error"]
              puts "#{RED}⏺ API Error: #{response["error"]["message"]}#{RESET}"
              task_success = false
              break
            end

            # Parse Chat Completions response
            choice = response.dig("choices", 0)
            unless choice
              puts "#{RED}⏺ Error: No response from model#{RESET}"
              task_success = false
              break
            end

            message = choice["message"]
            text_content = message["content"]
            tool_calls = message["tool_calls"] || []

            # Add assistant message to conversation
            messages << message

            if text_content && !text_content.empty?
              puts "\n#{CYAN}⏺#{RESET} #{render_markdown(text_content)}"
              save_message("assistant", text_content, session_id)
            end

            break if tool_calls.empty?

            # Execute tool calls and add results to messages
            tool_calls.each do |tc|
              tool_name = tc.dig("function", "name")
              tool_args = JSON.parse(tc.dig("function", "arguments") || "{}")
              call_id = tc["id"]

              label = tool_message(tool_name, tool_args)
              interaction_tools << tool_name

              print "\n"
              result = with_spinner(label) do
                run_tool(tool_name, tool_args)
              end

              result_lines = result.split("\n")
              preview = result_lines.first.to_s[0, 60]
              if result_lines.length > 1
                preview += " #{DIM}(+#{result_lines.length - 1} more lines)#{RESET}"
              elsif result_lines.first.to_s.length > 60
                preview += "..."
              end
              puts "  #{DIM}⎿ #{preview}#{RESET}"

              # Add tool result to conversation
              messages << {
                role: "tool",
                tool_call_id: call_id,
                content: result
              }
            end
          end

          # Save task to episodic memory
          unless interaction_tools.empty?
            last_text = messages.reverse.find { |m| (m["role"] || m[:role]) == "assistant" && (m["content"] || m[:content]) }&.then { |m| m["content"] || m[:content] }
            save_task(
              user_input,
              (last_text || "")[0, 200],
              interaction_tools.uniq.join(", "),
              task_success,
              session_id
            )
          end

          puts

        rescue Interrupt
          break
        rescue => e
          puts "#{RED}⏺ Error: #{e.message}#{RESET}"
          puts e.backtrace.first(3).join("\n") if ENV["DEBUG"]
        end
      end
    end

    def run_quick(request, context: nil)
      result = run_headless(request, context: context)
      puts result[:text] if result[:text]
      exit(result[:success] ? 0 : 1)
    end

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

    def run_headless(request, model: nil, context: nil)
      ensure_db_exists
      model ||= MODELS.first[:id]
      session_id = Time.now.strftime("%Y%m%d_%H%M%S")

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

        SAFETY RULES (HIGHEST PRIORITY):
        - NEVER take destructive actions unless the user explicitly asked for them
        - Destructive actions include: deleting files/emails/events, sending emails, modifying or cancelling bookings/reservations, running rm/rmdir/git reset --hard, overwriting important data
        - When in doubt, READ and REPORT rather than modify or delete
        - Always prefer non-destructive alternatives (e.g., open a page and report what you see rather than submitting forms)
        - If a task inherently requires a destructive action, stop and report what you would do instead of doing it

        AUTONOMY RULES:
        - ACT FIRST. Just do it — but never destructively.
        - After ANY code change → immediately use verify to check it works
        - Keep using tools until you have a complete answer

        ACTION RULES:
        - Use macos_auto for macOS apps. Use browser for Safari.
        - Chain actions naturally.

        BROWSER WORKFLOW FOR EMAIL → ACTION TASKS:
        1. SEARCH: Use Gmail URL search (mail.google.com/mail/u/0/#search/your+terms) — never click labels or categories
        2. OPEN EMAIL: Use get_links to find email URLs, then open_url to view the specific email
        3. EXTRACT INFO: Use get_text to read the email body — extract PNR, booking ID, dates, names, links
        4. NAVIGATE TO ACTION SITE: Use open_url to go directly to the service website (airline, hotel, etc.)
        5. FILL FORM: Use get_text to identify ALL input fields first, then fill EACH field before clicking submit
        6. NEVER click submit/OTP buttons until ALL required fields are filled

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
          return { success: false, text: "API Error: #{response.dig("error", "message")}", tools_used: interaction_tools }
        end

        choice = response.dig("choices", 0)
        unless choice
          return { success: false, text: "No response from model", tools_used: interaction_tools }
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

      unless interaction_tools.empty?
        save_task(request, (final_text || "")[0, 200], interaction_tools.uniq.join(", "), task_success, session_id)
      end

      { success: task_success, text: final_text, tools_used: interaction_tools }
    rescue => e
      { success: false, text: "Error: #{e.message}", tools_used: [] }
    end

    def create_workflow_interactive(description)
      require_relative "ruboto/workflow"
      ensure_db_exists

      puts "#{CYAN}Parsing workflow...#{RESET}"
      parsed = Workflow::IntentParser.parse(description)
      steps = Workflow::PlanGenerator.generate(parsed)

      puts "\n#{BOLD}Workflow: #{parsed.name}#{RESET}"
      puts "#{DIM}\"#{description}\"#{RESET}\n\n"

      puts "#{CYAN}Trigger:#{RESET} #{parsed.trigger[:type]} #{parsed.trigger[:match] ? "(#{parsed.trigger[:match]})" : "(manual)"}"
      puts "\n#{CYAN}Generated #{steps.length} steps:#{RESET}"

      steps.each_with_index do |step, idx|
        puts "  #{BOLD}#{idx + 1}.#{RESET} #{step.description}"
        puts "     #{DIM}Tool: #{step.tool}, Output: $#{step.output_key || 'none'}#{RESET}"
      end

      print "\n#{YELLOW}Save this workflow? [y/n]#{RESET} "
      answer = gets&.strip&.downcase
      if answer == "y"
        id = Workflow::Storage.save_workflow(parsed, steps)
        puts "#{GREEN}✓#{RESET} Saved workflow '#{parsed.name}' (id: #{id})"
        puts "#{DIM}Run with: ruboto-ai --run-workflow #{parsed.name}#{RESET}"
      else
        puts "#{DIM}Workflow not saved.#{RESET}"
      end
    end

    def list_workflows_cli
      require_relative "ruboto/workflow"
      ensure_db_exists

      workflows = Workflow::Storage.list_workflows
      if workflows.empty?
        puts "#{DIM}No workflows saved yet.#{RESET}"
        puts "Create one with: ruboto-ai --workflow \"your workflow description\""
        return
      end

      puts "#{CYAN}Saved Workflows:#{RESET}\n\n"
      workflows.each do |wf|
        status = wf[:enabled] ? "#{GREEN}enabled#{RESET}" : "#{RED}disabled#{RESET}"
        confidence = (wf[:overall_confidence] * 100).round
        conf_color = confidence >= 80 ? GREEN : (confidence >= 50 ? YELLOW : RED)

        puts "  #{BOLD}#{wf[:name]}#{RESET} [#{status}]"
        puts "    #{DIM}#{wf[:description][0, 60]}#{wf[:description].length > 60 ? '...' : ''}#{RESET}"
        puts "    Trigger: #{wf[:trigger_type]} | Runs: #{wf[:run_count]} | Confidence: #{conf_color}#{confidence}%#{RESET}"
        puts
      end
    end

    def schedule_cli(action, workflow_name = nil)
      require_relative "ruboto/workflow"
      ensure_db_exists

      case action.to_s.downcase
      when "list"
        show_scheduled_workflows
      when "status"
        show_schedule_status
      when "enable"
        toggle_workflow_schedule(workflow_name, true)
      when "disable"
        toggle_workflow_schedule(workflow_name, false)
      when "check"
        check_and_run_due_workflows
      else
        puts "#{RED}Unknown action: #{action}#{RESET}"
        puts "#{DIM}Usage: /schedule list|status|enable|disable|check [workflow-name]#{RESET}"
      end
    end

    def show_scheduled_workflows
      workflows = Workflow::Storage.list_workflows
      scheduled = workflows.select { |wf| wf[:trigger_type] != "manual" }

      if scheduled.empty?
        puts "#{DIM}No scheduled workflows.#{RESET}"
        puts "Create one with: /workflow \"Every Friday at 5pm, do something\""
        return
      end

      puts "#{CYAN}Scheduled Workflows:#{RESET}\n\n"

      scheduled.each do |wf|
        full_wf = Workflow::Storage.load_workflow(wf[:id])
        trigger_config = full_wf[:trigger_config] || {}

        status = wf[:enabled] ? "#{GREEN}enabled#{RESET}" : "#{RED}disabled#{RESET}"
        trigger_desc = format_trigger_description(wf[:trigger_type], trigger_config)

        puts "  #{BOLD}#{wf[:name]}#{RESET} [#{status}]"
        puts "    #{DIM}#{wf[:description][0, 50]}#{wf[:description].length > 50 ? '...' : ''}#{RESET}"
        puts "    #{CYAN}Trigger:#{RESET} #{trigger_desc}"

        # Show last run
        manager = Workflow::TriggerManager.new
        history = manager.get_trigger_history(wf[:id], 1)
        if history.any?
          puts "    #{DIM}Last triggered: #{history.first[:triggered_at]}#{RESET}"
        end
        puts
      end
    end

    def show_schedule_status
      manager = Workflow::TriggerManager.new
      now = Time.now

      puts "#{CYAN}Schedule Status:#{RESET}\n\n"
      puts "  Current time: #{now.strftime('%Y-%m-%d %H:%M:%S %Z')}"
      puts

      # Check for due workflows
      due = manager.get_due_workflows(now)
      if due.any?
        puts "  #{YELLOW}Workflows due to run:#{RESET}"
        due.each { |wf| puts "    • #{wf[:name]}" }
      else
        puts "  #{GREEN}No workflows due right now.#{RESET}"
      end
      puts

      # Show next scheduled runs
      puts "  #{DIM}Use '/schedule check' to run due workflows manually.#{RESET}"
    end

    def toggle_workflow_schedule(name, enabled)
      unless name
        puts "#{RED}Workflow name required.#{RESET}"
        puts "#{DIM}Usage: /schedule #{enabled ? 'enable' : 'disable'} <workflow-name>#{RESET}"
        return
      end

      workflow = Workflow::Storage.load_workflow_by_name(name)
      unless workflow
        puts "#{RED}Workflow '#{name}' not found.#{RESET}"
        return
      end

      sql = "UPDATE user_workflows SET enabled = #{enabled ? 1 : 0}, updated_at = datetime('now') WHERE id = #{workflow[:id]};"
      Ruboto.run_sql(sql)

      action = enabled ? "enabled" : "disabled"
      puts "#{GREEN}✓#{RESET} Workflow '#{name}' #{action}."
    end

    def check_and_run_due_workflows
      manager = Workflow::TriggerManager.new
      now = Time.now

      due = manager.get_due_workflows(now)

      if due.empty?
        puts "#{DIM}No workflows due to run.#{RESET}"
        return
      end

      puts "#{CYAN}Found #{due.length} workflow(s) due to run:#{RESET}\n\n"

      due.each do |wf|
        puts "#{BOLD}Running: #{wf[:name]}#{RESET}"

        # Record trigger execution
        manager.record_trigger(wf[:id], :schedule, { triggered_at: now.to_s })

        # Run the workflow
        run_workflow_cli(wf[:name])
        puts
      end
    end

    def format_trigger_description(trigger_type, config)
      config = config.transform_keys(&:to_sym) rescue config

      case trigger_type.to_s
      when "schedule"
        freq = config[:frequency] || config["frequency"]
        hour = config[:hour] || config["hour"]
        day = config[:day_of_week] || config["day_of_week"]

        time_str = hour ? "#{hour}:#{(config[:minute] || 0).to_s.rjust(2, '0')}" : "any time"

        case freq.to_s
        when "daily"
          "Daily at #{time_str}"
        when "weekly"
          day_name = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday][day.to_i] rescue "Unknown"
          "Every #{day_name} at #{time_str}"
        when "monthly"
          "Monthly on day #{config[:day_of_month] || 1} at #{time_str}"
        else
          "Schedule: #{freq}"
        end
      when "file_watch"
        path = config[:path] || config["path"] || "?"
        pattern = config[:pattern] || config["pattern"] || "*"
        "Watch #{path} for #{pattern}"
      when "email_match"
        from = config[:from_pattern] || config["from_pattern"]
        subject = config[:subject_pattern] || config["subject_pattern"]
        parts = []
        parts << "from: #{from}" if from
        parts << "subject: #{subject}" if subject
        "Email #{parts.join(', ')}"
      else
        trigger_type.to_s.capitalize
      end
    end

    def history_cli(workflow_name = nil, limit = nil)
      require_relative "ruboto/workflow"
      ensure_db_exists

      limit ||= 10

      if workflow_name
        # Show history for specific workflow
        workflow = Workflow::Storage.load_workflow_by_name(workflow_name)
        unless workflow
          puts "#{RED}Workflow '#{workflow_name}' not found.#{RESET}"
          return
        end

        runs = Workflow::History.get_runs(workflow[:id], limit: limit, include_log: true)
        stats = Workflow::History.get_stats(workflow[:id])

        puts "#{CYAN}History: #{workflow[:name]}#{RESET}\n\n"

        # Show stats
        puts "  #{BOLD}Statistics:#{RESET}"
        puts "    Total runs: #{stats[:total_runs]} | Success: #{GREEN}#{stats[:successful]}#{RESET} | Failed: #{RED}#{stats[:failed]}#{RESET}"
        puts "    Success rate: #{stats[:success_rate]}% | Avg duration: #{stats[:avg_duration_seconds]}s"
        puts

        if runs.empty?
          puts "  #{DIM}No run history yet.#{RESET}"
          return
        end

        puts "  #{BOLD}Recent Runs:#{RESET}"
        runs.each do |run|
          status_color = run[:status] == "completed" ? GREEN : (run[:status] == "failed" ? RED : YELLOW)
          status_icon = run[:status] == "completed" ? "✓" : (run[:status] == "failed" ? "✗" : "○")

          puts "    #{status_color}#{status_icon}#{RESET} #{run[:started_at]} - #{run[:status]}"
          puts "      #{DIM}Duration: #{run[:duration_seconds] || '?'}s | Steps: #{(run[:log] || []).length}#{RESET}"

          # Show errors if any
          errors = (run[:log] || []).select { |e| e[:event]&.to_s == "failed" || e[:error] }
          errors.each do |err|
            puts "      #{RED}Error: #{err[:error] || err[:data]&.dig(:error) || 'Unknown'}#{RESET}"
          end
        end
      else
        # Show all recent runs
        runs = Workflow::History.get_all_runs(limit: limit, include_log: false)

        if runs.empty?
          puts "#{DIM}No workflow history yet.#{RESET}"
          return
        end

        puts "#{CYAN}Recent Workflow Runs:#{RESET}\n\n"

        runs.each do |run|
          status_color = run[:status] == "completed" ? GREEN : (run[:status] == "failed" ? RED : YELLOW)
          status_icon = run[:status] == "completed" ? "✓" : (run[:status] == "failed" ? "✗" : "○")

          puts "  #{status_color}#{status_icon}#{RESET} #{BOLD}#{run[:workflow_name]}#{RESET}"
          puts "    #{run[:started_at]} - #{run[:status]} (#{run[:duration_seconds] || '?'}s)"
        end

        puts "\n#{DIM}Use /history <workflow-name> for detailed history.#{RESET}"
      end
    end

    def export_cli(workflow_name, file_path = nil)
      require_relative "ruboto/workflow"
      ensure_db_exists

      workflow = Workflow::Storage.load_workflow_by_name(workflow_name)
      unless workflow
        puts "#{RED}Workflow '#{workflow_name}' not found.#{RESET}"
        return
      end

      file_path ||= "#{workflow_name.gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
      file_path = File.expand_path(file_path)

      if Workflow::ExportImport.export_to_file(workflow[:id], file_path)
        puts "#{GREEN}✓#{RESET} Exported '#{workflow_name}' to #{file_path}"

        # Show summary
        data = Workflow::ExportImport.export_workflow(workflow[:id])
        puts "  #{DIM}#{data[:steps].length} steps, #{data[:run_count]} runs, #{(data[:overall_confidence] * 100).round}% confidence#{RESET}"
      else
        puts "#{RED}Failed to export workflow.#{RESET}"
      end
    end

    def import_cli(file_path)
      require_relative "ruboto/workflow"
      ensure_db_exists

      file_path = File.expand_path(file_path)

      unless File.exist?(file_path)
        puts "#{RED}File not found: #{file_path}#{RESET}"
        return
      end

      workflow_id = Workflow::ExportImport.import_from_file(file_path, rename_on_conflict: true)

      if workflow_id
        workflow = Workflow::Storage.load_workflow(workflow_id)
        puts "#{GREEN}✓#{RESET} Imported workflow '#{workflow[:name]}'"
        puts "  #{DIM}#{Workflow::Storage.load_steps(workflow_id).length} steps#{RESET}"
        puts "  #{DIM}Run with: /run #{workflow[:name]}#{RESET}"
      else
        puts "#{RED}Failed to import workflow. Check file format.#{RESET}"
      end
    end

    def audit_cli(workflow_name, run_id = nil)
      require_relative "ruboto/workflow"

      if run_id
        # Show specific run details
        show_audit_run(workflow_name, run_id)
      else
        # Show audit summary for workflow
        show_audit_summary(workflow_name)
      end
    end

    def show_audit_summary(workflow_name)
      logs = Workflow::AuditLogger.list_logs(workflow_name)

      if logs.empty?
        puts "#{DIM}No audit logs found for '#{workflow_name}'.#{RESET}"
        puts "#{DIM}Logs are created when workflows run.#{RESET}"
        return
      end

      puts "#{CYAN}Audit Logs: #{workflow_name}#{RESET}\n\n"

      summary = Workflow::AuditLogger.get_summary(workflow_name)

      summary.each do |log|
        status_color = log[:status] == "completed" ? GREEN : (log[:status] == "failed" ? RED : YELLOW)
        status_icon = log[:status] == "completed" ? "✓" : (log[:status] == "failed" ? "✗" : "○")

        puts "  #{status_color}#{status_icon}#{RESET} Run #{log[:run_id]} - #{log[:started_at]}"
        puts "    #{DIM}Status: #{log[:status]} | Duration: #{log[:duration] || '?'}s | Corrections: #{log[:corrections]}#{RESET}"
        puts "    #{DIM}Log: #{log[:log_file]}#{RESET}"
        puts
      end

      puts "#{DIM}Use /audit #{workflow_name} <run-id> for detailed view.#{RESET}"
    end

    def show_audit_run(workflow_name, run_id)
      logs = Workflow::AuditLogger.list_logs(workflow_name)
      log_file = logs.find { |f| f.include?("run_#{run_id}_") }

      unless log_file
        puts "#{RED}Audit log for run #{run_id} not found.#{RESET}"
        return
      end

      data = Workflow::AuditLogger.read_log(log_file)
      unless data
        puts "#{RED}Failed to read audit log.#{RESET}"
        return
      end

      puts "#{CYAN}Audit Log: #{workflow_name} - Run #{run_id}#{RESET}\n\n"
      puts "  #{DIM}File: #{File.basename(log_file)}#{RESET}\n\n"

      data[:events].each do |event|
        case event[:type]
        when "workflow_start"
          puts "  #{BOLD}[START]#{RESET} #{event[:timestamp]}"
          puts "    Trigger: #{event[:data][:trigger_type] || 'manual'}"

        when "step_start"
          puts "  #{CYAN}[STEP #{event[:data][:step_id]}]#{RESET} #{event[:data][:description]}"
          puts "    Tool: #{event[:data][:tool]} | Confidence: #{(event[:data][:confidence] * 100).round}%"

        when "step_result"
          if event[:data][:success]
            puts "    #{GREEN}✓#{RESET} #{event[:data][:summary]}"
          else
            puts "    #{RED}✗#{RESET} #{event[:data][:error]}"
          end

        when "user_correction"
          puts "    #{YELLOW}[CORRECTION]#{RESET} #{event[:data][:correction_type]}"
          puts "      #{DIM}#{event[:data][:original]} → #{event[:data][:corrected]}#{RESET}"

        when "confidence_change"
          change = event[:data][:change]
          color = change >= 0 ? GREEN : RED
          puts "    #{color}[CONFIDENCE]#{RESET} #{(event[:data][:old_confidence] * 100).round}% → #{(event[:data][:new_confidence] * 100).round}%"

        when "user_action"
          puts "    #{YELLOW}[USER]#{RESET} #{event[:data][:action]}"

        when "workflow_complete"
          status_color = event[:data][:status] == "completed" ? GREEN : RED
          puts "\n  #{BOLD}[COMPLETE]#{RESET} #{status_color}#{event[:data][:status]}#{RESET}"
          puts "    Duration: #{event[:data][:duration_seconds]}s"
          puts "    Steps: #{event[:data][:steps_successful]}/#{event[:data][:steps_executed]} successful"

        when "error"
          puts "    #{RED}[ERROR]#{RESET} #{event[:data][:context]}: #{event[:data][:error_message]}"
        end
      end
    end

    def trust_workflow_cli(name, step_number = nil, confidence_percent = nil)
      require_relative "ruboto/workflow"
      ensure_db_exists

      workflow = Workflow::Storage.load_workflow_by_name(name)
      unless workflow
        puts "#{RED}Workflow '#{name}' not found.#{RESET}"
        return
      end

      steps = Workflow::Storage.load_steps(workflow[:id])

      if step_number.nil?
        # Show graduation status for all steps
        puts "#{CYAN}Trust Status: #{workflow[:name]}#{RESET}\n\n"

        steps.each do |step|
          tracker = Workflow::ConfidenceTracker.new(workflow_id: workflow[:id], step_order: step[:step_order])
          confidence = step[:confidence]
          status = tracker.graduation_status(
            confidence: confidence,
            run_count: workflow[:run_count],
            recent_corrections: tracker.get_corrections.length
          )

          conf_percent = (confidence * 100).round
          conf_color = conf_percent >= 80 ? GREEN : (conf_percent >= 50 ? YELLOW : RED)
          grad_icon = status[:ready] ? "#{GREEN}✓#{RESET}" : "#{YELLOW}○#{RESET}"

          puts "  #{BOLD}Step #{step[:step_order]}:#{RESET} #{step[:description]}"
          puts "    Confidence: #{conf_color}#{conf_percent}%#{RESET} | #{grad_icon} #{status[:ready] ? 'Ready for autonomous' : 'Supervised'}"

          unless status[:ready]
            status[:reasons].each { |r| puts "    #{DIM}• #{r}#{RESET}" }
          end

          # Show learned patterns
          patterns = tracker.infer_patterns
          unless patterns.empty?
            puts "    #{CYAN}Learned patterns:#{RESET}"
            patterns.each { |p| puts "      • #{p[:type]}: #{p[:pattern]}" }
          end
          puts
        end
        return
      end

      # Adjust specific step confidence
      step = steps.find { |s| s[:step_order] == step_number }
      unless step
        puts "#{RED}Step #{step_number} not found. Available steps: 1-#{steps.length}#{RESET}"
        return
      end

      if confidence_percent.nil?
        # Show current status
        puts "#{CYAN}Step #{step_number}:#{RESET} #{step[:description]}"
        puts "  Current confidence: #{(step[:confidence] * 100).round}%"
        puts "  #{DIM}Use: /trust #{name} #{step_number} <0-100> to adjust#{RESET}"
        return
      end

      # Set new confidence
      new_confidence = [[confidence_percent / 100.0, 0.0].max, 1.0].min
      Workflow::Storage.update_step_confidence(workflow[:id], step_number, new_confidence)
      Workflow::Storage.update_overall_confidence(workflow[:id])

      puts "#{GREEN}✓#{RESET} Updated step #{step_number} confidence to #{confidence_percent}%"
      puts "#{DIM}Step will #{new_confidence >= 0.8 ? 'run autonomously' : 'require approval'} next time.#{RESET}"
    end

    def run_workflow_cli(name)
      require_relative "ruboto/workflow"
      ensure_db_exists

      workflow = Workflow::Storage.load_workflow_by_name(name)
      unless workflow
        puts "#{RED}Workflow '#{name}' not found.#{RESET}"
        puts "#{DIM}List workflows with: ruboto-ai --workflows#{RESET}"
        return
      end

      steps_data = Workflow::Storage.load_steps(workflow[:id])
      steps = steps_data.map do |s|
        Workflow::Step.new(
          id: s[:step_order],
          tool: s[:tool],
          params: s[:params],
          output_key: s[:output_key],
          description: s[:description]
        ).tap { |step| step.confidence = s[:confidence] }
      end

      runtime = Workflow::Runtime.new(steps, mode: :supervised)
      run_id = Workflow::Storage.start_run(workflow[:id])

      puts "#{CYAN}Running workflow: #{workflow[:name]}#{RESET}"
      puts "#{DIM}#{workflow[:description]}#{RESET}\n\n"

      success = true
      while !runtime.complete?
        step = runtime.current_step
        confidence = (step.confidence * 100).round

        puts "#{BOLD}Step #{step.id}/#{steps.length}:#{RESET} #{step.description}"
        puts "  #{DIM}Tool: #{step.tool}#{RESET}"
        puts "  #{DIM}Confidence: #{confidence}%#{confidence >= 80 ? ' (autonomous)' : ''}#{RESET}"

        resolved_params = runtime.resolve_params(step.params)
        puts "  #{DIM}Params: #{resolved_params.inspect}#{RESET}"

        if runtime.mode == :supervised && step.confidence < 0.8
          print "\n  #{YELLOW}[a]pprove  [s]kip  [e]dit  [c]ancel#{RESET} > "
          choice = gets&.strip&.downcase

          tracker = Workflow::ConfidenceTracker.new(workflow_id: workflow[:id], step_order: step.id)

          case choice
          when "a"
            # Continue with approval - confidence increases after execution
          when "s"
            puts "  #{DIM}Skipped.#{RESET}"
            new_confidence = tracker.on_skip(step.confidence)
            Workflow::Storage.update_step_confidence(workflow[:id], step.id, new_confidence)
            runtime.log_event(:skipped)
            runtime.advance
            next
          when "c"
            puts "  #{RED}Cancelled.#{RESET}"
            success = false
            break
          when "e"
            edited_params = edit_step_params(step, resolved_params, tracker)
            if edited_params
              resolved_params = edited_params
              puts "  #{GREEN}✓#{RESET} Parameters updated."
            else
              puts "  #{DIM}Edit cancelled.#{RESET}"
              next
            end
          else
            puts "  #{DIM}Invalid choice. Try again.#{RESET}"
            next
          end
        end

        tracker = Workflow::ConfidenceTracker.new(workflow_id: workflow[:id], step_order: step.id)
        print "  #{YELLOW}Executing...#{RESET}"
        result = execute_workflow_step(step, resolved_params)

        if result[:success]
          puts "\r  #{GREEN}✓#{RESET} #{result[:summary] || 'Done'}          "
          runtime.store_result(step.output_key, result[:output])
          runtime.log_event(:completed, { output: result[:summary] })

          new_confidence = tracker.on_approval(step.confidence)
          Workflow::Storage.update_step_confidence(workflow[:id], step.id, new_confidence)
        else
          puts "\r  #{RED}✗#{RESET} #{result[:error]}          "
          runtime.log_event(:failed, { error: result[:error] })
          success = false

          print "  #{YELLOW}[r]etry  [s]kip  [c]ancel#{RESET} > "
          choice = gets&.strip&.downcase
          case choice
          when "r"
            next
          when "s"
            runtime.advance
            next
          else
            break
          end
        end

        runtime.advance
        puts
      end

      status = success && runtime.complete? ? "completed" : "failed"
      Workflow::Storage.complete_run(run_id, status, runtime.state, runtime.run_log)
      Workflow::Storage.increment_run_count(workflow[:id], success)
      Workflow::Storage.update_overall_confidence(workflow[:id])

      if success && runtime.complete?
        puts "#{GREEN}✓ Workflow completed successfully.#{RESET}"
      else
        puts "#{RED}✗ Workflow did not complete.#{RESET}"
      end
    end

    def edit_step_params(step, current_params, tracker)
      puts "\n  #{CYAN}Edit parameters for: #{step.tool}#{RESET}"
      puts "  #{DIM}Current parameters:#{RESET}"

      param_keys = current_params.keys
      param_keys.each_with_index do |key, idx|
        puts "    #{idx + 1}. #{key}: #{current_params[key].inspect}"
      end

      print "\n  #{YELLOW}Enter parameter number to edit (or 'done' to finish, 'cancel' to abort):#{RESET} "
      input = gets&.strip&.downcase

      return nil if input == "cancel"
      return current_params if input == "done"

      idx = input.to_i - 1
      if idx < 0 || idx >= param_keys.length
        puts "  #{RED}Invalid selection.#{RESET}"
        return edit_step_params(step, current_params, tracker)
      end

      key = param_keys[idx]
      original_value = current_params[key]

      puts "  #{DIM}Current value: #{original_value.inspect}#{RESET}"
      print "  #{YELLOW}New value (or 'keep' to keep current):#{RESET} "
      new_value_str = gets&.strip

      return edit_step_params(step, current_params, tracker) if new_value_str == "keep"

      # Parse the new value
      new_value = parse_param_value(new_value_str, original_value)

      # Record the correction
      tracker.on_correction(
        step.confidence,
        correction_type: "param_edit",
        original: original_value.to_s,
        corrected: new_value.to_s
      )

      # Update params and continue editing
      updated_params = current_params.dup
      updated_params[key] = new_value

      puts "  #{GREEN}✓#{RESET} Updated #{key}"
      edit_step_params(step, updated_params, tracker)
    end

    def parse_param_value(str, original)
      return str if original.is_a?(String)

      if original.is_a?(Array)
        # Try to parse as JSON array, fallback to comma-separated
        begin
          JSON.parse(str)
        rescue
          str.split(",").map(&:strip)
        end
      elsif original.is_a?(Hash)
        begin
          JSON.parse(str)
        rescue
          original
        end
      elsif original.is_a?(Numeric)
        str.include?(".") ? str.to_f : str.to_i
      else
        str
      end
    end

    def execute_workflow_step(step, params)
      require_relative "ruboto/workflow"

      case step.tool
      when "file_glob"
        path = params[:path] || params["path"] || "."
        pattern = params[:pattern] || params["pattern"] || "*"
        full_pattern = File.join(File.expand_path(path), pattern)
        files = Dir.glob(full_pattern).select { |f| File.file?(f) }

        # Apply time filter if present
        if params[:since]
          cutoff = parse_time_filter(params[:since])
          files = files.select { |f| File.mtime(f) >= cutoff } if cutoff
        end

        files = files.sort_by { |f| -File.mtime(f).to_i } # newest first
        { success: true, output: files, summary: "Found #{files.length} files" }

      when "pdf_extract"
        files = params[:files] || params["files"] || []
        fields = params[:fields] || params["fields"] || ["vendor", "amount", "date"]
        fields = fields.map(&:to_s)

        results = Workflow::Extractors::PDF.batch_extract(files, fields)
        successful = results.reject { |r| r[:error] }

        {
          success: successful.length > 0,
          output: results,
          summary: "Extracted from #{successful.length}/#{files.length} files"
        }

      when "csv_read"
        path = params[:path] || params["path"]
        rows = Workflow::Extractors::CSV.read(path)
        { success: true, output: rows, summary: "Read #{rows.length} rows" }

      when "csv_append", "file_append"
        path = params[:path] || params["path"]
        data = params[:data] || params["data"]

        if data.is_a?(Array)
          data.each do |item|
            row_data = item.is_a?(Hash) && item[:data] ? item[:data] : item
            Workflow::Extractors::CSV.append(path, row_data)
          end
          { success: true, output: nil, summary: "Appended #{data.length} rows to #{File.basename(path)}" }
        else
          Workflow::Extractors::CSV.append(path, data)
          { success: true, output: nil, summary: "Appended to #{File.basename(path)}" }
        end

      when "data_filter"
        data = params[:data] || params["data"] || []
        condition = params[:condition] || params["condition"]
        filtered = Workflow::Extractors::CSV.filter(data, condition)
        { success: true, output: filtered, summary: "Filtered to #{filtered.length} items" }

      when "browser", "browser_form"
        result = tool_browser(params.transform_keys(&:to_s))
        success = !result.to_s.start_with?("error")
        { success: success, output: result, summary: result.to_s[0, 60] }

      when "email_search"
        result = tool_macos_auto({ "action" => "mail_inbox", "limit" => 20 })
        { success: true, output: result, summary: "Retrieved emails" }

      when "email_send"
        to = params[:to] || params["to"]
        subject = params[:subject] || params["subject"] || "Workflow Result"
        body = params[:body] || params["body"] || params[:data].to_s

        result = tool_macos_auto({
          "action" => "mail_send",
          "to" => to,
          "subject" => subject,
          "body" => body
        })
        { success: !result.to_s.start_with?("error"), output: result, summary: "Sent email to #{to}" }

      when "noop"
        { success: true, output: nil, summary: "No operation" }

      when "download_file", "web_download"
        url = params[:url] || params["url"]
        return { success: false, error: "url is required" } unless url

        output_path = params[:path] || params["path"]
        unless output_path
          # Auto-generate filename from URL
          filename = File.basename(URI.parse(url).path)
          filename = "download_#{Time.now.to_i}" if filename.empty?
          output_path = File.join("/tmp", filename)
        end

        # Ensure directory exists
        FileUtils.mkdir_p(File.dirname(output_path))

        # Download with redirect following
        downloaded_path = download_file_from_url(url, output_path)
        { success: true, output: downloaded_path, summary: "Downloaded to #{downloaded_path}" }

      else
        { success: false, error: "Unknown tool: #{step.tool}" }
      end
    rescue => e
      { success: false, error: e.message }
    end

    def parse_time_filter(filter)
      case filter.to_s.downcase
      when /(\d+)d/, /(\d+)\s*days?/
        Time.now - ($1.to_i * 24 * 60 * 60)
      when /(\d+)w/, /(\d+)\s*weeks?/
        Time.now - ($1.to_i * 7 * 24 * 60 * 60)
      when /(\d+)h/, /(\d+)\s*hours?/
        Time.now - ($1.to_i * 60 * 60)
      when "today"
        Time.now - (24 * 60 * 60)
      when "this week", "7d"
        Time.now - (7 * 24 * 60 * 60)
      when "this month", "30d"
        Time.now - (30 * 24 * 60 * 60)
      else
        nil
      end
    end

    def download_file_from_url(url, output_path, max_redirects = 5)
      uri = URI.parse(url)
      raise "Invalid URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      redirect_count = 0
      loop do
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = 30
        http.read_timeout = 60

        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = "Ruboto/1.0"

        response = http.request(request)

        case response
        when Net::HTTPSuccess
          File.open(output_path, "wb") { |f| f.write(response.body) }
          return output_path
        when Net::HTTPRedirection
          redirect_count += 1
          raise "Too many redirects" if redirect_count > max_redirects
          uri = URI.parse(response["location"])
        else
          raise "Download failed: HTTP #{response.code} #{response.message}"
        end
      end
    end
  end
end
