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
  DB_PATH = File.join(RUBOTO_DIR, "history.db")
  MAX_HISTORY_LOAD = 100

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
        tools: tool_schemas
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
      SQL

      run_sql(schema)
    end

    def run_sql(sql)
      output, _status = Open3.capture2('sqlite3', DB_PATH, sql)
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

        #{CYAN}Commands:#{RESET}
          #{BOLD}/q#{RESET}        #{DIM}quit#{RESET}
          #{BOLD}/c#{RESET}        #{DIM}clear conversation context#{RESET}
          #{BOLD}/h#{RESET}        #{DIM}show this help#{RESET}
          #{BOLD}/history#{RESET}  #{DIM}show recent commands#{RESET}
          #{BOLD}/profile#{RESET}  #{DIM}view/set profile (set <key> <val>, del <key>)#{RESET}
          #{BOLD}/teach#{RESET}    #{DIM}teach workflows (/teach name when <trigger> do <steps>)#{RESET}
          #{BOLD}/tasks#{RESET}    #{DIM}show recent task history (/tasks <count>)#{RESET}
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

        ACTION RULES:
        - Use macos_auto to open apps, check calendar, create reminders, send emails, create notes, manage clipboard
        - Use browser to open URLs, read page content, fill forms, click buttons, extract links
        - Chain actions naturally: check calendar → draft email → send it
        - mail_send and browser run_js require user confirmation — just call the tool, user will be prompted
        - If an action fails (app not running, permission denied), report the error and suggest alternatives

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
  end
end
