# frozen_string_literal: true

require_relative "../ruboto"

module Ruboto
  module CLI
    USAGE = <<~TEXT
      Usage: ruboto-ai [options]

        (no args)                  Interactive REPL (default)
        --quick "request"          Single-shot: one request, print result, exit
        --context "app:Name"       App context for quick mode (optional)
        --briefing morning|evening|auto  Run scheduled briefing
        --tasks [N]                Print recent N tasks (default 10), exit
        --install-schedule         Install launchd plist for scheduled briefings
        --uninstall-schedule       Remove launchd plist
        --help                     Show this help
    TEXT

    def self.run(argv)
      return Ruboto.run if argv.empty?

      case argv.first
      when "--help"
        puts USAGE
      when "--quick"
        request = argv[1]
        unless request && !request.start_with?("--")
          $stderr.puts "Error: --quick requires a request string"
          exit 1
        end
        context = nil
        if (ci = argv.index("--context"))
          context = argv[ci + 1]
        end
        Ruboto.run_quick(request, context: context)
      when "--briefing"
        mode = argv[1] || "auto"
        unless %w[morning evening auto].include?(mode)
          $stderr.puts "Error: --briefing accepts morning, evening, or auto"
          exit 1
        end
        Ruboto.run_briefing(mode)
      when "--tasks"
        limit = (argv[1] || "10").to_i
        Ruboto.run_tasks_cli(limit)
      when "--install-schedule"
        Ruboto.install_schedule
      when "--uninstall-schedule"
        Ruboto.uninstall_schedule
      else
        $stderr.puts "Unknown option: #{argv.first}"
        $stderr.puts USAGE
        exit 1
      end
    end
  end
end
