# frozen_string_literal: true

require "rbconfig"

module Ruboto
  module Scheduler
    PLIST_LABEL = "com.ruboto.briefing"
    PLIST_DIR = File.expand_path("~/Library/LaunchAgents")
    PLIST_PATH = File.join(PLIST_DIR, "#{PLIST_LABEL}.plist")

    def install_schedule
      bin_path = File.expand_path("../../bin/ruboto-ai", __dir__)
      ruby_path = RbConfig.ruby

      plist_content = <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>#{PLIST_LABEL}</string>
            <key>ProgramArguments</key>
            <array>
                <string>#{ruby_path}</string>
                <string>#{bin_path}</string>
                <string>--briefing</string>
                <string>auto</string>
            </array>
            <key>StartCalendarInterval</key>
            <array>
                <dict>
                    <key>Hour</key><integer>8</integer>
                    <key>Minute</key><integer>30</integer>
                </dict>
                <dict>
                    <key>Hour</key><integer>17</integer>
                    <key>Minute</key><integer>30</integer>
                </dict>
            </array>
            <key>StandardOutPath</key>
            <string>#{RUBOTO_DIR}/briefing.log</string>
            <key>StandardErrorPath</key>
            <string>#{RUBOTO_DIR}/briefing.log</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>OPENROUTER_API_KEY</key>
                <string>#{ENV["OPENROUTER_API_KEY"]}</string>
            </dict>
        </dict>
        </plist>
      PLIST

      Dir.mkdir(PLIST_DIR) unless Dir.exist?(PLIST_DIR)
      Dir.mkdir(RUBOTO_DIR) unless Dir.exist?(RUBOTO_DIR)

      File.write(PLIST_PATH, plist_content)

      # Unload first if already loaded (ignore errors)
      system("launchctl", "unload", PLIST_PATH, err: File::NULL, out: File::NULL)
      success = system("launchctl", "load", PLIST_PATH)

      if success
        puts "Scheduled briefings installed."
        puts "  Morning: 8:30am"
        puts "  Evening: 5:30pm"
        puts "  Plist: #{PLIST_PATH}"
        puts "  Log: #{RUBOTO_DIR}/briefing.log"
      else
        $stderr.puts "Error: launchctl load failed. Check plist at #{PLIST_PATH}"
        exit 1
      end
    end

    def uninstall_schedule
      unless File.exist?(PLIST_PATH)
        puts "No schedule installed (#{PLIST_PATH} not found)."
        return
      end

      system("launchctl", "unload", PLIST_PATH, err: File::NULL, out: File::NULL)
      File.delete(PLIST_PATH)
      puts "Scheduled briefings removed."
    end
  end
end
